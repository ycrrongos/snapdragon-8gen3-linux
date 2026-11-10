# audio-s5fx — LEMANS tplg HW_IF_TYPE 6→0 (LPAIF)

## 背景（s5fw）

s5fw 已把 `PRI_MI2S_IBIT` 绑到 sound 并在 startup `set_rate(1.536M)+prepare_enable`：
- clk_summary 显示 consumer `sound` / `pri_mi2s_ibit`，rate=1536000
- 试播仍 FAIL：`APM_CMD_SET_CFG` status=1 → `Failed to set media format -22`

## 新假设

当前 `SM8650-CERRO-tplg.bin` 来自 **LEMANS-EVK**（SA8775P）。Primary MI2S widget token：
- `AR_TKN_U32_MODULE_HW_IF_TYPE` = **6**（LEMANS 扩展 LPAIF）
- `AR_TKN_U32_MODULE_HW_IF_IDX` = 0（PRIMARY）

主线文档 LPAIF 类型仅 0–4；SM8450-HDK 的 PRIMARY 用 **TYPE=0 IDX=0**。  
TYPE=6 可能被 SM8650 ADSP 拒绝。

## 改动

- 备份：`SM8650-CERRO-tplg-lemans-type6.bin`
- 活跃：`SM8650-CERRO-tplg.bin`（offset 6028：TYPE 6→**0**）
- 继承 s5fw：IBIT clk 投票 + `cerro_dtb=s5fx`
- 镜像：`boot-v2-disp-dpu-s5fx.img`

## 验收（2026-08-17）

- `cerro_dtb=s5fx`；tplg TOK `(251,0)`。
- `speaker-test -D hw:0,0` → **PLAY_EXIT=0**（period/buffer 设上，左右声道跑完）。
- dmesg **无** `Failed to set media format` / SET_CFG status=1。
- **仍**：`aw88261 … start failure (-1)`（acf 已 load）→ 可能听不到物理出声；下一刀 AW PA。
- 日志：`notes/bisect-logs/linux-s5fx-play-20260817.txt`。
