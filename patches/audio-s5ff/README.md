# audio s5ff — skip PD + CERRO topology

## Why
APR binds to `adsp_apps`, but services with `qcom,protection-domain` wait for PDR
(`avs/audio` / `msm/adsp/audio_pd`) which never fires → empty aprbus → no q6prm clocks.

After deleting PD, card still failed: missing `qcom/sm8650/SM8650-CERRO-tplg.bin`
(from sound `model = "SM8650-CERRO"`).

## Changes
- DTS: `/delete-property/ qcom,protection-domain` on `&q6apm` / `&q6prm`
- Topology: decompress QRD/MTP stub (`Kaanapali-MTP-tplg.bin.zst`) →
  `SM8650-CERRO-tplg.bin` (archived under `notes/firmware-adsp-sm8650/`)

## Result
`aplay -l` shows **card 0 SM8650-CERRO** (MultiMedia1/2). `speaker-test` still
`-EINVAL` (routing/mixer TBD).

Keeps s5fd memblock skip + s5fe ADSP-first load order.
