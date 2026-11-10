// SPDX-License-Identifier: GPL-2.0
/*
 * Apply a pmic-glink node on a Cerro kernel whose builtin DTB predates it.
 * qcom_battmgr / ucsi_glink bind only after this node exists.
 */
#include <linux/module.h>
#include <linux/of.h>

static int ovcs_id = -1;

/* Generated next to this file as cerro-pmic-glink-overlay.dtbo.inc */
static const unsigned char cerro_pmic_glink_dtbo[] = {
#include "cerro-pmic-glink-overlay.dtbo.inc"
};

static int __init cerro_pmic_glink_overlay_init(void)
{
	int ret;

	ret = of_overlay_fdt_apply(cerro_pmic_glink_dtbo, sizeof(cerro_pmic_glink_dtbo),
				   &ovcs_id, NULL);
	if (ret) {
		pr_err("cerro-pmic-glink: overlay apply failed: %d\n", ret);
		return ret;
	}
	pr_info("cerro-pmic-glink: overlay applied (id=%d)\n", ovcs_id);
	return 0;
}

static void __exit cerro_pmic_glink_overlay_exit(void)
{
	if (ovcs_id >= 0)
		of_overlay_remove(&ovcs_id);
}

module_init(cerro_pmic_glink_overlay_init);
module_exit(cerro_pmic_glink_overlay_exit);

MODULE_DESCRIPTION("Cerro runtime pmic-glink DT overlay");
MODULE_LICENSE("GPL");
