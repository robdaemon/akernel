QEMU ?= qemu-system-riscv64
QEMU_MEMORY ?= 4G
QEMU_SMP ?= 1
INITRD_ADDR ?= 0x84000000

KERNEL_ELF := bin/akernel.elf
INIT_ELF := bin/userspace/init.elf
SERIAL_ELF := bin/userspace/serial.elf
FUZZ_ELF := bin/userspace/fuzz.elf
INITRD_ROOT := initrd/root
INITRD_OUT := initrd/out
INITRD_CPIO := $(INITRD_OUT)/initramfs.cpio
INITRD_IMG := $(INITRD_OUT)/akernel-initrd.img

.PHONY: all kernel userspace init serial fuzz initrd run clean clean-kernel clean-userspace clean-initrd

all: kernel initrd

kernel:
	alr build

userspace: init serial fuzz

init:
	$(MAKE) -C userspace/init

serial:
	$(MAKE) -C userspace/serial

fuzz:
	$(MAKE) -C userspace/fuzz

initrd: $(INITRD_IMG)

$(INITRD_IMG): init serial fuzz tools/mkinitrd.py
	rm -rf $(INITRD_ROOT)
	mkdir -p $(INITRD_ROOT)/System $(INITRD_ROOT)/Drivers $(INITRD_ROOT)/Tests $(INITRD_OUT)
	cp $(INIT_ELF) $(INITRD_ROOT)/System/Init
	cp $(SERIAL_ELF) $(INITRD_ROOT)/Drivers/Serial
	cp $(FUZZ_ELF) $(INITRD_ROOT)/Tests/Fuzz
	printf '%s\n' 'program 1 Drivers/Serial uart_mmio uart_irq' > $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 2 Tests/Fuzz' >> $(INITRD_ROOT)/System/Manifest
	cd $(INITRD_ROOT) && find . -print | sort | cpio --quiet -o -H newc > ../../$(INITRD_CPIO)
	python3 tools/mkinitrd.py $(INITRD_CPIO) $(INITRD_IMG)

$(INIT_ELF):
	$(MAKE) -C userspace/init

run: all
	$(QEMU) \
	  -machine virt \
	  -smp $(QEMU_SMP) \
	  -m $(QEMU_MEMORY) \
	  -nographic \
	  -kernel $(KERNEL_ELF) \
	  -device loader,file=$(INITRD_IMG),addr=$(INITRD_ADDR)

clean: clean-kernel clean-userspace clean-initrd

clean-kernel:
	alr clean

clean-userspace:
	$(MAKE) -C userspace/init clean
	$(MAKE) -C userspace/serial clean

clean-initrd:
	rm -rf $(INITRD_ROOT) $(INITRD_OUT)
