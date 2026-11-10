// SPDX-License-Identifier: GPL-2.0-only
/*
 * cerro-audio-shmem — DMA via q6apm-dais (ADSP SMMU) for AudioReach GSL MAP.
 *
 * Allocates with dma_alloc_coherent on the same device mainline PCM uses, so
 * the address ADSP sees is a proper IOVA (+ SID in upper bits), not raw CMA.
 *
 * Prior attempts with raw CMA phys + hyp_assign rebooted the SoC.
 */
#include <linux/module.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/mm.h>
#include <linux/dma-mapping.h>
#include <linux/mutex.h>
#include <linux/list.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/ioctl.h>

#define DRV_NAME	"cerro-audio-shmem"
#define DEV_SHMEM	"cerro_audio_shmem"
#define DEV_MEM		"msm_audio_mem"
#define SID_MASK_DEFAULT 0xf

#define CERRO_SHMEM_IOC_MAGIC 'C'
struct cerro_shmem_alloc_req {
	__u32 size;
	__u32 flags;
	__u64 phys;	/* out: IOVA | (sid << 32) for SPF MAP */
	__u32 id;
	__u32 pad;
};
#define CERRO_SHMEM_ALLOC    _IOWR(CERRO_SHMEM_IOC_MAGIC, 1, struct cerro_shmem_alloc_req)
#define CERRO_SHMEM_FREE     _IOW(CERRO_SHMEM_IOC_MAGIC, 2, __u32)
#define CERRO_SHMEM_GET_PHYS _IOWR(CERRO_SHMEM_IOC_MAGIC, 3, struct cerro_shmem_alloc_req)

struct shmem_buf {
	struct list_head node;
	u32 id;
	size_t size;
	void *vaddr;
	dma_addr_t dma;		/* IOVA from dais device */
	u64 spf_addr;		/* dma | (sid << 32) */
};

struct shmem_file {
	struct shmem_buf *active;
};

static LIST_HEAD(buf_list);
static DEFINE_MUTEX(buf_lock);
static u32 next_id = 1;
static struct device *dma_dev;
static long sid = -1;

static int match_q6apm_dais(struct device *dev, const void *data)
{
	const char *compat;

	if (!dev->of_node)
		return 0;
	compat = of_get_property(dev->of_node, "compatible", NULL);
	return compat && !strcmp(compat, "qcom,q6apm-dais");
}

static struct shmem_buf *buf_find(u32 id)
{
	struct shmem_buf *b;

	list_for_each_entry(b, &buf_list, node)
		if (b->id == id)
			return b;
	return NULL;
}

static int shmem_alloc(struct shmem_file *sf, struct cerro_shmem_alloc_req *req)
{
	struct shmem_buf *b;
	size_t sz;

	sz = PAGE_ALIGN(req->size);
	if (!sz || sz > (16 * 1024 * 1024))
		return -EINVAL;
	if (!dma_dev)
		return -ENODEV;

	b = kzalloc(sizeof(*b), GFP_KERNEL);
	if (!b)
		return -ENOMEM;

	b->vaddr = dma_alloc_attrs(dma_dev, sz, &b->dma, GFP_KERNEL,
				   DMA_ATTR_FORCE_CONTIGUOUS);
	if (!b->vaddr) {
		b->vaddr = dma_alloc_coherent(dma_dev, sz, &b->dma, GFP_KERNEL);
		if (!b->vaddr) {
			kfree(b);
			return -ENOMEM;
		}
	}
	b->size = sz;
	if (sid < 0)
		b->spf_addr = b->dma;
	else
		b->spf_addr = b->dma | ((u64)sid << 32);

	mutex_lock(&buf_lock);
	b->id = next_id++;
	list_add(&b->node, &buf_list);
	sf->active = b;
	mutex_unlock(&buf_lock);

	req->size = sz;
	req->phys = b->spf_addr;
	req->id = b->id;
	pr_info(DRV_NAME ": alloc id=%u sz=%zu dma=%pad spf=0x%llx sid=%ld\n",
		b->id, b->size, &b->dma, b->spf_addr, sid);
	return 0;
}

static void shmem_free_locked(struct shmem_buf *b)
{
	dma_free_coherent(dma_dev, b->size, b->vaddr, b->dma);
	list_del(&b->node);
	kfree(b);
}

static long shmem_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct shmem_file *sf = file->private_data;
	struct cerro_shmem_alloc_req req;
	struct shmem_buf *b;
	u32 id;
	int ret;

	switch (cmd) {
	case CERRO_SHMEM_ALLOC:
		if (copy_from_user(&req, (void __user *)arg, sizeof(req)))
			return -EFAULT;
		ret = shmem_alloc(sf, &req);
		if (ret)
			return ret;
		if (copy_to_user((void __user *)arg, &req, sizeof(req)))
			return -EFAULT;
		return 0;
	case CERRO_SHMEM_FREE:
		if (get_user(id, (u32 __user *)arg))
			return -EFAULT;
		mutex_lock(&buf_lock);
		b = buf_find(id);
		if (!b) {
			mutex_unlock(&buf_lock);
			return -ENOENT;
		}
		if (sf->active == b)
			sf->active = NULL;
		shmem_free_locked(b);
		mutex_unlock(&buf_lock);
		return 0;
	case CERRO_SHMEM_GET_PHYS:
		if (copy_from_user(&req, (void __user *)arg, sizeof(req)))
			return -EFAULT;
		mutex_lock(&buf_lock);
		b = buf_find(req.id);
		if (!b && sf->active)
			b = sf->active;
		if (!b) {
			mutex_unlock(&buf_lock);
			return -ENOENT;
		}
		req.phys = b->spf_addr;
		req.size = b->size;
		req.id = b->id;
		mutex_unlock(&buf_lock);
		if (copy_to_user((void __user *)arg, &req, sizeof(req)))
			return -EFAULT;
		return 0;
	default:
		return -ENOTTY;
	}
}

static int shmem_mmap(struct file *file, struct vm_area_struct *vma)
{
	struct shmem_file *sf = file->private_data;
	struct shmem_buf *b = sf->active;
	unsigned long size;

	if (!b || !dma_dev)
		return -EINVAL;
	size = vma->vm_end - vma->vm_start;
	if (size > b->size)
		return -EINVAL;
	return dma_mmap_coherent(dma_dev, vma, b->vaddr, b->dma, size);
}

static int shmem_open(struct inode *inode, struct file *file)
{
	struct shmem_file *sf = kzalloc(sizeof(*sf), GFP_KERNEL);

	if (!sf)
		return -ENOMEM;
	file->private_data = sf;
	return 0;
}

static int shmem_release(struct inode *inode, struct file *file)
{
	kfree(file->private_data);
	return 0;
}

static const struct file_operations shmem_fops = {
	.owner		= THIS_MODULE,
	.open		= shmem_open,
	.release	= shmem_release,
	.unlocked_ioctl	= shmem_ioctl,
	.compat_ioctl	= shmem_ioctl,
	.mmap		= shmem_mmap,
	.llseek		= noop_llseek,
};

static const struct file_operations mem_fops = {
	.owner = THIS_MODULE,
	.llseek = noop_llseek,
};

static struct miscdevice shmem_misc = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = DEV_SHMEM,
	.fops = &shmem_fops,
	.mode = 0666,
};

static struct miscdevice mem_misc = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = DEV_MEM,
	.fops = &mem_fops,
	.mode = 0666,
};

static int __init cerro_audio_shmem_init(void)
{
	struct device *dev;
	struct of_phandle_args args;
	int ret;

	dev = bus_find_device(&platform_bus_type, NULL, NULL, match_q6apm_dais);
	if (!dev) {
		pr_err(DRV_NAME ": qcom,q6apm-dais not found (ADSP up?)\n");
		return -ENODEV;
	}
	dma_dev = dev;
	get_device(dma_dev);

	sid = -1;
	if (dma_dev->of_node &&
	    of_parse_phandle_with_fixed_args(dma_dev->of_node, "iommus",
					     1, 0, &args) == 0) {
		sid = args.args[0] & SID_MASK_DEFAULT;
		of_node_put(args.np);
		pr_info(DRV_NAME ": using dais dma_dev=%s sid=%ld\n",
			dev_name(dma_dev), sid);
	} else {
		pr_info(DRV_NAME ": using dais dma_dev=%s (no sid)\n",
			dev_name(dma_dev));
	}

	ret = misc_register(&shmem_misc);
	if (ret)
		goto err_dev;
	ret = misc_register(&mem_misc);
	if (ret)
		goto err_shmem;

	pr_info(DRV_NAME ": /dev/%s ready\n", DEV_SHMEM);
	return 0;

err_shmem:
	misc_deregister(&shmem_misc);
err_dev:
	put_device(dma_dev);
	dma_dev = NULL;
	return ret;
}

static void __exit cerro_audio_shmem_exit(void)
{
	struct shmem_buf *b, *tmp;

	misc_deregister(&mem_misc);
	misc_deregister(&shmem_misc);
	mutex_lock(&buf_lock);
	list_for_each_entry_safe(b, tmp, &buf_list, node)
		shmem_free_locked(b);
	mutex_unlock(&buf_lock);
	if (dma_dev)
		put_device(dma_dev);
}

module_init(cerro_audio_shmem_init);
module_exit(cerro_audio_shmem_exit);
MODULE_DESCRIPTION("Cerro AudioReach shmem via q6apm-dais SMMU");
MODULE_LICENSE("GPL");
