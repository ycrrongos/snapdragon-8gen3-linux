// SPDX-License-Identifier: GPL-2.0-only
/* OmniVision OV12D2Q on Cerro: audited factory D-PHY modes, runtime PM. */
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>
#include <media/v4l2-cci.h>
#include <media/v4l2-common.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-subdev.h>
#include "ov12d2q-regs.h"

#define EXP_MARGIN 16
/* Factory OP pixel throughput is1GHz, RAW10 over4 D-PHY lanes =>1.25GHz.
 * Timing register540 counts groups of8 output pixel periods. Scale both the
 * line length and timing pixel rate by8 so V4L2 line duration remains6.0006us.
 */
static const s64 link_frequencies[] = { 1250000000LL };
struct ov12d2q_mode {
 u32 width, height, llp, fll;
 s64 pixel_rate;
 u8 link_index;
 struct v4l2_rect crop;
 const struct cci_reg_sequence *registers;
 unsigned int num_registers;
};
static const struct ov12d2q_mode modes[] = {
 { 1920, 1080, 4320, 5555, 719928000LL, 0,
   {0, 0, 3840, 2160}, ov12d2q_mode1, ARRAY_SIZE(ov12d2q_mode1) },
 { 3840, 2160, 4320, 5555, 719928000LL, 0,
   {0, 0, 3840, 2160}, ov12d2q_mode0, ARRAY_SIZE(ov12d2q_mode0) },
};

struct ov12d2q {
 struct v4l2_subdev sd;
 struct media_pad pad;
 struct v4l2_ctrl_handler controls;
 struct v4l2_ctrl *exposure, *vblank, *hblank, *pixel_rate, *link_freq;
 const struct ov12d2q_mode *mode;
 struct regulator_bulk_data rails[1];
 struct gpio_desc *reset, *enable;
 struct clk *clock;
 struct regmap *regmap;
 struct mutex lock;
 bool streaming;
};

static struct ov12d2q *to_ov12d2q(struct v4l2_subdev *sd)
{
 return container_of(sd, struct ov12d2q, sd);
}

static int ov12d2q_power_on(struct device *dev)
{
 struct ov12d2q *sensor = to_ov12d2q(dev_get_drvdata(dev));
 int ret;
 gpiod_set_value_cansleep(sensor->reset, 1);
 usleep_range(2000, 2500);
 gpiod_set_value_cansleep(sensor->enable, 1);
 ret = regulator_enable(sensor->rails[0].consumer);
 if (ret)
  goto disable_gpio;
 if (regulator_get_voltage(sensor->rails[0].consumer) != 1800000) {
  ret = -ERANGE;
  goto disable_io;
 }
 gpiod_set_value_cansleep(sensor->reset, 0);
 usleep_range(5000, 6000);
 ret = clk_prepare_enable(sensor->clock);
 if (ret)
  goto assert_reset;
 usleep_range(2000, 2500);
 return 0;
assert_reset:
 gpiod_set_value_cansleep(sensor->reset, 1);
disable_io:
 regulator_disable(sensor->rails[0].consumer);
disable_gpio:
 gpiod_set_value_cansleep(sensor->enable, 0);
 return ret;
}

static int ov12d2q_power_off(struct device *dev)
{
 struct ov12d2q *sensor = to_ov12d2q(dev_get_drvdata(dev));
 clk_disable_unprepare(sensor->clock);
 usleep_range(1000, 1500);
 gpiod_set_value_cansleep(sensor->reset, 1);
 usleep_range(1000, 1500);
 regulator_disable(sensor->rails[0].consumer);
 gpiod_set_value_cansleep(sensor->enable, 0);
 return 0;
}

static int ov12d2q_identify(struct ov12d2q *sensor)
{
 u64 id;
 int ret = cci_read(sensor->regmap, CCI_REG16(0x300b), &id, NULL);

 if (ret)
  return ret;
 if (id != 0x1441)
  return dev_err_probe(sensor->sd.dev, -ENODEV, "unexpected chip ID 0x%04llx\n", id);
 return 0;
}

static int ov12d2q_set_control(struct v4l2_ctrl *ctrl)
{
 struct ov12d2q *sensor = container_of(ctrl->handler, struct ov12d2q, controls);
 struct device *dev = sensor->sd.dev;
 int ret = 0;

 if (ctrl->id == V4L2_CID_VBLANK)
  __v4l2_ctrl_modify_range(sensor->exposure, 4, sensor->mode->height + ctrl->val - EXP_MARGIN,
                          1, min_t(s64, 1000, sensor->mode->height + ctrl->val - EXP_MARGIN));
 if (!pm_runtime_get_if_in_use(dev))
  return 0;
 cci_write(sensor->regmap, CCI_REG8(0x3208), 0x00, &ret);
 switch (ctrl->id) {
 case V4L2_CID_EXPOSURE:
  cci_write(sensor->regmap, CCI_REG16(0x3501), ctrl->val, &ret);
  break;
 case V4L2_CID_ANALOGUE_GAIN:
  cci_write(sensor->regmap, CCI_REG16(0x3508), ctrl->val, &ret);
  break;
 case V4L2_CID_VBLANK:
  cci_write(sensor->regmap, CCI_REG16(0x380e), sensor->mode->height + ctrl->val, &ret);
  break;
 default:
  ret = -EINVAL;
 }
 /* Release group hold even after a failed control write. */
 {
  int release = 0;
  cci_write(sensor->regmap, CCI_REG8(0x3208), 0x10, &release);
  cci_write(sensor->regmap, CCI_REG8(0x3208), 0xa0, &release);
  if (!ret)
   ret = release;
 }
 pm_runtime_put(dev);
 return ret;
}
static const struct v4l2_ctrl_ops ov12d2q_control_ops = { .s_ctrl = ov12d2q_set_control };

/* The real OV12D2Q Android static CFA is BGGR; confirm real scenes after capture. */
static void ov12d2q_format(const struct ov12d2q_mode *mode,
                          struct v4l2_mbus_framefmt *format)
{
 *format = (struct v4l2_mbus_framefmt) {
  .width = mode->width, .height = mode->height, .code = MEDIA_BUS_FMT_SBGGR10_1X10,
  .field = V4L2_FIELD_NONE, .colorspace = V4L2_COLORSPACE_RAW,
  .ycbcr_enc = V4L2_YCBCR_ENC_DEFAULT, .quantization = V4L2_QUANTIZATION_FULL_RANGE,
  .xfer_func = V4L2_XFER_FUNC_NONE,
 };
}
static int ov12d2q_get_format(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
                             struct v4l2_subdev_format *format)
{
 struct ov12d2q *sensor = to_ov12d2q(sd);
 if (format->pad)
  return -EINVAL;
 mutex_lock(&sensor->lock);
 if (format->which == V4L2_SUBDEV_FORMAT_TRY)
  format->format = *v4l2_subdev_state_get_format(state, 0);
 else
  ov12d2q_format(sensor->mode, &format->format);
 mutex_unlock(&sensor->lock);
 return 0;
}
static int ov12d2q_update_controls(struct ov12d2q *sensor)
{
 const struct ov12d2q_mode *mode = sensor->mode;
 s64 blank = mode->llp - mode->width;
 int ret;
 ret = __v4l2_ctrl_s_ctrl(sensor->link_freq, mode->link_index);
 if (ret)
  return ret;
 ret = __v4l2_ctrl_s_ctrl_int64(sensor->pixel_rate, mode->pixel_rate);
 if (ret)
  return ret;
 ret = __v4l2_ctrl_modify_range(sensor->hblank, blank, blank, 1, blank);
 if (ret)
  return ret;
 blank = mode->fll - mode->height;
 ret = __v4l2_ctrl_modify_range(sensor->vblank, blank, 65535 - mode->height, 1, blank);
 if (ret)
  return ret;
 return __v4l2_ctrl_s_ctrl(sensor->vblank, blank);
}
static int ov12d2q_set_format(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
                             struct v4l2_subdev_format *format)
{
 struct ov12d2q *sensor = to_ov12d2q(sd);
 const struct ov12d2q_mode *mode;
 int ret = 0;
 if (format->pad)
  return -EINVAL;
 mode = v4l2_find_nearest_size(modes, ARRAY_SIZE(modes), width, height,
                               format->format.width, format->format.height);
 mutex_lock(&sensor->lock);
 if (format->which == V4L2_SUBDEV_FORMAT_ACTIVE && sensor->streaming && mode != sensor->mode) {
  ret = -EBUSY;
  goto unlock;
 }
 ov12d2q_format(mode, &format->format);
 if (format->which == V4L2_SUBDEV_FORMAT_TRY) {
  *v4l2_subdev_state_get_format(state, 0) = format->format;
 } else if (mode != sensor->mode) {
  const struct ov12d2q_mode *old = sensor->mode;
  sensor->mode = mode;
  ret = ov12d2q_update_controls(sensor);
  if (ret) {
   sensor->mode = old;
   ov12d2q_update_controls(sensor);
  }
 }
unlock:
 mutex_unlock(&sensor->lock);
 return ret;
}
static int ov12d2q_init_state(struct v4l2_subdev *sd, struct v4l2_subdev_state *state)
{
 struct v4l2_subdev_format format = { .which = V4L2_SUBDEV_FORMAT_TRY };
 ov12d2q_format(&modes[0], &format.format);
 return ov12d2q_set_format(sd, state, &format);
}
static int ov12d2q_enum_code(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
                            struct v4l2_subdev_mbus_code_enum *code)
{
 if (code->pad || code->index)
  return -EINVAL;
 code->code = MEDIA_BUS_FMT_SBGGR10_1X10;
 return 0;
}
static int ov12d2q_enum_size(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
                            struct v4l2_subdev_frame_size_enum *size)
{
 if (size->pad || size->index >= ARRAY_SIZE(modes) || size->code != MEDIA_BUS_FMT_SBGGR10_1X10)
  return -EINVAL;
 size->min_width = size->max_width = modes[size->index].width;
 size->min_height = size->max_height = modes[size->index].height;
 return 0;
}
static int ov12d2q_get_selection(struct v4l2_subdev *sd, struct v4l2_subdev_state *state,
                                struct v4l2_subdev_selection *selection)
{
 struct ov12d2q *sensor = to_ov12d2q(sd);
 if (selection->pad)
  return -EINVAL;
 switch (selection->target) {
 case V4L2_SEL_TGT_NATIVE_SIZE:
 case V4L2_SEL_TGT_CROP_BOUNDS:
  selection->r = (struct v4l2_rect) { 0, 0, 3840, 2160 };
  return 0;
 case V4L2_SEL_TGT_CROP_DEFAULT:
  selection->r = modes[1].crop;
  return 0;
 case V4L2_SEL_TGT_CROP:
  mutex_lock(&sensor->lock);
  if (selection->which == V4L2_SUBDEV_FORMAT_TRY) {
   const struct v4l2_mbus_framefmt *f = v4l2_subdev_state_get_format(state, 0);
   const struct ov12d2q_mode *mode = v4l2_find_nearest_size(modes, ARRAY_SIZE(modes),
                                                        width, height, f->width, f->height);
   selection->r = mode->crop;
  } else {
   selection->r = sensor->mode->crop;
  }
  mutex_unlock(&sensor->lock);
  return 0;
 default:
  return -EINVAL;
 }
}
static int ov12d2q_stream(struct v4l2_subdev *sd, int enable)
{
 struct ov12d2q *sensor = to_ov12d2q(sd);
 struct device *dev = sd->dev;
 int ret = 0;

 mutex_lock(&sensor->lock);
 if (!!enable == sensor->streaming)
  goto unlock;
 if (enable) {
  ret = pm_runtime_resume_and_get(dev);
  if (ret < 0)
   goto unlock;
  ret = ov12d2q_identify(sensor);
  if (!ret)
   ret = cci_write(sensor->regmap, CCI_REG8(0x0103), 1, NULL);
  if (!ret)
   usleep_range(5000, 6000);
  if (!ret)
   ret = cci_multi_reg_write(sensor->regmap, ov12d2q_global, ARRAY_SIZE(ov12d2q_global), NULL);
  if (!ret)
   ret = cci_multi_reg_write(sensor->regmap, sensor->mode->registers, sensor->mode->num_registers, NULL);
  if (!ret)
   ret = __v4l2_ctrl_handler_setup(&sensor->controls);
  if (!ret)
   ret = cci_write(sensor->regmap, CCI_REG8(0x0100), 1, NULL);
  if (ret) {
   cci_write(sensor->regmap, CCI_REG8(0x0100), 0, NULL);
   pm_runtime_put_sync(dev);
   goto unlock;
  }
 } else {
  ret = cci_write(sensor->regmap, CCI_REG8(0x0100), 0, NULL);
  /* Power off releases the stream even if I2C no longer responds. */
  pm_runtime_put_sync(dev);
 }
 sensor->streaming = !!enable;
unlock:
 mutex_unlock(&sensor->lock);
 return ret;
}
static const struct v4l2_subdev_pad_ops ov12d2q_pad_ops = {
 .enum_mbus_code = ov12d2q_enum_code, .enum_frame_size = ov12d2q_enum_size,
 .get_fmt = ov12d2q_get_format, .set_fmt = ov12d2q_set_format,
 .get_selection = ov12d2q_get_selection,
};
static const struct v4l2_subdev_video_ops ov12d2q_video_ops = { .s_stream = ov12d2q_stream };
static const struct v4l2_subdev_internal_ops ov12d2q_internal_ops = { .init_state = ov12d2q_init_state };
static const struct v4l2_subdev_ops ov12d2q_ops = { .pad = &ov12d2q_pad_ops, .video = &ov12d2q_video_ops };

static int ov12d2q_probe(struct i2c_client *client)
{
 struct device *dev = &client->dev;
 struct ov12d2q *sensor;
 const char *names[] = { "io" };
 int i, ret;

 sensor = devm_kzalloc(dev, sizeof(*sensor), GFP_KERNEL);
 if (!sensor)
  return -ENOMEM;
 sensor->mode = &modes[0];
 mutex_init(&sensor->lock);
 v4l2_i2c_subdev_init(&sensor->sd, client, &ov12d2q_ops);
 sensor->sd.internal_ops = &ov12d2q_internal_ops;
 sensor->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
 sensor->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;
 sensor->pad.flags = MEDIA_PAD_FL_SOURCE;
 sensor->reset = devm_gpiod_get(dev, "reset", GPIOD_OUT_HIGH);
 if (IS_ERR(sensor->reset))
  return dev_err_probe(dev, PTR_ERR(sensor->reset), "reset\n");
 sensor->enable = devm_gpiod_get(dev, "enable", GPIOD_OUT_LOW);
 if (IS_ERR(sensor->enable))
  return dev_err_probe(dev, PTR_ERR(sensor->enable), "analog switch\n");
 sensor->clock = devm_clk_get(dev, NULL);
 if (IS_ERR(sensor->clock))
  return dev_err_probe(dev, PTR_ERR(sensor->clock), "MCLK4\n");
 ret = clk_set_rate(sensor->clock, 24000000);
 if (ret || clk_get_rate(sensor->clock) != 24000000)
  return ret ?: -ERANGE;
 for (i = 0; i < ARRAY_SIZE(names); i++)
  sensor->rails[i].supply = names[i];
 ret = devm_regulator_bulk_get(dev, ARRAY_SIZE(sensor->rails), sensor->rails);
 if (ret)
  return dev_err_probe(dev, ret, "supplies\n");
 sensor->regmap = devm_cci_regmap_init_i2c(client, 16);
 if (IS_ERR(sensor->regmap))
  return PTR_ERR(sensor->regmap);
 ret = ov12d2q_power_on(dev);
 if (ret)
  return ret;
 ret = ov12d2q_identify(sensor);
 ov12d2q_power_off(dev);
 if (ret)
  return ret;
 pm_runtime_set_suspended(dev);
 pm_runtime_enable(dev);
 ret = media_entity_pads_init(&sensor->sd.entity, 1, &sensor->pad);
 if (ret)
  goto disable_pm;
 v4l2_ctrl_handler_init(&sensor->controls, 9);
 sensor->controls.lock = &sensor->lock;
 sensor->link_freq = v4l2_ctrl_new_int_menu(&sensor->controls, NULL, V4L2_CID_LINK_FREQ,
                                           ARRAY_SIZE(link_frequencies)-1, 0, link_frequencies);
 if (sensor->link_freq)
  sensor->link_freq->flags |= V4L2_CTRL_FLAG_READ_ONLY;
 sensor->pixel_rate = v4l2_ctrl_new_std(&sensor->controls, NULL, V4L2_CID_PIXEL_RATE,
                                        719928000LL, 719928000LL, 1, modes[0].pixel_rate);
 if (sensor->pixel_rate)
  sensor->pixel_rate->flags |= V4L2_CTRL_FLAG_READ_ONLY;
 sensor->hblank = v4l2_ctrl_new_std(&sensor->controls, NULL, V4L2_CID_HBLANK,
                                    modes[0].llp-modes[0].width, modes[0].llp-modes[0].width,
                                    1, modes[0].llp-modes[0].width);
 if (sensor->hblank)
  sensor->hblank->flags |= V4L2_CTRL_FLAG_READ_ONLY;
 sensor->exposure = v4l2_ctrl_new_std(&sensor->controls, &ov12d2q_control_ops,
                                     V4L2_CID_EXPOSURE, 4, modes[0].fll-EXP_MARGIN, 1, 1000);
 sensor->vblank = v4l2_ctrl_new_std(&sensor->controls, &ov12d2q_control_ops, V4L2_CID_VBLANK,
                                   modes[0].fll-modes[0].height, 65535-modes[0].height,
                                   1, modes[0].fll-modes[0].height);
 v4l2_ctrl_new_std(&sensor->controls, &ov12d2q_control_ops, V4L2_CID_ANALOGUE_GAIN, 256, 3968, 2, 256);
 v4l2_ctrl_new_std_menu(&sensor->controls, NULL, V4L2_CID_CAMERA_ORIENTATION,
                       V4L2_CAMERA_ORIENTATION_FRONT, 0, V4L2_CAMERA_ORIENTATION_FRONT);
 v4l2_ctrl_new_std(&sensor->controls, NULL, V4L2_CID_CAMERA_SENSOR_ROTATION, 270, 270, 1, 270);
 sensor->sd.ctrl_handler = &sensor->controls;
 if (sensor->controls.error) {
  ret = sensor->controls.error;
  goto cleanup;
 }
 ret = v4l2_async_register_subdev_sensor(&sensor->sd);
 if (ret)
  goto cleanup;
 dev_info(dev, "OV12D2Q identified; 1920x1080 + 3840x2160 factory modes registered, powered off\n");
 return 0;
cleanup:
 v4l2_ctrl_handler_free(&sensor->controls);
 media_entity_cleanup(&sensor->sd.entity);
disable_pm:
 pm_runtime_disable(dev);
 return ret;
}
static void ov12d2q_remove(struct i2c_client *client)
{
 struct ov12d2q *sensor = to_ov12d2q(i2c_get_clientdata(client));
 v4l2_async_unregister_subdev(&sensor->sd);
 if (sensor->streaming)
  ov12d2q_stream(&sensor->sd, 0);
 pm_runtime_disable(&client->dev);
 if (!pm_runtime_status_suspended(&client->dev))
  ov12d2q_power_off(&client->dev);
 v4l2_ctrl_handler_free(&sensor->controls);
 media_entity_cleanup(&sensor->sd.entity);
}
static const struct dev_pm_ops ov12d2q_pm_ops = {
 SET_RUNTIME_PM_OPS(ov12d2q_power_off, ov12d2q_power_on, NULL)
};
static const struct of_device_id ov12d2q_match[] = {
 { .compatible = "ovti,ov12d2q" },
 {}
};
MODULE_DEVICE_TABLE(of, ov12d2q_match);
static struct i2c_driver ov12d2q_driver = {
 .driver = { .name = "ov12d2q-cerro", .of_match_table = ov12d2q_match, .pm = &ov12d2q_pm_ops },
 .probe = ov12d2q_probe, .remove = ov12d2q_remove,
};
module_i2c_driver(ov12d2q_driver);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("OmniVision OV12D2Q Cerro factory D-PHY modes");
