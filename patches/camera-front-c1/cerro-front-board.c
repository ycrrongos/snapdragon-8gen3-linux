// SPDX-License-Identifier: GPL-2.0-only
/* Add the front sensor graph once per boot. Never remove/reapply live graphs. */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/string.h>
static const unsigned char template[] __aligned(8) = {
#include "front-overlay.inc"
};
struct location { unsigned int offset, binding; };
static const struct location locations[] = {
#include "front-locations.inc"
};
static int overlay_id;
static int __init front_board_init(void)
{
 struct device_node *cc = NULL, *tlmm = NULL, *main = NULL, *io = NULL, *existing;
 const char *name;
 unsigned char *blob = NULL;
 unsigned int bindings[3], i;
 int ret = -EINVAL;
 if (!of_machine_is_compatible("nubia,cerro"))
  return -ENODEV;
 existing = of_find_node_by_path("/soc@0/cci@ac15000/i2c-bus@0/front@10");
 if (existing) { of_node_put(existing); return -EEXIST; }
 cc = of_find_node_by_path("/soc@0/clock-controller@ade0000");
 tlmm = of_find_node_by_path("/soc@0/pinctrl@f100000");
 main = of_find_node_by_path("/soc@0/cci@ac15000/i2c-bus@1/camera@10");
 if (!cc || !tlmm || !main || !of_device_is_compatible(cc,"qcom,sm8650-camcc") ||
     !of_device_is_compatible(tlmm,"qcom,sm8650-tlmm"))
  goto out;
 io = of_parse_phandle(main,"io-supply",0);
 if (!io || of_property_read_string(io,"regulator-name",&name) ||
     strcmp(name,"cerro-camera-l5m"))
  goto out;
 bindings[0] = cc->phandle; bindings[1] = tlmm->phandle; bindings[2] = io->phandle;
 for (i = 0; i < ARRAY_SIZE(bindings); i++)
  if (!bindings[i]) goto out;
 blob = kmemdup(template,sizeof(template),GFP_KERNEL);
 if (!blob) { ret = -ENOMEM; goto out; }
 for (i = 0; i < ARRAY_SIZE(locations); i++) {
  const struct location *loc = &locations[i];
  __be32 value;
  if (loc->binding >= ARRAY_SIZE(bindings) || loc->offset + sizeof(value) > sizeof(template))
   goto out;
  memcpy(&value,blob + loc->offset,sizeof(value));
  if (be32_to_cpu(value) != 0xca100001 + loc->binding)
   goto out;
  value = cpu_to_be32(bindings[loc->binding]);
  memcpy(blob + loc->offset,&value,sizeof(value));
 }
 ret = of_overlay_fdt_apply(blob,sizeof(template),&overlay_id,NULL);
 if (!ret) pr_info("Cerro front graph added once; no CAMSS rebind\n");
out:
 kfree(blob); of_node_put(io); of_node_put(main); of_node_put(tlmm); of_node_put(cc);
 return ret;
}
module_init(front_board_init);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Cerro OV12D2Q front camera graph, live validated providers");
