// SPDX-License-Identifier: GPL-2.0-only
/* Bounded one-shot chip identification. No streaming or lens-control writes. */
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>

static const unsigned char overlay[] __aligned(8) = {
#include "camera-identify-overlay.inc"
};
static int overlay_id = -1;

static int camera_id_probe(struct i2c_client *client)
{
 struct device *dev = &client->dev;
 struct regulator_bulk_data rails[] = {
  { .supply = "af" }, { .supply = "digital" },
  { .supply = "io" }, { .supply = "analog" },
 };
 const int expected_uv[] = { 2800000, 1104000, 1800000, 2960000 };
 struct gpio_desc *reset, *enable;
 struct clk *clock;
 u8 address[] = { 0x00, 0x16 }, data[2] = {};
 struct i2c_msg msgs[] = {
  { .addr = client->addr, .len = sizeof(address), .buf = address },
  { .addr = client->addr, .flags = I2C_M_RD, .len = sizeof(data), .buf = data },
 };
 int ret, cleanup, count = 0, i;
 bool clock_on = false;
 u16 id = 0;

 if (client->addr != 0x10)
  return -EINVAL;
 reset = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
 if (IS_ERR(reset))
  return dev_err_probe(dev, PTR_ERR(reset), "reset GPIO\n");
 enable = devm_gpiod_get(dev, "enable", GPIOD_OUT_LOW);
 if (IS_ERR(enable))
  return dev_err_probe(dev, PTR_ERR(enable), "analog switch GPIO\n");
 clock = devm_clk_get(dev, NULL);
 if (IS_ERR(clock))
  return dev_err_probe(dev, PTR_ERR(clock), "MCLK1\n");
 ret = clk_set_rate(clock, 24000000);
 if (ret || clk_get_rate(clock) != 24000000)
  return dev_err_probe(dev, ret ?: -ERANGE, "MCLK1 must be 24MHz\n");
 ret = regulator_bulk_get(dev, ARRAY_SIZE(rails), rails);
 if (ret)
  return dev_err_probe(dev, ret, "fixed factory supplies\n");
 /* Exact factory up sequence: AF, GPIO13, digital, IO, custom1, clock, reset. */
 for (i = 0; i < ARRAY_SIZE(rails); i++) {
  ret = regulator_enable(rails[i].consumer);
  if (ret)
   goto power_down;
  count++;
  if (regulator_get_voltage(rails[i].consumer) != expected_uv[i]) {
   ret = -ERANGE;
   goto power_down;
  }
  if (i == 0) {
   usleep_range(1000, 1500);
   gpiod_set_value_cansleep(enable, 1);
  }
 }
 usleep_range(10000, 11000);
 ret = clk_prepare_enable(clock);
 if (ret)
  goto power_down;
 clock_on = true;
 usleep_range(5000, 6000);
 gpiod_set_value_cansleep(reset, 0);
 usleep_range(5000, 6000);
 ret = i2c_transfer(client->adapter, msgs, ARRAY_SIZE(msgs));
 if (ret == ARRAY_SIZE(msgs)) {
  id = (data[0] << 8) | data[1];
  ret = (id == 0x0800 || id == 0x0906) ? 0 : -ENODEV;
 } else if (ret >= 0) {
  ret = -EIO;
 }
power_down:
 gpiod_set_value_cansleep(reset, 1);
 if (clock_on)
  clk_disable_unprepare(clock);
 while (count) {
  count--;
  cleanup = regulator_disable(rails[count].consumer);
  if (cleanup && !ret)
   ret = cleanup;
  if (count == 3)
   usleep_range(1000, 1500);
  if (count == 1)
   gpiod_set_value_cansleep(enable, 0);
 }
 gpiod_set_value_cansleep(enable, 0);
 regulator_bulk_free(ARRAY_SIZE(rails), rails);
 dev_info(dev, "one-shot ID=0x%04x result=%d; reset asserted, owned power/clock released\n", id, ret);
 return ret;
}

static const struct of_device_id camera_id_of_match[] = {
 { .compatible = "nubia,cerro-camera-id" }, {}
};
MODULE_DEVICE_TABLE(of, camera_id_of_match);
static struct i2c_driver camera_id_driver = {
 .driver = { .name = "cerro-camera-id", .of_match_table = camera_id_of_match },
 .probe = camera_id_probe,
};

static bool expected_phandle(const char *path, u32 expected)
{
 struct device_node *np = of_find_node_by_path(path);
 bool match = np && np->phandle == expected;
 of_node_put(np);
 return match;
}

static int __init camera_identify_init(void)
{
 int ret;
 if (!of_machine_is_compatible("nubia,cerro") ||
     !expected_phandle("/soc@0/clock-controller@ade0000", 230) ||
     !expected_phandle("/soc@0/pinctrl@f100000", 143))
  return -EINVAL;
 ret = i2c_add_driver(&camera_id_driver);
 if (ret)
  return ret;
 ret = of_overlay_fdt_apply(overlay, sizeof(overlay), &overlay_id, NULL);
 if (ret)
  i2c_del_driver(&camera_id_driver);
 return ret;
}
module_init(camera_identify_init);
/* Deliberately no module_exit: avoid unsafe OF overlay remove/reapply cycles.
 * The one-shot probe releases its resources; reboot removes this experiment. */
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Cerro one-shot read-only main camera identification");
