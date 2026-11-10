# audio-s5fw — PRI_MI2S_IBIT 时钟投票

## 动机

s5fv 冷启动声卡 PASS，但试播 FAIL：
- DSP `APM_CMD_SET_CFG` → `error[1001006]` → `Failed to set media format -22` on `PRI_MI2S_RX`
- `LPASS_CLK_ID_PRI_MI2S_IBIT` enable/prepare count = 0（从未投票）
- Audioreach `q6i2s_ops` 无 `set_sysclk`；`sc8280xp` 原先只 `set_fmt(BP_FP)`

## 改动

1. **DTS**（`linux/sm8650-nubia-cerro.dts`，`cerro_dtb=s5fw`）  
   sound 节点：
   ```
   clocks = <&q6prmcc LPASS_CLK_ID_PRI_MI2S_IBIT LPASS_CLK_ATTRIBUTE_COUPLE_NO>;
   clock-names = "pri_mi2s_ibit";
   ```

2. **机芯**（`build/linux/sound/soc/qcom/sc8280xp.c`，副本见本目录）  
   - `devm_clk_get_optional(..., "pri_mi2s_ibit")`
   - `PRIMARY_MI2S_{RX,TX}` startup：`clk_set_rate(1.536M)` + `clk_prepare_enable`
   - shutdown：`clk_disable_unprepare`
   - MI2S init：codec DAI `BC_FC|NB_NF|I2S`

## 镜像

`build/boot_repack/boot-v2-disp-dpu-s5fw.img`（无 ath12k，拟合 boot 96MiB）

## 验收

- IBIT 绑定 PASS（`clk_summary` consumer=`sound`，rate=1536000）。
- 试播仍 FAIL（同 s5fv SET_CFG status=1）→ 见 **s5fx**（tplg `HW_IF_TYPE`）。
