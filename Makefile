QEMU ?= qemu-system-riscv64
QEMU_MEMORY ?= 4G
QEMU_SMP ?= 4
INITRD_ADDR ?= 0x84000000

KERNEL_ELF := bin/akernel.elf
INIT_ELF := bin/userspace/init.elf
SERIAL_ELF := bin/userspace/serial.elf
FUZZ_ELF := bin/userspace/fuzz.elf
SPIN_ELF := bin/userspace/spin.elf
MEMSTAGE_ELF := bin/userspace/memstage.elf
ECHO_ELF := bin/userspace/echo.elf
FILESERVER_ELF := bin/userspace/fileserver.elf
VIRTIO_RNG_ELF := bin/userspace/virtio_rng.elf
INITRD_ROOT := initrd/root
INITRD_OUT := initrd/out
INITRD_CPIO := $(INITRD_OUT)/initramfs.cpio
INITRD_IMG := $(INITRD_OUT)/akernel-initrd.img

.PHONY: all kernel userspace init serial fuzz spin memstage echo fileserver virtio_rng initrd run clean clean-kernel clean-userspace clean-initrd

all: kernel initrd

kernel:
	alr build

userspace: init serial fuzz spin memstage echo fileserver

init:
	$(MAKE) -C userspace/init

serial:
	$(MAKE) -C userspace/serial

fuzz:
	$(MAKE) -C userspace/fuzz

spin:
	$(MAKE) -C userspace/spin

memstage:
	$(MAKE) -C userspace/memstage

echo:
	$(MAKE) -C userspace/echo

fileserver:
	$(MAKE) -C userspace/fileserver

virtio_rng:
	$(MAKE) -C userspace/virtio_rng

initrd: $(INITRD_IMG)

$(INITRD_IMG): init serial fuzz spin memstage echo fileserver virtio_rng tools/mkinitrd.py
	rm -rf $(INITRD_ROOT)
	mkdir -p $(INITRD_ROOT)/System $(INITRD_ROOT)/Drivers $(INITRD_ROOT)/Tests $(INITRD_OUT)
	cp $(INIT_ELF) $(INITRD_ROOT)/System/Init
	cp $(FILESERVER_ELF) $(INITRD_ROOT)/System/Fileserver
	printf '%s\n' 'driver virtio,mmio Drivers/VirtioRng virtio 4' > $(INITRD_ROOT)/System/Drivers
	cp $(VIRTIO_RNG_ELF) $(INITRD_ROOT)/Drivers/VirtioRng
	cp $(SERIAL_ELF) $(INITRD_ROOT)/Drivers/Serial
	cp $(FUZZ_ELF) $(INITRD_ROOT)/Tests/Fuzz
	cp $(SPIN_ELF) $(INITRD_ROOT)/Tests/Spin
	cp $(MEMSTAGE_ELF) $(INITRD_ROOT)/Tests/Memstage
	cp $(ECHO_ELF) $(INITRD_ROOT)/Tests/Echo
	printf '%s\n' 'program 1 Drivers/Serial uart/mmio uart/irq console_server' > $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'volume RD0 Initrd ci' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 2 System/Fileserver fs_server console boot_files' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 3 Tests/Fuzz ipc_test console Tests/Echo fs System/Manifest' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 4 Tests/Spin console' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' '# file Tests/Echo' >> $(INITRD_ROOT)/System/Manifest
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
	  -device loader,file=$(INITRD_IMG),addr=$(INITRD_ADDR) \
	  -global virtio-mmio.force-legacy=false \
	  -device virtio-rng-device

clean: clean-kernel clean-userspace clean-initrd

clean-kernel:
	alr clean

clean-userspace:
	$(MAKE) -C userspace/init clean
	$(MAKE) -C userspace/serial clean

clean-initrd:
	rm -rf $(INITRD_ROOT) $(INITRD_OUT)
