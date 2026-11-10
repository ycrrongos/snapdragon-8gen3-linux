// SPDX-License-Identifier: GPL-2.0-only
/*
 * Driver for ZTE BF068 (Raydium RM692H0) 1116x2480 CMD-mode DSC DSI panel.
 *
 * Reconstructed 2026-10-31 from the .cursor session archive (rong backup
 * 20261013): the s5an..s5ew bisect history in the LOA_Nubia_Z60U agent
 * transcripts. Key lessons baked in:
 *   - s5an/s5ao/s5aq: vendor packets must go out with their exact MIPI dtype
 *     (0x39 long write even for 2-byte FE page selects; 0x15 short with param).
 *   - s5ar/s5at: wake (0x11) BEFORE the FE body; FE-before-wake bricks RX.
 *   - s5ba: 0x15 B3 7F is a poison packet that bricks the panel RX (skipped).
 *   - s5bq: PPS must be packed like msm dsi_populate_dsc_params
 *     (drm_dsc_setup_rc_params PRE_SCR) so chunk=698 / xmit=410 match FE D2.
 *   - enable(): re-kick 0x11/0x29 + PPS + compression after host enable
 *     (prepare_prev_first), brightness is direct (s5bt superseded the inverted experiment).
 */

#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/regulator/consumer.h>

#include <drm/display/drm_dsc.h>
#include <drm/display/drm_dsc_helper.h>
#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>

#include <video/mipi_display.h>

/* MSM mode query restored with the original runtime refresh support. */
extern const struct drm_display_mode *
msm_dsi_host_get_display_mode(struct mipi_dsi_host *host);

struct rm692h0_panel {
	struct drm_panel panel;
	struct mipi_dsi_device *dsi;
	struct regulator_bulk_data *supplies;
	struct gpio_desc *reset_gpio;
	struct drm_dsc_config dsc;
	bool prepared;
	unsigned int cur_vrefresh;
};

static const struct regulator_bulk_data rm692h0_supplies[] = {
	{ .supply = "vddio" },
	{ .supply = "vddd" },
	{ .supply = "vdd" },
	{ .supply = "vci" },
};

static inline struct rm692h0_panel *to_rm692h0(struct drm_panel *panel)
{
	return container_of(panel, struct rm692h0_panel, panel);
}

/*
 * Send DCS with an explicit MIPI data type to match vendor 0x05/0x15/0x39.
 * MSM transfer returns 0 on success; only ret < 0 is failure (s5ao).
 */
static ssize_t rm692h0_dcs_typed_write(struct mipi_dsi_device *dsi, u8 type,
				       const void *data, size_t len)
{
	const struct mipi_dsi_host_ops *ops = dsi->host->ops;
	struct mipi_dsi_msg msg = {
		.channel = dsi->channel,
		.type = type,
		.tx_buf = data,
		.tx_len = len,
	};

	if (!ops || !ops->transfer)
		return -ENOSYS;
	if (!len)
		return -EINVAL;
	if (dsi->mode_flags & MIPI_DSI_MODE_LPM)
		msg.flags |= MIPI_DSI_MSG_USE_LPM;

	return ops->transfer(dsi->host, &msg);
}

static void rm692h0_dcs_typed_write_multi(struct mipi_dsi_multi_context *ctx,
					  u8 type, const void *data, size_t len)
{
	struct mipi_dsi_device *dsi = ctx->dsi;
	ssize_t ret;

	if (ctx->accum_err)
		return;

	ret = rm692h0_dcs_typed_write(dsi, type, data, len);
	if (ret < 0) {
		ctx->accum_err = ret;
		dev_err(&dsi->dev,
			"cerro: rm692h0 dcs type=0x%02x len=%zu failed: %zd\n",
			type, len, ret);
	}
}

#define rm692h0_dcs_typed_write_seq_multi(ctx, type, seq...)		\
	do {								\
		static const u8 d[] = { seq };				\
		rm692h0_dcs_typed_write_multi(ctx, type, d, ARRAY_SIZE(d)); \
	} while (0)

/* Vendor raw H/L/H mapped through GPIO_ACTIVE_LOW: finish released. */
static void rm692h0_reset(struct rm692h0_panel *ctx)
{
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	usleep_range(10000, 11000);
	gpiod_set_value_cansleep(ctx->reset_gpio, 0);
	usleep_range(40000, 41000);
}

/*
 * s5bq: PPS must match msm dsi_populate_dsc_params (setup_rc PRE_SCR) so
 * initial_xmit_delay=410 / slice_chunk_size=698 agree with vendor FE D2.
 */
static int rm692h0_pack_pps(struct rm692h0_panel *ctx,
			    struct drm_dsc_picture_parameter_set *pps)
{
	struct drm_dsc_config *dsc = &ctx->dsc;
	int ret;

	dsc->pic_width = 1116;
	dsc->pic_height = 2480;
	dsc->convert_rgb = true;
	dsc->simple_422 = false;
	dsc->vbr_enable = false;

	drm_dsc_set_const_params(dsc);
	drm_dsc_set_rc_buf_thresh(dsc);
	ret = drm_dsc_setup_rc_params(dsc, DRM_DSC_1_1_PRE_SCR);
	if (ret)
		return ret;
	dsc->initial_scale_value = drm_dsc_initial_scale_value(dsc);
	dsc->line_buf_depth = dsc->bits_per_component + 1;
	ret = drm_dsc_compute_rc_parameters(dsc);
	if (ret)
		return ret;
	drm_dsc_pps_payload_pack(pps, dsc);
	return 0;
}

/*
 * DRM modes for KDE/KWin (Display settings → refresh rate).
 * 60/120 porches from vendor timing@0/@1; 90 = linear mid + BD=0x02.
 */
static const struct drm_display_mode rm692h0_modes[] = {
	{ /* 120Hz — preferred */
		.clock = (1116 + 26 + 8 + 76) * (2480 + 56 + 8 + 8) * 120 / 1000,
		.hdisplay = 1116,
		.hsync_start = 1116 + 26,
		.hsync_end = 1116 + 26 + 8,
		.htotal = 1116 + 26 + 8 + 76,
		.vdisplay = 2480,
		.vsync_start = 2480 + 56,
		.vsync_end = 2480 + 56 + 8,
		.vtotal = 2480 + 56 + 8 + 8,
		.width_mm = 71,
		.height_mm = 157,
		.type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED,
	},
	{ /* 90Hz — cerro mid porch between 60 and 120 */
		.clock = (1116 + 137 + 8 + 206) * (2480 + 56 + 8 + 8) * 90 / 1000,
		.hdisplay = 1116,
		.hsync_start = 1116 + 137,
		.hsync_end = 1116 + 137 + 8,
		.htotal = 1116 + 137 + 8 + 206,
		.vdisplay = 2480,
		.vsync_start = 2480 + 56,
		.vsync_end = 2480 + 56 + 8,
		.vtotal = 2480 + 56 + 8 + 8,
		.width_mm = 71,
		.height_mm = 157,
		.type = DRM_MODE_TYPE_DRIVER,
	},
	{ /* 60Hz */
		.clock = (1116 + 248 + 8 + 336) * (2480 + 56 + 8 + 8) * 60 / 1000,
		.hdisplay = 1116,
		.hsync_start = 1116 + 248,
		.hsync_end = 1116 + 248 + 8,
		.htotal = 1116 + 248 + 8 + 336,
		.vdisplay = 2480,
		.vsync_start = 2480 + 56,
		.vsync_end = 2480 + 56 + 8,
		.vtotal = 2480 + 56 + 8 + 8,
		.width_mm = 71,
		.height_mm = 157,
		.type = DRM_MODE_TYPE_DRIVER,
	},
};

static unsigned int rm692h0_normalize_hz(unsigned int hz)
{
	if (hz <= 75)
		return 60;
	if (hz <= 105)
		return 90;
	return 120;
}

static unsigned int rm692h0_pending_hz(struct rm692h0_panel *ctx)
{
	const struct drm_display_mode *mode;
	unsigned int hz = ctx->cur_vrefresh ?: 120;

	mode = msm_dsi_host_get_display_mode(ctx->dsi->host);
	if (mode)
		hz = drm_mode_vrefresh(mode);
	return rm692h0_normalize_hz(hz);
}

/* Vendor timing-switch (LP): used when rate changes without full power cycle. */
static int rm692h0_timing_switch(struct rm692h0_panel *ctx, unsigned int hz)
{
	struct mipi_dsi_device *dsi = ctx->dsi;
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = dsi };
	u8 bd;

	hz = rm692h0_normalize_hz(hz);
	if (hz == ctx->cur_vrefresh)
		return 0;

	if (hz == 60)
		bd = 0x00;
	else if (hz == 90)
		bd = 0x02;
	else
		bd = 0x05;

	dev_err(&dsi->dev, "cerro: rm692h0 timing-switch %u→%u Hz (BD=0x%02x)\n",
		ctx->cur_vrefresh, hz, bd);

	dsi->mode_flags |= MIPI_DSI_MODE_LPM;
	rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xfe, 0x40);
	{
		u8 bd_cmd[] = { 0xbd, bd };

		rm692h0_dcs_typed_write_multi(&dsi_ctx, 0x39, bd_cmd,
					      ARRAY_SIZE(bd_cmd));
	}

	if (hz == 60) {
		/* vendor timing-switch@0 FE5A/5B set (abbrev from dtsi) */
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xfe, 0x5a);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x49, 0x5e, 0xff, 0xf0, 0xff, 0xff, 0xff, 0xf0, 0xff, 0xff, 0x00, 0xfd, 0xfd);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x58, 0x16, 0xfa);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x5e, 0x0f, 0x0f, 0x0f, 0x05);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x66, 0x00, 0x00, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x6e, 0x00, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x7e, 0x00, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x92, 0x4e, 0x22, 0x1f);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x99, 0x2d, 0x24, 0x0c, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x9e, 0x20, 0x20, 0x20);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xa2, 0x10, 0x03);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xa7, 0x10);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xa9, 0x10, 0x0d);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xac, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xb0, 0x08, 0x08, 0x05, 0x05, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xb8, 0x09, 0x09, 0x05, 0x00, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xc0, 0x08, 0x08, 0x03, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xc8, 0x06, 0x06, 0x02);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xea, 0x16);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xfe, 0x5b);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x2b, 0x4b);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x2d, 0x24);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x2f, 0x1f);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x30, 0x1f, 0x3f, 0x3f, 0x38, 0x32, 0x24, 0x0c, 0x00, 0x00, 0x25, 0x25, 0x1d);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x3d, 0x11);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x3f, 0x07);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x40, 0x04, 0x00, 0x00, 0x1a, 0x1a, 0x0e, 0x08, 0x03, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x4b, 0x08, 0x08, 0x08, 0x08);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x50, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x53, 0x09, 0x09, 0x05, 0x02);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x58, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x5c, 0x08, 0x08, 0x04, 0x01, 0x00);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x64, 0x07, 0x07, 0x03, 0x01);
	} else {
		/* vendor timing-switch@1 (also for 90 with BD=0x02) */
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xfe, 0x5a);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x49, 0x0f, 0x08, 0x04, 0x00, 0x06, 0x06, 0x06, 0x06, 0x06, 0x04);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x55, 0x10, 0x10);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x58, 0x05, 0x03);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x5e, 0x0f, 0x0f, 0x0f, 0x0a);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x66, 0x10, 0x10, 0x10);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x6e, 0x05, 0x05);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x76, 0x05, 0x05);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x7e, 0x05, 0x05);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x92, 0x72, 0x45, 0x25);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x99, 0x7f, 0x40, 0x0f, 0x03);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x9e, 0x30, 0x10, 0x3d);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xa2, 0x1d, 0x09);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xa7, 0x27);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xa9, 0x27, 0x1a);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xac, 0x04);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xb0, 0x20, 0x10, 0x0a, 0x0d, 0x03);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xb8, 0x12, 0x12, 0x0d, 0x03, 0x02);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xc0, 0x0e, 0x0e, 0x09, 0x03);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xc8, 0x0b, 0x0b, 0x07);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xea, 0x1f);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xfe, 0x5b);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x2b, 0x7a);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x2d, 0x45);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x2f, 0x32);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x31, 0x60, 0x1f, 0x60, 0x60, 0x60, 0x37, 0x18, 0x0f, 0x0a, 0x30, 0x30, 0x2b);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x3d, 0x1f);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x3f, 0x0f, 0x07, 0x02, 0x01, 0x1b, 0x1b, 0x1b, 0x0e, 0x06, 0x02);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x4b, 0x13, 0x13, 0x0d, 0x09);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x50, 0x01);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x53, 0x12, 0x12, 0x0b, 0x05);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x58, 0x03);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x5c, 0x0b, 0x0d, 0x08, 0x04, 0x02);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x5c, 0x0b, 0x00, 0x08, 0x04, 0x02);
		rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0x64, 0x09, 0x09, 0x06, 0x02);
	}

	rm692h0_dcs_typed_write_seq_multi(&dsi_ctx, 0x39, 0xfe, 0x00);
	dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;

	if (dsi_ctx.accum_err)
		return dsi_ctx.accum_err;

	ctx->cur_vrefresh = hz;
	return 0;
}


static void rm692h0_on(struct mipi_dsi_multi_context *dsi_ctx, unsigned int hz)
{
	u8 bd;

	/*
	 * s5bl: s5bk + init code FE00 C2/36/35/53 + FE60 block.
	 * Skip poison B3 7F. Goal: grow toward emission while keeping 0x9c.
	 * s5ew: BD selects panel TE rate — vendor 0x00=60, 0x05=120;
	 * 90Hz uses 0x02 (cerro-interpolated; no vendor timing@90).
	 */
	if (hz <= 75)
		bd = 0x00;
	else if (hz <= 105)
		bd = 0x02;
	else
		bd = 0x05;

	dsi_ctx->dsi->mode_flags |= MIPI_DSI_MODE_LPM;
	mipi_dsi_dcs_exit_sleep_mode_multi(dsi_ctx);
	mipi_dsi_msleep(dsi_ctx, 120);

	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x98);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x20, 0x03);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x42);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x68, 0x02);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x40);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x0a, 0xc9);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x0b, 0x17);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x0c, 0x35);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xbe, 0xc9);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xbf, 0x11);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xc0, 0xc9);
	{
		u8 bd_cmd[] = { 0xbd, bd };

		rm692h0_dcs_typed_write_multi(dsi_ctx, 0x39, bd_cmd,
					      ARRAY_SIZE(bd_cmd));
	}
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfe, 0xa1);
	/* SKIP: 0x15, 0xb3, 0x7f — confirmed poison (s5ba → 0x00) */

	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfe, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfa, 0x01);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x57);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xc2, 0x48);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x5a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x00, 0x80);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x1a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x0d, 0x64);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x40);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xdc, 0xb8);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x42);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xda, 0x82);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x20);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x81, 0x80);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x34);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x47, 0x03);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x48, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x00, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x9f, 0x5c);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xa0, 0xc4);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x1c, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x1d, 0x10);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x49, 0x55);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x34);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x1e, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x1f, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x20, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x22, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x21, 0x70);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x23, 0xf8);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x24, 0x77);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x25, 0xf8);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x26, 0xf8);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x2f, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x30, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x31, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x32, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x33, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x34, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x35, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x36, 0x40);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x37, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x38, 0x7f);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x39, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x3a, 0xb6);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x3b, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x3d, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x3f, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x40, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x41, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x42, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0xd4);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x40, 0x02);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0xfd);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x80, 0x06);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x83, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0xa0);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x06, 0x36);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x6e, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x7c, 0x15);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0xd0);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x11, 0x75);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x92, 0x03);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0xa1);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xc3, 0x87);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xc4, 0xff);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xc5, 0x7f);
	/* VESA 10bit / FE D2 — first chunk */
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfe, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfa, 0x01);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfe, 0xd2);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x4f, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x50, 0x11);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x51, 0xab);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x52, 0x30);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x53, 0x09);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x54, 0xb0);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x55, 0x04);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x56, 0x5c);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x58, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x59, 0x14);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x5a, 0x02);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x5b, 0x2e);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x5c, 0x01);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x5d, 0x9a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x5e, 0x19);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x5f, 0x01);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x60, 0xbe);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x61, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x62, 0x0a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x63, 0x0c);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x64, 0x05);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x65, 0x0e);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x66, 0x05);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x67, 0xfd);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x68, 0x16);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x69, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x6a, 0x10);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x6b, 0xdc);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x6c, 0x07);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x6d, 0x10);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x6e, 0x20);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x6f, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x70, 0x06);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x71, 0x0f);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x72, 0x0f);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x73, 0x33);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x74, 0x0e);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x75, 0x1c);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x76, 0x2a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x77, 0x38);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x78, 0x46);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x79, 0x54);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x7a, 0x62);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x7b, 0x69);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x7c, 0x70);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x7d, 0x77);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x7e, 0x79);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x7f, 0x7b);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x80, 0x7d);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x81, 0x7e);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x82, 0x01);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x83, 0xc2);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x84, 0x22);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x85, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x86, 0x2a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x87, 0x40);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x88, 0x32);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x89, 0xbe);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x8a, 0x3a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x8b, 0xfc);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x8c, 0x3a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x8d, 0xfa);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x8e, 0x3a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x8f, 0xf8);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x90, 0x3b);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x91, 0x38);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x92, 0x3b);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x93, 0x78);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x94, 0x3b);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x95, 0x76);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x96, 0x4b);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x97, 0xb6);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x98, 0x4b);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x99, 0xf6);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x9a, 0x4c);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x9b, 0x34);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x9c, 0x5c);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x9d, 0x74);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x9e, 0x8c);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x9f, 0xf4);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xa2, 0x02);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xa3, 0xba);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xa4, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xa5, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xa6, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xa7, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xa9, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xaa, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xa0, 0xa0);
	/*
	 * vendor timing@1 / timing-switch@1: 120fps black-line block.
	 * Also used for 90Hz (BD=0x02). Skip on 60Hz (vendor timing-switch@0
	 * has a different FE5A/5B set applied via rm692h0_timing_switch).
	 */
	if (hz > 75) {
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x5a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x49, 0x0f, 0x08, 0x04, 0x00, 0x06, 0x06, 0x06, 0x06, 0x06, 0x04);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x55, 0x10, 0x10);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x58, 0x05, 0x03);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x5e, 0x0f, 0x0f, 0x0f, 0x0a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x66, 0x10, 0x10, 0x10);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x6e, 0x05, 0x05);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x76, 0x05, 0x05);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x7e, 0x05, 0x05);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x92, 0x72, 0x45, 0x25);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x99, 0x7f, 0x40, 0x0f, 0x03);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x9e, 0x30, 0x10, 0x3d);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xa2, 0x1d, 0x09);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xa7, 0x27);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xa9, 0x27, 0x1a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xac, 0x04);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xb0, 0x20, 0x10, 0x0a, 0x0d, 0x03);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xb8, 0x12, 0x12, 0x0d, 0x03, 0x02);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xc0, 0x0e, 0x0e, 0x09, 0x03);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xc8, 0x0b, 0x0b, 0x07);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xea, 0x1f);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0xfe, 0x5b);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x2b, 0x7a);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x2d, 0x45);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x2f, 0x32);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x31, 0x60, 0x1f, 0x60, 0x60, 0x60, 0x37, 0x18, 0x0f, 0x0a, 0x30, 0x30, 0x2b);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x3d, 0x1f);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x3f, 0x0f, 0x07, 0x02, 0x01, 0x1b, 0x1b, 0x1b, 0x0e, 0x06, 0x02);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x4b, 0x13, 0x13, 0x0d, 0x09);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x50, 0x01);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x53, 0x12, 0x12, 0x0b, 0x05);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x58, 0x03);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x5c, 0x0b, 0x0d, 0x08, 0x04, 0x02);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x5c, 0x0b, 0x00, 0x08, 0x04, 0x02);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x64, 0x09, 0x09, 0x06, 0x02);
	}
	/* ST swire control */
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfe, 0x40);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x24, 0x54);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xa9, 0x14);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xad, 0xc8);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xa5, 0x20);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xac, 0x04);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xae, 0x70);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xaf, 0x4b);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xb0, 0x4b);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xb2, 0x4b);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xb3, 0x4f);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfe, 0x26);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x1d, 0x26);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xa4, 0x1f);
	/* 8.8 PVGH */
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfe, 0x40);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x3a, 0xe8);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x3b, 0xe8);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfe, 0x42);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x81, 0xe8);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x82, 0xe8);
	/* init code */
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfe, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xc2, 0x08);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x36, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x35, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0x53, 0x20);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x39, 0x51, 0x00, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfe, 0x60);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xae, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xb3, 0x00);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xb8, 0xff);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xba, 0xff);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xc7, 0xcb);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xc8, 0xcb);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xdb, 0xcb);
	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xdc, 0xcb);

	rm692h0_dcs_typed_write_seq_multi(dsi_ctx, 0x15, 0xfe, 0x00);
	mipi_dsi_dcs_set_display_on_multi(dsi_ctx);
	mipi_dsi_msleep(dsi_ctx, 20);
}

static int rm692h0_disable(struct drm_panel *panel)
{
	struct rm692h0_panel *ctx = to_rm692h0(panel);
	struct mipi_dsi_device *dsi = ctx->dsi;
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = dsi };

	dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;

	mipi_dsi_dcs_set_display_off_multi(&dsi_ctx);
	mipi_dsi_msleep(&dsi_ctx, 20);
	mipi_dsi_dcs_enter_sleep_mode_multi(&dsi_ctx);
	mipi_dsi_msleep(&dsi_ctx, 120);

	return dsi_ctx.accum_err;
}

static int rm692h0_prepare(struct drm_panel *panel)
{
	struct rm692h0_panel *ctx = to_rm692h0(panel);
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = ctx->dsi };
	struct drm_dsc_picture_parameter_set pps;
	struct device *dev = &ctx->dsi->dev;
	int ret;

	ret = regulator_bulk_enable(ARRAY_SIZE(rm692h0_supplies), ctx->supplies);
	if (ret < 0)
		return ret;

	/* s5an lesson: settle supplies before reset */
	msleep(20);
	rm692h0_reset(ctx);

	ctx->cur_vrefresh = rm692h0_pending_hz(ctx);
	rm692h0_on(&dsi_ctx, ctx->cur_vrefresh);
	if (dsi_ctx.accum_err) {
		dev_err(dev, "cerro: rm692h0 on accum_err=%d\n", dsi_ctx.accum_err);
		goto err_on;
	}

	/* MIPI DSC PPS + enable compression (aligned with dsi_populate). */
	ret = rm692h0_pack_pps(ctx, &pps);
	if (ret) {
		dev_err(dev, "cerro: rm692h0 prepare pack_pps failed %d\n", ret);
		goto err_on;
	}
	mipi_dsi_picture_parameter_set_multi(&dsi_ctx, &pps);
	mipi_dsi_compression_mode_ext_multi(&dsi_ctx, true,
					    MIPI_DSI_COMPRESSION_DSC, 0);
	mipi_dsi_msleep(&dsi_ctx, 28);

	if (dsi_ctx.accum_err)
		goto err_on;

	ctx->prepared = true;
	return 0;

err_on:
	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	regulator_bulk_disable(ARRAY_SIZE(rm692h0_supplies), ctx->supplies);
	return dsi_ctx.accum_err ? dsi_ctx.accum_err : ret;
}

static int rm692h0_unprepare(struct drm_panel *panel)
{
	struct rm692h0_panel *ctx = to_rm692h0(panel);

	if (!ctx->prepared)
		return 0;

	gpiod_set_value_cansleep(ctx->reset_gpio, 1);
	regulator_bulk_disable(ARRAY_SIZE(rm692h0_supplies), ctx->supplies);
	ctx->prepared = false;
	return 0;
}

/*
 * prepare_prev_first: on-cmd/PPS run before host HS is fully up (s5al saw
 * power_mode=0x00 without the re-kick). Re-kick sleep-out / display-on /
 * PPS / compression after the host is enabled.
 */
static int rm692h0_enable(struct drm_panel *panel)
{
	struct rm692h0_panel *ctx = to_rm692h0(panel);
	struct mipi_dsi_device *dsi = ctx->dsi;
	struct mipi_dsi_multi_context dsi_ctx = { .dsi = dsi };
	struct drm_dsc_picture_parameter_set pps;
	struct device *dev = &dsi->dev;
	u8 power_mode = 0xff;
	int pm_ret, ret;

	ret = rm692h0_timing_switch(ctx, rm692h0_pending_hz(ctx));
	if (ret)
		return ret;
	dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;

	mipi_dsi_dcs_exit_sleep_mode_multi(&dsi_ctx);
	mipi_dsi_msleep(&dsi_ctx, 120);
	mipi_dsi_dcs_set_display_on_multi(&dsi_ctx);
	mipi_dsi_msleep(&dsi_ctx, 20);

	/* s5bt: non-inverted DCS brightness was confirmed visible. */
	mipi_dsi_dcs_set_display_brightness_large(dsi, 3515);

	ret = rm692h0_pack_pps(ctx, &pps);
	if (ret) {
		dev_err(dev, "cerro: rm692h0 enable pack_pps failed %d\n", ret);
		return ret;
	}
	mipi_dsi_picture_parameter_set_multi(&dsi_ctx, &pps);
	mipi_dsi_compression_mode_ext_multi(&dsi_ctx, true,
					    MIPI_DSI_COMPRESSION_DSC, 0);
	mipi_dsi_msleep(&dsi_ctx, 28);

	pm_ret = mipi_dsi_dcs_get_power_mode(dsi, &power_mode);
	dev_err(dev,
		"cerro: rm692h0 enable power_mode=0x%02x ret=%d accum=%d (expect ~0x9c)\n",
		power_mode, pm_ret, dsi_ctx.accum_err);

	return dsi_ctx.accum_err;
}

static int rm692h0_get_modes(struct drm_panel *panel,
			     struct drm_connector *connector)
{
	struct drm_display_mode *mode;
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(rm692h0_modes); i++) {
		mode = drm_mode_duplicate(connector->dev, &rm692h0_modes[i]);
		if (!mode)
			return -ENOMEM;
		drm_mode_set_name(mode);
		drm_mode_probed_add(connector, mode);
	}
	connector->display_info.width_mm = 71;
	connector->display_info.height_mm = 157;
	connector->display_info.bpc = 10;
	return ARRAY_SIZE(rm692h0_modes);
}

static enum drm_panel_orientation rm692h0_get_orientation(struct drm_panel *panel)
{
	return DRM_MODE_PANEL_ORIENTATION_LEFT_UP;
}

static const struct drm_panel_funcs rm692h0_funcs = {
	.prepare = rm692h0_prepare,
	.unprepare = rm692h0_unprepare,
	.disable = rm692h0_disable,
	.enable = rm692h0_enable,
	.get_modes = rm692h0_get_modes,
	.get_orientation = rm692h0_get_orientation,
};

/* s5bt: direct UI-to-DCS brightness, not the discarded inverted experiment. */
static int rm692h0_bl_update_status(struct backlight_device *bl)
{
	struct mipi_dsi_device *dsi = bl_get_data(bl);
	u16 brightness = backlight_get_brightness(bl);

	int ret;

	/* Final historical driver sends brightness in HS. */
	dsi->mode_flags &= ~MIPI_DSI_MODE_LPM;
	ret = mipi_dsi_dcs_set_display_brightness_large(dsi,
						     clamp_val(brightness, 15, 3515));
	dsi->mode_flags |= MIPI_DSI_MODE_LPM;
	return ret;

}

static const struct backlight_ops rm692h0_bl_ops = {
	.update_status = rm692h0_bl_update_status,
};

static struct backlight_device *
rm692h0_create_backlight(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	const struct backlight_properties props = {
		.type = BACKLIGHT_RAW,
		.brightness = 3515,
		.max_brightness = 3515,
	};

	return devm_backlight_device_register(dev, dev_name(dev), dev, dsi,
					      &rm692h0_bl_ops, &props);
}

static int rm692h0_probe(struct mipi_dsi_device *dsi)
{
	struct device *dev = &dsi->dev;
	struct rm692h0_panel *ctx;
	int ret;

	ctx = devm_drm_panel_alloc(dev, struct rm692h0_panel, panel,
				   &rm692h0_funcs, DRM_MODE_CONNECTOR_DSI);
	if (IS_ERR(ctx))
		return PTR_ERR(ctx);

	ret = devm_regulator_bulk_get_const(dev, ARRAY_SIZE(rm692h0_supplies),
					    rm692h0_supplies, &ctx->supplies);
	if (ret < 0)
		return dev_err_probe(dev, ret, "failed to get supplies\n");

	ctx->reset_gpio = devm_gpiod_get(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(ctx->reset_gpio))
		return dev_err_probe(dev, PTR_ERR(ctx->reset_gpio),
				     "failed to get reset gpio\n");

	ctx->dsi = dsi;
	mipi_dsi_set_drvdata(dsi, ctx);

	/* CMD mode + DSC (vendor): no MIPI_DSI_MODE_VIDEO. */
	dsi->lanes = 4;
	dsi->format = MIPI_DSI_FMT_RGB888;
	dsi->mode_flags = MIPI_DSI_CLOCK_NON_CONTINUOUS |
			  MIPI_DSI_MODE_DSC_ALL_SLICES_IN_PKT;

	ctx->dsc.dsc_version_major = 1;
	ctx->dsc.dsc_version_minor = 1;
	ctx->dsc.slice_height = 20;
	ctx->dsc.slice_width = 558;
	ctx->dsc.slice_count = 2;
	ctx->dsc.bits_per_component = 10;
	ctx->dsc.bits_per_pixel = 10 << 4;
	ctx->dsc.block_pred_enable = true;
	dsi->dsc = &ctx->dsc;

	ctx->panel.prepare_prev_first = true;

	ctx->panel.backlight = rm692h0_create_backlight(dsi);
	if (IS_ERR(ctx->panel.backlight))
		return dev_err_probe(dev, PTR_ERR(ctx->panel.backlight),
				     "failed to create backlight\n");

	drm_panel_add(&ctx->panel);

	ret = mipi_dsi_attach(dsi);
	if (ret < 0) {
		drm_panel_remove(&ctx->panel);
		return dev_err_probe(dev, ret, "failed to attach to DSI host\n");
	}

	return 0;
}

static void rm692h0_remove(struct mipi_dsi_device *dsi)
{
	struct rm692h0_panel *ctx = mipi_dsi_get_drvdata(dsi);
	int ret;

	ret = mipi_dsi_detach(dsi);
	if (ret < 0)
		dev_err(&dsi->dev, "failed to detach from DSI host: %d\n", ret);
	drm_panel_remove(&ctx->panel);
}

static const struct of_device_id rm692h0_of_match[] = {
	{ .compatible = "raydium,rm692h0" },
	{ .compatible = "zte,bf068-rm692h0" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, rm692h0_of_match);

static struct mipi_dsi_driver rm692h0_driver = {
	.probe = rm692h0_probe,
	.remove = rm692h0_remove,
	.driver = {
		.name = "panel-raydium-rm692h0",
		.of_match_table = rm692h0_of_match,
	},
};
module_mipi_dsi_driver(rm692h0_driver);

MODULE_AUTHOR("Cerro bring-up (reconstructed from .cursor session archive)");
MODULE_DESCRIPTION("DRM driver for Raydium RM692H0 BF068 CMD+DSC panel (cerro)");
MODULE_LICENSE("GPL");
