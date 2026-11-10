// SPDX-License-Identifier: GPL-2.0-only
/* Board graph only. No I/O, firmware writing or invented provider phandles. */
#include <linux/module.h>
#include <linux/of.h>
#include <linux/slab.h>
#include <linux/string.h>
static const unsigned char template[] __aligned(8) = {
#include "camera-board-overlay.inc"
};
struct patch_location { unsigned int offset, binding; };
static const struct patch_location locations[] = {
#include "camera-board-locations.inc"
};
static unsigned int focus_min, focus_max;
module_param(focus_min, uint, 0444);
module_param(focus_max, uint, 0444);
MODULE_PARM_DESC(focus_min, "Infinity DAC from THIS unit's IMX800 EEPROM");
MODULE_PARM_DESC(focus_max, "Macro DAC from THIS unit's IMX800 EEPROM");
static int overlay_id;
static int __init board_init(void)
{
 struct device_node *camcc = NULL, *tlmm = NULL, *cci1 = NULL, *state = NULL, *existing;
 unsigned int bindings[6], i;
 unsigned char *blob = NULL;
 int ret = -EINVAL;
 if (!of_machine_is_compatible("nubia,cerro") ||
     !focus_min || focus_min >= focus_max || focus_max > 1023)
  return -EINVAL;
 existing = of_find_node_by_path("/soc@0/rsc@17a00000/camera-pm8010m-regulators");
 if (existing) {
  of_node_put(existing);
  return -EEXIST; /* One board overlay per boot; never replace a live camera. */
 }
 camcc = of_find_node_by_path("/soc@0/clock-controller@ade0000");
 tlmm = of_find_node_by_path("/soc@0/pinctrl@f100000");
 cci1 = of_find_node_by_path("/soc@0/cci@ac16000");
 if (!camcc || !tlmm || !cci1 ||
     !of_device_is_compatible(camcc, "qcom,sm8650-camcc") ||
     !of_device_is_compatible(tlmm, "qcom,sm8650-tlmm"))
  goto out;
 bindings[0] = camcc->phandle; bindings[1] = tlmm->phandle;
 if (!bindings[0] || !bindings[1] ||
     of_property_read_u32_index(cci1, "pinctrl-0", 0, &bindings[2]) ||
     of_property_read_u32_index(cci1, "pinctrl-1", 0, &bindings[3]))
  goto out;
 state = of_find_node_by_phandle(bindings[2]);
 if (!state || !of_node_name_eq(state, "cci1-0-default-state"))
  goto out;
 of_node_put(state);
 state = of_find_node_by_phandle(bindings[3]);
 if (!state || !of_node_name_eq(state, "cci1-0-sleep-state"))
  goto out;
 bindings[4] = focus_min; bindings[5] = focus_max;
 blob = kmemdup(template, sizeof(template), GFP_KERNEL);
 if (!blob) { ret = -ENOMEM; goto out; }
 for (i = 0; i < ARRAY_SIZE(locations); i++) {
  const struct patch_location *location = &locations[i];
  __be32 value;
  if (location->binding >= ARRAY_SIZE(bindings) ||
      location->offset + sizeof(value) > sizeof(template))
   goto out;
  memcpy(&value, blob + location->offset, sizeof(value));
  if (be32_to_cpu(value) != 0xca000001 + location->binding)
   goto out;
  value = cpu_to_be32(bindings[location->binding]);
  memcpy(blob + location->offset, &value, sizeof(value));
 }
 ret = of_overlay_fdt_apply(blob, sizeof(template), &overlay_id, NULL);
 if (!ret)
  pr_info("Cerro camera board graph applied, OTP lens %u..%u\n", focus_min, focus_max);
out:
 kfree(blob);
 of_node_put(state); of_node_put(cci1); of_node_put(tlmm); of_node_put(camcc);
 return ret;
}
module_init(board_init);
/* Intentionally no exit: OF camera graphs remain for this boot. */
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Cerro native camera board graph with live OF providers");
