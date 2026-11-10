# Out-of-tree against build/linux-7.2 (vermagic 7.2.0-rc5-dirty, MODVERSIONS=n).
KDIR ?= /mnt/data/LOA_Nubia_Z60U/build/linux-7.2
obj-m += cerro-pmic-glink-overlay.o

all: cerro-pmic-glink-overlay.dtbo.inc
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 LLVM=1 KBUILD_MODPOST_WARN=1 modules

cerro-pmic-glink-overlay.dtbo: cerro-pmic-glink-overlay.dts
	dtc -@ -I dts -O dtb -o $@ $<

cerro-pmic-glink-overlay.dtbo.inc: cerro-pmic-glink-overlay.dtbo
	od -An -t x1 -v $< | sed 's/ /,0x/g;s/^,//;s/$$/,/' > $@

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 LLVM=1 clean
	rm -f cerro-pmic-glink-overlay.dtbo cerro-pmic-glink-overlay.dtbo.inc
