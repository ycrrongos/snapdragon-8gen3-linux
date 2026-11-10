// SPDX-License-Identifier: GPL-2.0-only
/*
 * cerro-aud-pasthru — mainline GPR userspace bridge for AudioReach AGM/ARGS.
 *
 * Creates /dev/aud_pasthru_adsp (real) plus stub /dev/aud_pasthru_modem and
 * /dev/gpr_channel so ARGS gpr_lx can open all three paths.
 *
 * Unlike vendor audio-pkt.c (needs DT + gpr-lite + msm_audio_ion), this binds
 * to the already-probed q6apm aprbus device and uses gpr_alloc_port().
 * On write, src_port is rewritten to the dynamic port so responses route back.
 *
 * Shared-mem MAP with offset-mode (ION) is not supported yet → -EOPNOTSUPP.
 */
#include <linux/module.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/poll.h>
#include <linux/skbuff.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/wait.h>
#include <linux/device.h>
#include <linux/of.h>
#include <linux/soc/qcom/apr.h>
#include <dt-bindings/soc/qcom,gpr.h>

#define DRV_NAME		"cerro-aud-pasthru"
#define DEV_ADSP		"aud_pasthru_adsp"
#define DEV_MODEM		"aud_pasthru_modem"
#define DEV_GPR_CH		"gpr_channel"
#define MAX_PACKET_SIZE		4096
#define APM_CMD_SHARED_MEM_MAP_REGIONS	0x0100100C
#define APM_MEMORY_MAP_BIT_MASK_IS_OFFSET_MODE	0x00000004UL

struct pasthru_pkt {
	struct list_head node;
	u32 len;
	u8 data[];
};

/*
 * ARGS registers userspace ports (e.g. GSL_MAIN_SRC_PORT=0x2003). We must
 * send with the kernel gpr_alloc_port id so ADSP replies reach us, then rewrite
 * response dest_port back to the userspace port ARGS expects.
 */
#define PORT_MAP_SLOTS 64
struct port_map_entry {
	u32 token;
	u32 user_port;
	bool used;
};

struct pasthru_dev {
	struct miscdevice misc;
	bool stub;			/* modem / gpr_channel: open-only */
	struct mutex lock;
	spinlock_t qlock;
	struct list_head queue;
	wait_queue_head_t readq;
	gpr_port_t *port;
	gpr_device_t *gdev;
	struct port_map_entry port_map[PORT_MAP_SLOTS];
	u32 port_map_next;
	u32 last_user_port;		/* fallback when token miss */
};

static struct pasthru_dev *g_adsp;
static struct pasthru_dev *g_modem;
static struct pasthru_dev *g_gprch;

static int match_q6apm(struct device *dev, const void *data)
{
	const char *compat;

	if (!dev->of_node)
		return 0;
	compat = of_get_property(dev->of_node, "compatible", NULL);
	return compat && !strcmp(compat, "qcom,q6apm");
}

static void pasthru_map_remember(struct pasthru_dev *pd, u32 token, u32 user_port)
{
	unsigned long flags;
	u32 i, slot;

	spin_lock_irqsave(&pd->qlock, flags);
	pd->last_user_port = user_port;
	/* update existing token slot if present */
	for (i = 0; i < PORT_MAP_SLOTS; i++) {
		if (pd->port_map[i].used && pd->port_map[i].token == token) {
			pd->port_map[i].user_port = user_port;
			spin_unlock_irqrestore(&pd->qlock, flags);
			return;
		}
	}
	slot = pd->port_map_next++ % PORT_MAP_SLOTS;
	pd->port_map[slot].token = token;
	pd->port_map[slot].user_port = user_port;
	pd->port_map[slot].used = true;
	spin_unlock_irqrestore(&pd->qlock, flags);
}

static u32 pasthru_map_lookup(struct pasthru_dev *pd, u32 token)
{
	unsigned long flags;
	u32 i, port;

	spin_lock_irqsave(&pd->qlock, flags);
	port = pd->last_user_port;
	for (i = 0; i < PORT_MAP_SLOTS; i++) {
		if (pd->port_map[i].used && pd->port_map[i].token == token) {
			port = pd->port_map[i].user_port;
			break;
		}
	}
	spin_unlock_irqrestore(&pd->qlock, flags);
	return port;
}

static int pasthru_rx_cb(const struct gpr_resp_pkt *resp, void *priv, int op)
{
	struct pasthru_dev *pd = priv;
	struct pasthru_pkt *pp;
	struct gpr_hdr *outh;
	u32 hdr_bytes, total, user_port;
	unsigned long flags;

	if (!pd || !resp || pd->stub)
		return -EINVAL;

	hdr_bytes = resp->hdr.hdr_size * 4;
	total = hdr_bytes + resp->payload_size;
	if (total < hdr_bytes || total > MAX_PACKET_SIZE)
		return -EINVAL;

	pp = kmalloc(struct_size(pp, data, total), GFP_ATOMIC);
	if (!pp)
		return -ENOMEM;

	pp->len = total;
	memcpy(pp->data, &resp->hdr, min_t(u32, hdr_bytes, sizeof(resp->hdr)));
	/* hdr may be larger than struct gpr_hdr if remote adds words — only
	 * copy what we have in resp->hdr; remainder zeroed.
	 */
	if (hdr_bytes > sizeof(resp->hdr))
		memset(pp->data + sizeof(resp->hdr), 0,
		       hdr_bytes - sizeof(resp->hdr));
	if (resp->payload_size && resp->payload)
		memcpy(pp->data + hdr_bytes, resp->payload, resp->payload_size);

	/* Translate kernel port → userspace port ARGS registered. */
	outh = (struct gpr_hdr *)pp->data;
	if (pd->port && outh->dest_port == pd->port->id) {
		user_port = pasthru_map_lookup(pd, outh->token);
		if (user_port)
			outh->dest_port = user_port;
	}

	spin_lock_irqsave(&pd->qlock, flags);
	list_add_tail(&pp->node, &pd->queue);
	spin_unlock_irqrestore(&pd->qlock, flags);
	wake_up_interruptible(&pd->readq);
	return 0;
}

static int pasthru_open(struct inode *inode, struct file *file)
{
	struct pasthru_dev *pd = container_of(file->private_data,
					      struct pasthru_dev, misc);
	file->private_data = pd;
	return 0;
}

static int pasthru_release(struct inode *inode, struct file *file)
{
	struct pasthru_dev *pd = file->private_data;
	struct pasthru_pkt *pp, *tmp;
	unsigned long flags;

	if (!pd || pd->stub)
		return 0;

	spin_lock_irqsave(&pd->qlock, flags);
	list_for_each_entry_safe(pp, tmp, &pd->queue, node) {
		list_del(&pp->node);
		kfree(pp);
	}
	spin_unlock_irqrestore(&pd->qlock, flags);
	return 0;
}

static ssize_t pasthru_read(struct file *file, char __user *buf,
			    size_t count, loff_t *ppos)
{
	struct pasthru_dev *pd = file->private_data;
	struct pasthru_pkt *pp;
	unsigned long flags;
	ssize_t use;

	if (!pd)
		return -EINVAL;
	if (pd->stub) {
		if (file->f_flags & O_NONBLOCK)
			return -EAGAIN;
		if (wait_event_interruptible(pd->readq, false))
			return -ERESTARTSYS;
		return 0;
	}

	spin_lock_irqsave(&pd->qlock, flags);
	while (list_empty(&pd->queue)) {
		spin_unlock_irqrestore(&pd->qlock, flags);
		if (file->f_flags & O_NONBLOCK)
			return -EAGAIN;
		if (wait_event_interruptible(pd->readq,
					     !list_empty(&pd->queue)))
			return -ERESTARTSYS;
		spin_lock_irqsave(&pd->qlock, flags);
	}
	pp = list_first_entry(&pd->queue, struct pasthru_pkt, node);
	list_del(&pp->node);
	spin_unlock_irqrestore(&pd->qlock, flags);

	use = min_t(size_t, count, pp->len);
	if (copy_to_user(buf, pp->data, use))
		use = -EFAULT;
	kfree(pp);
	return use;
}

static ssize_t pasthru_write(struct file *file, const char __user *buf,
			     size_t count, loff_t *ppos)
{
	struct pasthru_dev *pd = file->private_data;
	struct gpr_pkt *pkt;
	struct gpr_hdr *hdr;
	int ret;

	if (!pd)
		return -EINVAL;
	if (pd->stub)
		return count; /* swallow — ARGS may probe domains */

	if (count < sizeof(*hdr) || count > MAX_PACKET_SIZE)
		return -EINVAL;

	pkt = memdup_user(buf, count);
	if (IS_ERR(pkt))
		return PTR_ERR(pkt);

	hdr = &pkt->hdr;
	if (hdr->pkt_size != count) {
		ret = -EINVAL;
		goto out;
	}

	if (hdr->opcode == APM_CMD_SHARED_MEM_MAP_REGIONS &&
	    count >= sizeof(*hdr) + 8) {
		/* After hdr: u16 mem_pool_id, u16 num_regions, u32 property_flag */
		u32 prop;

		memcpy(&prop, (u8 *)pkt + sizeof(*hdr) + 4, sizeof(prop));
		if (prop & APM_MEMORY_MAP_BIT_MASK_IS_OFFSET_MODE) {
			dev_warn_ratelimited(pd->misc.this_device,
				"shared-mem offset MAP not supported yet\n");
			ret = -EOPNOTSUPP;
			goto out;
		}
	}

	if (!pd->port) {
		ret = -ENETRESET;
		goto out;
	}

	/* Remember userspace src_port, send with kernel port so ADSP replies
	 * hit our gpr_alloc_port callback; RX rewrites dest_port back.
	 */
	pasthru_map_remember(pd, hdr->token, hdr->src_port);
	hdr->src_port = pd->port->id;
	hdr->src_domain = GPR_DOMAIN_ID_APPS;

	mutex_lock(&pd->lock);
	ret = gpr_send_port_pkt(pd->port, pkt);
	mutex_unlock(&pd->lock);

out:
	kfree(pkt);
	return ret < 0 ? ret : count;
}

static __poll_t pasthru_poll(struct file *file, poll_table *wait)
{
	struct pasthru_dev *pd = file->private_data;
	__poll_t mask = 0;
	unsigned long flags;

	if (!pd)
		return EPOLLERR;
	poll_wait(file, &pd->readq, wait);
	if (pd->stub)
		return 0;
	spin_lock_irqsave(&pd->qlock, flags);
	if (!list_empty(&pd->queue))
		mask |= EPOLLIN | EPOLLRDNORM;
	spin_unlock_irqrestore(&pd->qlock, flags);
	return mask;
}

static const struct file_operations pasthru_fops = {
	.owner		= THIS_MODULE,
	.open		= pasthru_open,
	.release	= pasthru_release,
	.read		= pasthru_read,
	.write		= pasthru_write,
	.poll		= pasthru_poll,
	.llseek		= noop_llseek,
};

static int pasthru_init_dev(struct pasthru_dev **out, const char *name,
			    bool stub, gpr_device_t *gdev)
{
	struct pasthru_dev *pd;
	int ret;

	pd = kzalloc(sizeof(*pd), GFP_KERNEL);
	if (!pd)
		return -ENOMEM;

	pd->stub = stub;
	pd->gdev = gdev;
	mutex_init(&pd->lock);
	spin_lock_init(&pd->qlock);
	INIT_LIST_HEAD(&pd->queue);
	init_waitqueue_head(&pd->readq);

	pd->misc.minor = MISC_DYNAMIC_MINOR;
	pd->misc.name = name;
	pd->misc.fops = &pasthru_fops;
	pd->misc.mode = 0660;

	if (!stub) {
		pd->port = gpr_alloc_port(gdev, &gdev->dev, pasthru_rx_cb, pd);
		if (IS_ERR(pd->port)) {
			ret = PTR_ERR(pd->port);
			pd->port = NULL;
			kfree(pd);
			return ret;
		}
	}

	ret = misc_register(&pd->misc);
	if (ret) {
		if (pd->port)
			gpr_free_port(pd->port);
		kfree(pd);
		return ret;
	}

	*out = pd;
	pr_info(DRV_NAME ": /dev/%s ready%s (port=%d)\n", name,
		stub ? " [stub]" : "",
		pd->port ? pd->port->id : -1);
	return 0;
}

static void pasthru_free_dev(struct pasthru_dev *pd)
{
	struct pasthru_pkt *pp, *tmp;
	unsigned long flags;

	if (!pd)
		return;
	misc_deregister(&pd->misc);
	if (pd->port)
		gpr_free_port(pd->port);
	spin_lock_irqsave(&pd->qlock, flags);
	list_for_each_entry_safe(pp, tmp, &pd->queue, node) {
		list_del(&pp->node);
		kfree(pp);
	}
	spin_unlock_irqrestore(&pd->qlock, flags);
	kfree(pd);
}

static int __init cerro_aud_pasthru_init(void)
{
	struct device *dev;
	gpr_device_t *gdev;
	int ret;

	dev = bus_find_device(&aprbus, NULL, NULL, match_q6apm);
	if (!dev) {
		pr_err(DRV_NAME ": q6apm aprbus device not found (ADSP up?)\n");
		return -ENODEV;
	}
	gdev = to_apr_device(dev);

	ret = pasthru_init_dev(&g_adsp, DEV_ADSP, false, gdev);
	if (ret)
		goto put;

	ret = pasthru_init_dev(&g_modem, DEV_MODEM, true, NULL);
	if (ret)
		goto err_adsp;

	ret = pasthru_init_dev(&g_gprch, DEV_GPR_CH, true, NULL);
	if (ret)
		goto err_modem;

	/* keep one ref on gdev via held device until exit */
	return 0;

err_modem:
	pasthru_free_dev(g_modem);
	g_modem = NULL;
err_adsp:
	pasthru_free_dev(g_adsp);
	g_adsp = NULL;
put:
	put_device(dev);
	return ret;
}

static void __exit cerro_aud_pasthru_exit(void)
{
	struct device *dev = g_adsp && g_adsp->gdev ? &g_adsp->gdev->dev : NULL;

	pasthru_free_dev(g_gprch);
	pasthru_free_dev(g_modem);
	pasthru_free_dev(g_adsp);
	g_gprch = g_modem = g_adsp = NULL;
	if (dev)
		put_device(dev);
}

module_init(cerro_aud_pasthru_init);
module_exit(cerro_aud_pasthru_exit);
MODULE_DESCRIPTION("Cerro AudioReach GPR userspace passthrough");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Cerro Linux bringup");
