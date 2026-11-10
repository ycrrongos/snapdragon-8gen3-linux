// SPDX-License-Identifier: GPL-2.0-only
/* Cerro AK7316 VCM: audited factory volatile interface, per-unit OTP limits. */
#include <linux/delay.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/property.h>
#include <linux/regulator/consumer.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>

struct ak7316 {
 struct v4l2_subdev sd;
 struct v4l2_ctrl_handler controls;
 struct v4l2_ctrl *focus;
 struct regulator *supply;
 unsigned int minimum, maximum, position;
};
static struct ak7316 *to_ak7316(struct v4l2_subdev *sd)
{
 return container_of(sd, struct ak7316, sd);
}
static int ak7316_write(struct ak7316 *vcm, u8 address, u16 value, int size)
{
 struct i2c_client *client = v4l2_get_subdevdata(&vcm->sd);
 u8 message[3] = { address };
 int ret;
 if (size == 2)
  message[1] = value >> 8;
 message[size] = value & 0xff;
 ret = i2c_master_send(client, message, size + 1);
 if (ret != size + 1)
  dev_err(&client->dev, "VCM write reg%02x value%04x size%d result%d\n", address, value, size, ret);
 return ret == size + 1 ? 0 : ret < 0 ? ret : -EIO;
}
static int ak7316_move(struct ak7316 *vcm, unsigned int target)
{
 int ret, next;
 if (target < vcm->minimum || target > vcm->maximum)
  return -ERANGE;
 do {
  next = clamp_t(int, target, (int)vcm->position - 16,
                  (int)vcm->position + 16);
  ret = ak7316_write(vcm, 0, next << 6, 2);
  if (ret)
   return ret;
  vcm->position = next;
  usleep_range(1000, 1100);
 } while (vcm->position != target);
 return 0;
}
static int ak7316_control(struct v4l2_ctrl *ctrl)
{
 struct ak7316 *vcm = container_of(ctrl->handler, struct ak7316, controls);
 struct device *dev = vcm->sd.dev;
 int ret;
 if (ctrl->id != V4L2_CID_FOCUS_ABSOLUTE)
  return -EINVAL;
 ret = pm_runtime_get_if_in_use(dev);
 if (ret <= 0)
  return ret;
 ret = ak7316_move(vcm, ctrl->val);
 pm_runtime_put(dev);
 return ret;
}
static const struct v4l2_ctrl_ops ak7316_control_ops = { .s_ctrl = ak7316_control };
static int ak7316_resume(struct device *dev)
{
 struct ak7316 *vcm = to_ak7316(dev_get_drvdata(dev));
 int ret;
 ret = regulator_enable(vcm->supply);
 if (ret)
  return dev_err_probe(dev, ret, "VAF enable failed\n");
 if (regulator_get_voltage(vcm->supply) != 2800000) {
  dev_err(dev, "VAF readback %d !=2800000\n", regulator_get_voltage(vcm->supply));
  ret = -ERANGE;
  goto disable;
 }
 usleep_range(10000, 11000); /* Factory VAF-on delay10ms. */
 ret = ak7316_write(vcm, 2, 0x40, 1);
 if (ret)
  goto disable;
 usleep_range(1000, 1100); /* Match verified on-device init spacing. */
 ret = ak7316_write(vcm, 2, 0, 1);
 if (ret)
  goto disable;
 usleep_range(1000, 1100); /* Match verified on-device init spacing. */
 vcm->position = vcm->minimum;
 ret = ak7316_move(vcm, vcm->minimum);
 if (!ret)
  ret = ak7316_move(vcm, vcm->focus->val);
 if (!ret)
  return 0;
 ak7316_write(vcm, 2, 0x40, 1);
disable:
 regulator_disable(vcm->supply);
 return ret;
}
static int ak7316_suspend(struct device *dev)
{
 struct ak7316 *vcm = to_ak7316(dev_get_drvdata(dev));
 int ret, standby, power;
 ret = ak7316_move(vcm, vcm->minimum);
 standby = ak7316_write(vcm, 2, 0x40, 1);
 power = regulator_disable(vcm->supply);
 if (ret || standby)
  dev_warn(dev, "VCM parking/standby I2C failure: %d/%d\n", ret, standby);
 return power;
}
static int ak7316_open(struct v4l2_subdev *sd, struct v4l2_subdev_fh *fh)
{
 int ret = pm_runtime_resume_and_get(sd->dev);
 if (ret < 0)
  dev_err(sd->dev, "VCM open PM resume failed%d\n", ret);
 return ret;
}
static int ak7316_close(struct v4l2_subdev *sd, struct v4l2_subdev_fh *fh)
{
 return pm_runtime_put_sync(sd->dev);
}
static const struct v4l2_subdev_internal_ops ak7316_internal_ops = {
 .open = ak7316_open, .close = ak7316_close,
};
static const struct v4l2_subdev_ops ak7316_ops = {};
static int ak7316_probe(struct i2c_client *client)
{
 struct device *dev = &client->dev;
 struct ak7316 *vcm;
 int ret;
 vcm = devm_kzalloc(dev, sizeof(*vcm), GFP_KERNEL);
 if (!vcm)
  return -ENOMEM;
 /* Prototype DT values MUST come from this unit's EEPROM, no default sweep. */
 ret = device_property_read_u32(dev, "asahi-kasei,focus-min", &vcm->minimum);
 if (ret)
  return ret;
 ret = device_property_read_u32(dev, "asahi-kasei,focus-max", &vcm->maximum);
 if (ret)
  return ret;
 if (!vcm->minimum || vcm->minimum >= vcm->maximum || vcm->maximum > 1023)
  return -EINVAL;
 vcm->supply = devm_regulator_get(dev, "vdd");
 if (IS_ERR(vcm->supply))
  return dev_err_probe(dev, PTR_ERR(vcm->supply), "VAF supply unavailable\n");
 v4l2_i2c_subdev_init(&vcm->sd, client, &ak7316_ops);
 vcm->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
 vcm->sd.internal_ops = &ak7316_internal_ops;
 vcm->sd.entity.function = MEDIA_ENT_F_LENS;
 v4l2_ctrl_handler_init(&vcm->controls, 1);
 vcm->focus = v4l2_ctrl_new_std(&vcm->controls, &ak7316_control_ops,
                               V4L2_CID_FOCUS_ABSOLUTE, vcm->minimum,
                               vcm->maximum, 1, vcm->minimum);
 vcm->sd.ctrl_handler = &vcm->controls;
 ret = vcm->controls.error;
 if (ret)
  goto cleanup;
 ret = media_entity_pads_init(&vcm->sd.entity, 0, NULL);
 if (ret)
  goto cleanup;
 pm_runtime_set_suspended(dev);
 pm_runtime_enable(dev);
 ret = v4l2_async_register_subdev(&vcm->sd);
 if (ret) {
  pm_runtime_disable(dev);
  goto cleanup;
 }
 dev_info(dev, "AK7316 lens registered, OTP range%u..%u, powered off\n",
          vcm->minimum, vcm->maximum);
 return 0;
cleanup:
 v4l2_ctrl_handler_free(&vcm->controls);
 media_entity_cleanup(&vcm->sd.entity);
 return ret;
}
static void ak7316_remove(struct i2c_client *client)
{
 struct v4l2_subdev *sd = i2c_get_clientdata(client);
 struct ak7316 *vcm = to_ak7316(sd);
 v4l2_async_unregister_subdev(sd);
 pm_runtime_disable(&client->dev);
 if (!pm_runtime_status_suspended(&client->dev))
  ak7316_suspend(&client->dev);
 v4l2_ctrl_handler_free(&vcm->controls);
 media_entity_cleanup(&sd->entity);
}
static const struct dev_pm_ops ak7316_pm_ops = {
 SET_RUNTIME_PM_OPS(ak7316_suspend, ak7316_resume, NULL)
};
static const struct of_device_id ak7316_match[] = {
 { .compatible = "asahi-kasei,ak7316-cerro" }, {}
};
MODULE_DEVICE_TABLE(of, ak7316_match);
static struct i2c_driver ak7316_driver = {
 .driver = { .name = "ak7316-cerro", .of_match_table = ak7316_match, .pm = &ak7316_pm_ops },
 .probe = ak7316_probe, .remove = ak7316_remove,
};
module_i2c_driver(ak7316_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Cerro AK7316 calibrated V4L2 lens prototype");
