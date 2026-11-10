# Out-of-tree against build/linux-7.2 (vermagic 7.2.0-rc5-dirty).
KDIR ?= /mnt/data/LOA_Nubia_Z60U/build/linux-7.2
obj-m += cerro-aud-pasthru.o
obj-m += cerro-audio-shmem.o

all:
	@test -f $(KDIR)/Module.symvers || ln -sf vmlinux.symvers $(KDIR)/Module.symvers
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 LLVM=1 KBUILD_MODPOST_WARN=1 modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 LLVM=1 clean

.PHONY: all clean
