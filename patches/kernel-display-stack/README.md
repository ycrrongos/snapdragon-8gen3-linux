# Cerro 显示栈源码镜像（必须进 GitHub 主仓）

**为何存在**：主仓曾 `.gitignore` `/build/`，且 AGENTS §5.3 写「主仓库不收内核树」。  
用户**从未**说过不要推屏驱——那是规则漏洞。结果 GitHub 上长期没有 `panel-raydium-rm692h0.c` 等文件，本地一清理就丢。

本目录是 **build/linux-7.2 里显示相关源码的强制镜像**，随主仓 `LOA_Nubia_Z60U` 推送。  
改内核显示栈后：**树内 git commit** + **同步拷贝到这里** + **主仓 commit/push**。

| 路径 | 对应树内 |
|------|----------|
| `panel/panel-raydium-rm692h0.c` | `drivers/gpu/drm/panel/panel-raydium-rm692h0.c` |
| `msm-dsi/dsi_host.c` | `drivers/gpu/drm/msm/dsi/dsi_host.c` |
| `msm-dsi/dsi.h` | `drivers/gpu/drm/msm/dsi/dsi.h` |
| `include-drm/drm_mipi_dsi.h` | `include/drm/drm_mipi_dsi.h` |
| `dts/sm8650-nubia-cerro.dts` | `arch/arm64/boot/dts/qcom/sm8650-nubia-cerro.dts` |
| `setup/setup.c` | `arch/arm64/kernel/setup.c` |
| `TREE_SHA.txt` | 镜像时的树内 HEAD |

整棵 `linux-7.2` 仍可另有备份仓；但**屏驱源码不得只活在被 ignore 的 build/ 里**。
