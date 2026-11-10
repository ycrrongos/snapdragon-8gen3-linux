// SPDX-License-Identifier: GPL-2.0-only
#include <linux/module.h>
#include <linux/of.h>
static const unsigned char overlay[] __aligned(8) = {
#include "camera-lens-overlay.inc"
};
static int overlay_id;
static int __init lens_graph_init(void)
{
 if (!of_machine_is_compatible("nubia,cerro"))
  return -EINVAL;
 return of_overlay_fdt_apply(overlay, sizeof(overlay), &overlay_id, NULL);
}
module_init(lens_graph_init);
/* Prototype graph remains until reboot, never remove/reapply. */
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Cerro AK7316 lens runtime graph");
