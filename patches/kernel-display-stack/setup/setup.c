// SPDX-License-Identifier: GPL-2.0-only
/*
 * Based on arch/arm/kernel/setup.c
 *
 * Copyright (C) 1995-2001 Russell King
 * Copyright (C) 2012 ARM Ltd.
 */

#include <linux/acpi.h>
#include <linux/export.h>
#include <linux/kernel.h>
#include <linux/stddef.h>
#include <linux/ioport.h>
#include <linux/delay.h>
#include <linux/initrd.h>
#include <linux/console.h>
#include <linux/cache.h>
#include <linux/screen_info.h>
#include <linux/init.h>
#include <linux/kexec.h>
#include <linux/root_dev.h>
#include <linux/cpu.h>
#include <linux/interrupt.h>
#include <linux/smp.h>
#include <linux/fs.h>
#include <linux/panic_notifier.h>
#include <linux/proc_fs.h>
#include <linux/memblock.h>
#include <linux/of_fdt.h>
#include <linux/efi.h>
#include <linux/psci.h>
#include <linux/reboot.h>
#include <linux/sched/task.h>
#include <linux/scs.h>
#include <linux/mm.h>
#include <linux/arm-smccc.h>
#include <linux/libfdt.h>
#include <linux/initrd.h>
#include <linux/string.h>
#include <uapi/linux/psci.h>

#include <asm/acpi.h>
#include <asm/fixmap.h>
#include <asm/image.h>
#include <asm/cpu.h>
#include <asm/cputype.h>
#include <asm/daifflags.h>
#include <asm/elf.h>
#include <asm/cpufeature.h>
#include <asm/cpu_ops.h>
#include <asm/kasan.h>
#include <asm/numa.h>
#include <asm/rsi.h>
#include <asm/scs.h>
#include <asm/sections.h>
#include <asm/sparsemem.h>
#include <asm/memory.h>
#include <asm/setup.h>
#include <asm/smp_plat.h>
#include <asm/cacheflush.h>
#include <asm/tlbflush.h>
#include <asm/traps.h>
#include <asm/efi.h>
#include <asm/xen/hypervisor.h>
#include <asm/mmu_context.h>

static int num_standard_resources;
static struct resource *standard_resources;

phys_addr_t __fdt_pointer __initdata;
u64 mmu_enabled_at_boot __initdata;

/*
 * Standard memory resources
 */
static struct resource mem_res[] = {
	{
		.name = "Kernel code",
		.start = 0,
		.end = 0,
		.flags = IORESOURCE_SYSTEM_RAM
	},
	{
		.name = "Kernel data",
		.start = 0,
		.end = 0,
		.flags = IORESOURCE_SYSTEM_RAM
	}
};

#define kernel_code mem_res[0]
#define kernel_data mem_res[1]

/*
 * The recorded values of x0 .. x3 upon kernel entry.
 */
u64 __cacheline_aligned boot_args[4];

void __init smp_setup_processor_id(void)
{
	u64 mpidr = read_cpuid_mpidr() & MPIDR_HWID_BITMASK;
	set_cpu_logical_map(0, mpidr);

	pr_info("Booting Linux on physical CPU 0x%010lx [0x%08x]\n",
		(unsigned long)mpidr, read_cpuid_id());
}

bool arch_match_cpu_phys_id(int cpu, u64 phys_id)
{
	return phys_id == cpu_logical_map(cpu);
}

struct mpidr_hash mpidr_hash;
/**
 * smp_build_mpidr_hash - Pre-compute shifts required at each affinity
 *			  level in order to build a linear index from an
 *			  MPIDR value. Resulting algorithm is a collision
 *			  free hash carried out through shifting and ORing
 */
static void __init smp_build_mpidr_hash(void)
{
	u32 i, affinity, fs[4], bits[4], ls;
	u64 mask = 0;
	/*
	 * Pre-scan the list of MPIDRS and filter out bits that do
	 * not contribute to affinity levels, ie they never toggle.
	 */
	for_each_possible_cpu(i)
		mask |= (cpu_logical_map(i) ^ cpu_logical_map(0));
	pr_debug("mask of set bits %#llx\n", mask);
	/*
	 * Find and stash the last and first bit set at all affinity levels to
	 * check how many bits are required to represent them.
	 */
	for (i = 0; i < 4; i++) {
		affinity = MPIDR_AFFINITY_LEVEL(mask, i);
		/*
		 * Find the MSB bit and LSB bits position
		 * to determine how many bits are required
		 * to express the affinity level.
		 */
		ls = fls(affinity);
		fs[i] = affinity ? ffs(affinity) - 1 : 0;
		bits[i] = ls - fs[i];
	}
	/*
	 * An index can be created from the MPIDR_EL1 by isolating the
	 * significant bits at each affinity level and by shifting
	 * them in order to compress the 32 bits values space to a
	 * compressed set of values. This is equivalent to hashing
	 * the MPIDR_EL1 through shifting and ORing. It is a collision free
	 * hash though not minimal since some levels might contain a number
	 * of CPUs that is not an exact power of 2 and their bit
	 * representation might contain holes, eg MPIDR_EL1[7:0] = {0x2, 0x80}.
	 */
	mpidr_hash.shift_aff[0] = MPIDR_LEVEL_SHIFT(0) + fs[0];
	mpidr_hash.shift_aff[1] = MPIDR_LEVEL_SHIFT(1) + fs[1] - bits[0];
	mpidr_hash.shift_aff[2] = MPIDR_LEVEL_SHIFT(2) + fs[2] -
						(bits[1] + bits[0]);
	mpidr_hash.shift_aff[3] = MPIDR_LEVEL_SHIFT(3) +
				  fs[3] - (bits[2] + bits[1] + bits[0]);
	mpidr_hash.mask = mask;
	mpidr_hash.bits = bits[3] + bits[2] + bits[1] + bits[0];
	pr_debug("MPIDR hash: aff0[%u] aff1[%u] aff2[%u] aff3[%u] mask[%#llx] bits[%u]\n",
		mpidr_hash.shift_aff[0],
		mpidr_hash.shift_aff[1],
		mpidr_hash.shift_aff[2],
		mpidr_hash.shift_aff[3],
		mpidr_hash.mask,
		mpidr_hash.bits);
	/*
	 * 4x is an arbitrary value used to warn on a hash table much bigger
	 * than expected on most systems.
	 */
	if (mpidr_hash_size() > 4 * num_possible_cpus())
		pr_warn("Large number of MPIDR hash buckets detected\n");
}

/*
 * Prefer the board DTB linked into the Image (sm8650-nubia-cerro.dtb.o).
 * GKI ABL passes vendor_boot FDT in x0. Mainline DTB has memory size 0
 * and some reserved-memory addresses that differ from this phone (e.g.
 * hwfence). Harvest memory + reserved from the BL FDT before discarding it.
 */
extern char __dtb_sm8650_nubia_cerro_begin[];

static bool __initdata cerro_builtin_dtb_ok;

#define CERRO_MAX_MEM_BANKS	8
#define CERRO_MAX_RSV		64

struct cerro_region {
	u64 base;
	u64 size;
	bool nomap;
};

static struct cerro_region cerro_bl_mem[CERRO_MAX_MEM_BANKS] __initdata;
static int cerro_bl_mem_count __initdata;
static struct cerro_region cerro_bl_rsv[CERRO_MAX_RSV] __initdata;
static int cerro_bl_rsv_count __initdata;

/* Z60 Ultra 12GB: DRAM usable from 0xa0000000 (2.5GB low firmware hole). */
#define CERRO_FALLBACK_MEM_BASE	0xa0000000ULL
/* Was 0x260000000 (12G guess); top-down pt alloc / full map_mem hit fake high PA.
 * Cap at known-good low 256MiB until ABL FDT /memory is harvested. */
#define CERRO_FALLBACK_MEM_SIZE	0x10000000ULL

static void __init cerro_harvest_reg(const void *fdt, int node,
				    int addr_cells, int size_cells,
				    struct cerro_region *out, int *count,
				    int max, bool nomap)
{
	const fdt32_t *reg;
	int reg_len, i, cells;

	reg = fdt_getprop(fdt, node, "reg", &reg_len);
	if (!reg || reg_len <= 0 || addr_cells <= 0 || size_cells <= 0)
		return;

	cells = addr_cells + size_cells;
	for (i = 0; (i + cells) * (int)sizeof(fdt32_t) <= reg_len &&
	     *count < max; i += cells) {
		u64 base = 0, sz = 0;
		int c;

		for (c = 0; c < addr_cells; c++)
			base = (base << 32) | fdt32_to_cpu(reg[i + c]);
		for (c = 0; c < size_cells; c++)
			sz = (sz << 32) | fdt32_to_cpu(reg[i + addr_cells + c]);
		if (!sz)
			continue;
		out[*count].base = base;
		out[*count].size = sz;
		out[*count].nomap = nomap;
		(*count)++;
	}
}

static void __init cerro_harvest_bl_fdt(phys_addr_t bl_phys)
{
	void *fdt;
	int size = 0;
	int root, node, rsv, addr_cells, size_cells;

	fdt = fixmap_remap_fdt(bl_phys, &size, PAGE_KERNEL);
	if (!fdt || !early_init_dt_verify(fdt, bl_phys)) {
		pr_err("cerro: BL FDT harvest failed (phys=%pa)\n", &bl_phys);
		return;
	}

	root = fdt_path_offset(fdt, "/");
	if (root < 0)
		return;

	addr_cells = fdt_address_cells(fdt, root);
	size_cells = fdt_size_cells(fdt, root);

	fdt_for_each_subnode(node, fdt, root) {
		const char *type;
		int len;

		type = fdt_getprop(fdt, node, "device_type", &len);
		if (!type || strcmp(type, "memory"))
			continue;
		cerro_harvest_reg(fdt, node, addr_cells, size_cells,
				  cerro_bl_mem, &cerro_bl_mem_count,
				  CERRO_MAX_MEM_BANKS, false);
	}

	rsv = fdt_path_offset(fdt, "/reserved-memory");
	if (rsv >= 0) {
		int r_addr = fdt_address_cells(fdt, rsv);
		int r_size = fdt_size_cells(fdt, rsv);

		fdt_for_each_subnode(node, fdt, rsv) {
			bool nomap = fdt_getprop(fdt, node, "no-map", NULL);

			cerro_harvest_reg(fdt, node, r_addr, r_size,
					  cerro_bl_rsv, &cerro_bl_rsv_count,
					  CERRO_MAX_RSV, nomap);
		}
	}

	pr_err("cerro: harvested BL mem banks=%d reserved=%d\n",
	       cerro_bl_mem_count, cerro_bl_rsv_count);
}

static void __init cerro_apply_bl_fdt_extras(void)
{
	/*
	 * Baseline bring-up path (known to reach stage2 before): only the
	 * fixed DRAM bank. BL memory/reserved harvest is disabled until
	 * paging_init is past — wrong BL banks hung memblock_init.
	 */
	early_init_dt_add_memory_arch(CERRO_FALLBACK_MEM_BASE,
				      CERRO_FALLBACK_MEM_SIZE);
	pr_err("cerro: baseline fallback memory %#llx+%#llx (harvest unused: mem=%d rsv=%d)\n",
	       CERRO_FALLBACK_MEM_BASE, CERRO_FALLBACK_MEM_SIZE,
	       cerro_bl_mem_count, cerro_bl_rsv_count);
}

/*
 * Bisect hang. CERRO_PROBE_STAGE:
 *   0 after FDT scan, before apply
 *   1 after apply
 *   2 after arm64_memblock_init
 *   30 enter paging_init (before map_mem)
 *   31 after map_mem
 *   32 after create_idmap
 *   3 after paging_init
 *   4 after unflatten
 *   5 after bootmem_init
 *   6 end setup_arch
 * Delay always 3 seconds.
 *
 * CERRO_PROBE_SIGNAL:
 *   0 = PSCI SYSTEM_RESET（屏幕约 3s 循环重启 = PASS；USB 难区分 hang）
 *   1 = panic → ABL 进 fastboot（自动化脚本默认：晚出现的 fastboot=PASS）
 */
#define CERRO_PROBE_STAGE (-1)  /* disabled: 31 caused PSCI reset black-screen */
/* 0=PSCI reset (cerro ABL 可靠); 1=panic→fastboot (本机故意 panic 常无 USB) */
#define CERRO_PROBE_SIGNAL 0

void __init cerro_stage_probe(int stage)
{
	if (stage != CERRO_PROBE_STAGE || !cerro_builtin_dtb_ok)
		return;

#if CERRO_PROBE_SIGNAL == 1
	pr_err("cerro: probe stage %d — panic→fastboot in 3s (auto-bisect)\n",
	       stage);
	mdelay(3000);
	panic("cerro: probe stage %d OK\n", stage);
#else
	{
		struct arm_smccc_res res;

		pr_err("cerro: probe stage %d — PSCI reset in 3s\n", stage);
		mdelay(3000);
		arm_smccc_smc(PSCI_0_2_FN_SYSTEM_RESET, 0, 0, 0, 0, 0, 0, 0,
			      &res);
		while (true)
			cpu_relax();
	}
#endif
}

static phys_addr_t __init prefer_builtin_dtb(phys_addr_t dt_phys)
{
	phys_addr_t builtin = __pa_symbol(__dtb_sm8650_nubia_cerro_begin);
	void *virt;
	int size = 0;

	/*
	 * Baseline: do not touch BL FDT via fixmap before switching.
	 * (cerro_harvest_bl_fdt disabled while re-confirming stage2.)
	 */
	(void)cerro_harvest_bl_fdt;

	virt = fixmap_remap_fdt(builtin, &size, PAGE_KERNEL);
	if (virt && early_init_dt_verify(virt, builtin)) {
		pr_info("Using built-in cerro DTB at %pa (ignored bootloader FDT %pa)\n",
			&builtin, &dt_phys);
		cerro_builtin_dtb_ok = true;
		return builtin;
	}

	pr_err("built-in cerro DTB invalid; falling back to bootloader FDT\n");
	return dt_phys;
}

static void __init setup_machine_fdt(phys_addr_t dt_phys)
{
	int size = 0;
	void *dt_virt;
	const char *name;

	dt_phys = prefer_builtin_dtb(dt_phys);
	dt_virt = fixmap_remap_fdt(dt_phys, &size, PAGE_KERNEL);

	if (dt_virt)
		memblock_reserve(dt_phys, size);

	/*
	 * dt_virt is a fixmap address, hence __pa(dt_virt) can't be used.
	 * Pass dt_phys directly.
	 */
	if (!early_init_dt_scan(dt_virt, dt_phys)) {
		pr_crit("\n"
			"Error: invalid device tree blob: PA=%pa, VA=%px, size=%d bytes\n"
			"The dtb must be 8-byte aligned and must not exceed 2 MB in size.\n"
			"\nPlease check your bootloader.\n",
			&dt_phys, dt_virt, size);

		/*
		 * Note that in this _really_ early stage we cannot even BUG()
		 * or oops, so the least terrible thing to do is cpu_relax(),
		 * or else we could end-up printing non-initialized data, etc.
		 */
		while (true)
			cpu_relax();
	}

	cerro_stage_probe(0);

	if (cerro_builtin_dtb_ok)
		cerro_apply_bl_fdt_extras();

	cerro_stage_probe(1);

	/* Early fixups are done, map the FDT as read-only now */
	fixmap_remap_fdt(dt_phys, &size, PAGE_KERNEL_RO);

	name = of_flat_dt_get_machine_name();
	if (!name)
		return;

	pr_info("Machine model: %s\n", name);
	dump_stack_set_arch_desc("%s (DT)", name);
}

static void __init request_standard_resources(void)
{
	struct memblock_region *region;
	struct resource *res;
	unsigned long i = 0;
	size_t res_size;

	kernel_code.start   = __pa_symbol(_text);
	kernel_code.end     = __pa_symbol(__init_begin - 1);
	kernel_data.start   = __pa_symbol(_sdata);
	kernel_data.end     = __pa_symbol(_end - 1);
	insert_resource(&iomem_resource, &kernel_code);
	insert_resource(&iomem_resource, &kernel_data);

	num_standard_resources = memblock.memory.cnt;
	res_size = num_standard_resources * sizeof(*standard_resources);
	standard_resources = memblock_alloc_or_panic(res_size, SMP_CACHE_BYTES);

	for_each_mem_region(region) {
		res = &standard_resources[i++];
		if (memblock_is_nomap(region)) {
			res->name  = "reserved";
			res->flags = IORESOURCE_MEM;
			res->start = __pfn_to_phys(memblock_region_reserved_base_pfn(region));
			res->end = __pfn_to_phys(memblock_region_reserved_end_pfn(region)) - 1;
		} else {
			res->name  = "System RAM";
			res->flags = IORESOURCE_SYSTEM_RAM | IORESOURCE_BUSY;
			res->start = __pfn_to_phys(memblock_region_memory_base_pfn(region));
			res->end = __pfn_to_phys(memblock_region_memory_end_pfn(region)) - 1;
		}

		insert_resource(&iomem_resource, res);
	}
}

static int __init reserve_memblock_reserved_regions(void)
{
	u64 i, j;

	for (i = 0; i < num_standard_resources; ++i) {
		struct resource *mem = &standard_resources[i];
		phys_addr_t r_start, r_end, mem_size = resource_size(mem);

		if (!memblock_is_region_reserved(mem->start, mem_size))
			continue;

		for_each_reserved_mem_range(j, &r_start, &r_end) {
			resource_size_t start, end;

			start = max(PFN_PHYS(PFN_DOWN(r_start)), mem->start);
			end = min(PFN_PHYS(PFN_UP(r_end)) - 1, mem->end);

			if (start > mem->end || end < mem->start)
				continue;

			reserve_region_with_split(mem, start, end, "reserved");
		}
	}

	return 0;
}
arch_initcall(reserve_memblock_reserved_regions);

u64 __cpu_logical_map[NR_CPUS] = { [0 ... NR_CPUS-1] = INVALID_HWID };

u64 cpu_logical_map(unsigned int cpu)
{
	return __cpu_logical_map[cpu];
}

void __init __no_sanitize_address setup_arch(char **cmdline_p)
{
	setup_initial_init_mm(_text, _etext, _edata, _end);

	*cmdline_p = boot_command_line;

	kaslr_init();

	early_fixmap_init();
	early_ioremap_init();

	setup_machine_fdt(__fdt_pointer);

	/*
	 * Initialise the static keys early as they may be enabled by the
	 * cpufeature code and early parameters.
	 */
	jump_label_init();
	parse_early_param();

	dynamic_scs_init();

	/*
	 * The primary CPU enters the kernel with all DAIF exceptions masked.
	 *
	 * We must unmask Debug and SError before preemption or scheduling is
	 * possible to ensure that these are consistently unmasked across
	 * threads, and we want to unmask SError as soon as possible after
	 * initializing earlycon so that we can report any SErrors immediately.
	 *
	 * IRQ and FIQ will be unmasked after the root irqchip has been
	 * detected and initialized.
	 */
	local_daif_restore(DAIF_PROCCTX_NOIRQ);

	/*
	 * TTBR0 is only used for the identity mapping at this stage. Make it
	 * point to zero page to avoid speculatively fetching new entries.
	 */
	cpu_uninstall_idmap();

	xen_early_init();
	efi_init();

	if (!efi_enabled(EFI_BOOT)) {
		if ((u64)_text % MIN_KIMG_ALIGN)
			pr_warn(FW_BUG "Kernel image misaligned at boot, please fix your bootloader!");
		WARN_TAINT(mmu_enabled_at_boot, TAINT_FIRMWARE_WORKAROUND,
			   FW_BUG "Booted with MMU enabled!");
	}

	arm64_memblock_init();

	/*
	 * Cerro: fallback DRAM added before arm64_memblock_init can end up with
	 * no free pages for early_pgtable_alloc. Re-add after init and refresh
	 * memstart_addr (PHYS_OFFSET) so __phys_to_virt is consistent.
	 */
	if (cerro_builtin_dtb_ok) {
		memblock_add(CERRO_FALLBACK_MEM_BASE, CERRO_FALLBACK_MEM_SIZE);
		memblock_set_current_limit(MEMBLOCK_ALLOC_ANYWHERE);
		memstart_addr = round_down((s64)memblock_start_of_DRAM(),
					   1UL << SECTION_SIZE_BITS);
		pr_err("cerro: post-memblock_init re-add %#llx+%#llx memstart=%llx\n",
		       CERRO_FALLBACK_MEM_BASE, CERRO_FALLBACK_MEM_SIZE,
		       (unsigned long long)memstart_addr);
	}

	cerro_stage_probe(2);

	paging_init();
	cerro_stage_probe(3);

	acpi_table_upgrade();

	/* Parse the ACPI tables for possible boot-time configuration */
	acpi_boot_table_init();

	if (acpi_disabled)
		unflatten_device_tree();
	cerro_stage_probe(4);

	bootmem_init();
	cerro_stage_probe(5);

	kasan_init();

	request_standard_resources();

	early_ioremap_reset();

	if (acpi_disabled)
		psci_dt_init();
	else
		psci_acpi_init();

	arm64_rsi_init();

	init_bootcpu_ops();
	smp_init_cpus();
	smp_build_mpidr_hash();

	cerro_stage_probe(6);

#ifdef CONFIG_ARM64_SW_TTBR0_PAN
	/*
	 * Make sure init_thread_info.ttbr0 always generates translation
	 * faults in case uaccess_enable() is inadvertently called by the init
	 * thread.
	 */
	init_task.thread_info.ttbr0 = phys_to_ttbr(__pa_symbol(reserved_pg_dir));
#endif

	if (boot_args[1] || boot_args[2] || boot_args[3]) {
		pr_err("WARNING: x1-x3 nonzero in violation of boot protocol:\n"
			"\tx1: %016llx\n\tx2: %016llx\n\tx3: %016llx\n"
			"This indicates a broken bootloader or old kernel\n",
			boot_args[1], boot_args[2], boot_args[3]);
	}
}

static inline bool cpu_can_disable(unsigned int cpu)
{
#ifdef CONFIG_HOTPLUG_CPU
	const struct cpu_operations *ops = get_cpu_ops(cpu);

	if (ops && ops->cpu_can_disable)
		return ops->cpu_can_disable(cpu);
#endif
	return false;
}

bool arch_cpu_is_hotpluggable(int num)
{
	return cpu_can_disable(num);
}

static void dump_kernel_offset(void)
{
	const unsigned long offset = kaslr_offset();

	if (IS_ENABLED(CONFIG_RANDOMIZE_BASE) && offset > 0) {
		pr_emerg("Kernel Offset: 0x%lx from 0x%lx\n",
			 offset, KIMAGE_VADDR);
		pr_emerg("PHYS_OFFSET: 0x%llx\n", PHYS_OFFSET);
	} else {
		pr_emerg("Kernel Offset: disabled\n");
	}
}

static int arm64_panic_block_dump(struct notifier_block *self,
				  unsigned long v, void *p)
{
	dump_kernel_offset();
	dump_cpu_features();
	dump_mem_limit();
	return 0;
}

static struct notifier_block arm64_panic_block = {
	.notifier_call = arm64_panic_block_dump
};

static int __init register_arm64_panic_block(void)
{
	atomic_notifier_chain_register(&panic_notifier_list,
				       &arm64_panic_block);
	return 0;
}
device_initcall(register_arm64_panic_block);

static int __init check_mmu_enabled_at_boot(void)
{
	if (!efi_enabled(EFI_BOOT) && mmu_enabled_at_boot)
		panic("Non-EFI boot detected with MMU and caches enabled");
	return 0;
}
device_initcall_sync(check_mmu_enabled_at_boot);
