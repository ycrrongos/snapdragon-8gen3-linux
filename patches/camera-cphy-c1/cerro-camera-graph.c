// SPDX-License-Identifier: GPL-2.0-only
#include <linux/module.h>
#include <linux/of.h>
static const unsigned char graph[] __aligned(8) = {
#include "camera-graph-overlay.inc"
};
static int overlay_id;
static int __init graph_init(void)
{
 if (!of_machine_is_compatible("nubia,cerro"))
  return -EINVAL;
 return of_overlay_fdt_apply(graph, sizeof(graph), &overlay_id, NULL);
}
module_init(graph_init);
/* Runtime experiment cleared by reboot; do not remove/reapply OF graph nodes. */
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Cerro IMX800 CSIPHY1 runtime graph");
