# audio s5fd — PAS DMA oops fix (memstart-safe memblock)

## Root cause (s5fc)
`qcom_scm_pas_init_image` → `dma_alloc_coherent` → `dcache_clean_poc` Oops.
Fault VA `fffeffffe1f2f000`, phys `0x81f2f000` inside System RAM island
`81f20000-8249ffff` (also `816e*`, `84a0*`).

Those islands were `memblock_add`ed by `cerro_abl_memblock_expand_from_mapped_fdt`
but sit **below** `memstart` (`0xa0000000`), so `__phys_to_virt` is outside the
linear map while buddy still allocates them.

## Fix
`arch/arm64/kernel/setup.c` expand: **skip / clip** ranges below
`CERRO_FALLBACK_MEM_BASE` (`0xa0000000`).

## Also
- DTS `cerro_dtb=s5fd`; ADSP okay + `auto_boot=false` (from s5fc).
- Builtin DTB: `cp` → `arch/arm64/kernel/` + delete `.dtb.o` before `make Image`.
