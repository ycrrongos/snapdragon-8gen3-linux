// SPDX-License-Identifier: GPL-2.0-only
/* Passive PMIC GLINK USB-C observer. No send path or hardware writes. */
#include <linux/device.h>
#include <linux/err.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/soc/qcom/pmic_glink.h>

static struct platform_device *observer;

static void observe_rx(const void *data, size_t len, void *priv)
{
	const struct pmic_glink_hdr *hdr = data;

	if (len < sizeof(*hdr))
		return;
	/* UCSI synchronous replies are noisy; retain its connection indication. */
	if (le32_to_cpu(hdr->owner) == PMIC_GLINK_OWNER_USBC &&
	    le32_to_cpu(hdr->opcode) != 0x13)
		return;
	pr_info("cerro-dp-rx owner=%u type=%u opcode=%#x len=%zu bytes=%*ph\n",
		le32_to_cpu(hdr->owner), le32_to_cpu(hdr->type),
		le32_to_cpu(hdr->opcode), len, (int)min_t(size_t, len, 48), data);
}

static void observe_state(void *priv, int state)
{
	pr_info("cerro-dp-rx service_state=%d (receive-only)\n", state);
}

static int observe_probe(struct platform_device *pdev)
{
	const unsigned int owners[] = { PMIC_GLINK_OWNER_USBC, PMIC_GLINK_OWNER_USBC_PAN };
	struct pmic_glink_client *client;
	int i;

	for (i = 0; i < ARRAY_SIZE(owners); i++) {
		client = devm_pmic_glink_client_alloc(&pdev->dev, owners[i],
				observe_rx, observe_state, NULL);
		if (IS_ERR(client))
			return PTR_ERR(client);
		pmic_glink_client_register(client);
	}
	pr_info("cerro-dp-rx ready (USB-C owners only; no TX)\n");
	return 0;
}

static struct platform_driver observe_driver = {
	.probe = observe_probe,
	.driver.name = "cerro-dp-observe",
};

static int __init observe_init(void)
{
	struct device *parent;
	struct platform_device_info info = {
		.name = "cerro-dp-observe",
		.id = PLATFORM_DEVID_NONE,
	};
	int ret;

	parent = bus_find_device_by_name(&platform_bus_type, NULL, "pmic-glink");
	if (!parent)
		return -ENODEV;
	if (!dev_get_drvdata(parent)) {
		put_device(parent);
		return -ENODEV;
	}
	ret = platform_driver_register(&observe_driver);
	if (ret) {
		put_device(parent);
		return ret;
	}
	info.parent = parent;
	observer = platform_device_register_full(&info);
	put_device(parent);
	if (IS_ERR(observer)) {
		ret = PTR_ERR(observer);
		platform_driver_unregister(&observe_driver);
		return ret;
	}
	if (!device_is_bound(&observer->dev)) {
		platform_device_unregister(observer);
		platform_driver_unregister(&observe_driver);
		return -ENODEV;
	}
	return 0;
}

static void __exit observe_exit(void)
{
	platform_device_unregister(observer);
	platform_driver_unregister(&observe_driver);
	pr_info("cerro-dp-rx removed\n");
}

module_init(observe_init);
module_exit(observe_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Passive Cerro USB-C PMIC GLINK receive observer");
