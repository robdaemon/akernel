QEMU ?= qemu-system-riscv64
QEMU_MEMORY ?= 4G
QEMU_SMP ?= 4
#  Extra flags appended to the qemu command line. Default is
#  headless (-nographic: serial on stdio for the test harness);
#  override for interactive testing, e.g.
#  make run QEMU_ARGS="-display gtk" — the later -display wins
#  and serial stays on stdio.
QEMU_ARGS ?= -nographic
INITRD_ADDR ?= 0x84000000

KERNEL_ELF := bin/akernel.elf
INIT_ELF := bin/userspace/init.elf
SERIAL_ELF := bin/userspace/serial.elf
FUZZ_ELF := bin/userspace/fuzz.elf
SPIN_ELF := bin/userspace/spin.elf
MEMSTAGE_ELF := bin/userspace/memstage.elf
ECHO_ELF := bin/userspace/echo.elf
FILESERVER_ELF := bin/userspace/fileserver.elf
FAT32_ELF := bin/userspace/fat32.elf
PARTMGR_ELF := bin/userspace/partmgr.elf
VIRTIO_RNG_ELF := bin/userspace/virtio_rng.elf
VIRTIO_BLK_ELF := bin/userspace/virtio_blk.elf
VIRTIO_INPUT_ELF := bin/userspace/virtio_input.elf
VIRTIO_GPU_ELF := bin/userspace/virtio_gpu.elf
BUREAU_ELF := bin/userspace/bureau.elf
TERMINAL_ELF := bin/userspace/terminal.elf
DEMO_ELF := bin/userspace/demo.elf
SHELL_ELF := bin/userspace/shell.elf
DIR_ELF := bin/userspace/dir.elf
DISK_IMG := disk.img
INITRD_ROOT := initrd/root
INITRD_OUT := initrd/out
INITRD_CPIO := $(INITRD_OUT)/initramfs.cpio
INITRD_IMG := $(INITRD_OUT)/akernel-initrd.img

.PHONY: all kernel userspace init serial fuzz spin memstage echo fileserver fat32 partmgr virtio_rng virtio_blk virtio_input virtio_gpu bureau terminal demo shell dir initrd run clean clean-kernel clean-userspace clean-initrd

all: kernel initrd bureau terminal demo shell dir

kernel:
	alr build

userspace: init serial fuzz spin memstage echo fileserver fat32 partmgr

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

fat32:
	$(MAKE) -C userspace/fat32

partmgr:
	$(MAKE) -C userspace/partmgr

virtio_rng:
	$(MAKE) -C userspace/virtio_rng

virtio_blk:
	$(MAKE) -C userspace/virtio_blk

virtio_input:
	$(MAKE) -C userspace/virtio_input

virtio_gpu:
	$(MAKE) -C userspace/virtio_gpu

bureau:
	$(MAKE) -C userspace/bureau

terminal:
	$(MAKE) -C userspace/terminal

demo:
	$(MAKE) -C userspace/demo

shell:
	$(MAKE) -C userspace/shell

dir:
	$(MAKE) -C userspace/dir

#  64 MiB GPT data disk (host sgdisk + mkfs.vfat --offset +
#  mtools @@offset): partition 1 at sector 2048, 60 MiB FAT32 with
#  README.TXT, BIG.BIN (byte i = (i*7+3) mod 256, 64 KiB
#  multi-cluster chain), SUBDIR/HELLO.TXT and LongFileName.txt.
#  System/Partmgr serves the partition to System/Fat32 behind the
#  file server's VFS; the raw device (incl. GPT) stays WD0:disk
#  (BD0 = the FAT32 filesystem, label Sys, milestone 29).
#  Phony crate deps (not the ELF files: those have no rule) so
#  the images actually rebuild before being mcopy'd.
$(DISK_IMG): bureau terminal demo shell dir
	mkdir -p $(INITRD_OUT)
	printf 'Hello from the akernel FAT32 volume.\n' > $(INITRD_OUT)/readme.txt
	python3 -c "open('$(INITRD_OUT)/big.bin','wb').write(bytes(((i * 7 + 3) & 0xFF) for i in range(65536)))"
	printf 'Subdir hello!\n' > $(INITRD_OUT)/hello.txt
	printf 'A long file name body.\n' > $(INITRD_OUT)/longfile.txt
	rm -f $@
	truncate -s 67108864 $@
	sgdisk -n 1:2048:+60M -t 1:0700 -c 1:Sys $@ >/dev/null
	mkfs.vfat -F 32 -S 512 -s 1 -n Sys --offset 2048 $@ 61440 >/dev/null
	mcopy -i $@@@1048576 $(INITRD_OUT)/readme.txt ::README.TXT
	mcopy -i $@@@1048576 $(INITRD_OUT)/big.bin ::BIG.BIN
	mmd -i $@@@1048576 ::SUBDIR
	mcopy -i $@@@1048576 $(INITRD_OUT)/hello.txt ::SUBDIR/HELLO.TXT
	mcopy -i $@@@1048576 $(INITRD_OUT)/longfile.txt "::LongFileName.txt"
	mmd -i $@@@1048576 ::System
	mcopy -i $@@@1048576 $(BUREAU_ELF) ::System/Bureau
	mcopy -i $@@@1048576 $(TERMINAL_ELF) ::System/Terminal
	mcopy -i $@@@1048576 $(DEMO_ELF) ::System/Demo
	mcopy -i $@@@1048576 $(SHELL_ELF) ::System/Shell
	mmd -i $@@@1048576 ::C
	mcopy -i $@@@1048576 $(DIR_ELF) ::C/Dir
	printf 'System/Bureau\nSystem/Terminal\nSystem/Demo\n' > $(INITRD_OUT)/startup
	mcopy -i $@@@1048576 $(INITRD_OUT)/startup ::System/Startup

initrd: $(INITRD_IMG)

#  Bureau/Terminal deliberately NOT in the initrd (milestone 29):
#  they live on the Sys filesystem (disk.img :System/) and the
#  devmgr spawns them from there via Sys:System/Startup.
$(INITRD_IMG): init serial fuzz spin memstage echo fileserver fat32 partmgr virtio_rng virtio_blk virtio_input virtio_gpu tools/mkinitrd.py
	rm -rf $(INITRD_ROOT)
	mkdir -p $(INITRD_ROOT)/System $(INITRD_ROOT)/Drivers $(INITRD_ROOT)/Tests $(INITRD_OUT)
	cp $(INIT_ELF) $(INITRD_ROOT)/System/Init
	cp $(FILESERVER_ELF) $(INITRD_ROOT)/System/Fileserver
	cp $(FAT32_ELF) $(INITRD_ROOT)/System/Fat32
	cp $(PARTMGR_ELF) $(INITRD_ROOT)/System/Partmgr
	printf '%s\n' 'driver ns16550a Drivers/Serial none 0' > $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioRng pci 4' >> $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioBlk pci 2' >> $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioInput pci 18' >> $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioGpu pci 16' >> $(INITRD_ROOT)/System/Drivers
	cp $(VIRTIO_RNG_ELF) $(INITRD_ROOT)/Drivers/VirtioRng
	cp $(VIRTIO_BLK_ELF) $(INITRD_ROOT)/Drivers/VirtioBlk
	cp $(VIRTIO_INPUT_ELF) $(INITRD_ROOT)/Drivers/VirtioInput
	cp $(VIRTIO_GPU_ELF) $(INITRD_ROOT)/Drivers/VirtioGpu
	cp $(SERIAL_ELF) $(INITRD_ROOT)/Drivers/Serial
	cp $(FUZZ_ELF) $(INITRD_ROOT)/Tests/Fuzz
	cp $(SPIN_ELF) $(INITRD_ROOT)/Tests/Spin
	cp $(MEMSTAGE_ELF) $(INITRD_ROOT)/Tests/Memstage
	cp $(ECHO_ELF) $(INITRD_ROOT)/Tests/Echo
	printf '%s\n' 'volume RD0 Initrd ci' > $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 2 System/Fileserver fs_server console boot_files' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 3 Tests/Fuzz ipc_test console Tests/Echo fs System/Manifest part0' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 4 Tests/Spin console' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 5 System/Partmgr console blk part_server' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 6 System/Fat32 console part0 fat32_server' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' '# file Tests/Echo' >> $(INITRD_ROOT)/System/Manifest
	cd $(INITRD_ROOT) && find . -print | sort | cpio --quiet -o -H newc > ../../$(INITRD_CPIO)
	python3 tools/mkinitrd.py $(INITRD_CPIO) $(INITRD_IMG)

$(INIT_ELF):
	$(MAKE) -C userspace/init

run: all $(DISK_IMG)
	$(QEMU) \
	  -machine virt,iommu-sys=on \
	  -smp $(QEMU_SMP) \
	  -m $(QEMU_MEMORY) \
	  -kernel $(KERNEL_ELF) \
	  -device loader,file=$(INITRD_IMG),addr=$(INITRD_ADDR) \
	  -device virtio-rng-pci,addr=0x3 \
	  -drive file=$(DISK_IMG),if=none,id=hd0,format=raw \
	  -device virtio-blk-pci,drive=hd0,addr=0x4 \
	  -device virtio-keyboard-pci,addr=0x5 \
	  -device virtio-tablet-pci,addr=0x6 \
	  -device virtio-gpu-pci,addr=0x7 \
	  -monitor unix:/tmp/qmon.sock,server,nowait \
  -qmp unix:/tmp/qqmp.sock,server,nowait \
  $(QEMU_ARGS)

clean: clean-kernel clean-userspace clean-initrd

clean-kernel:
	alr clean

clean-userspace:
	$(MAKE) -C userspace/init clean
	$(MAKE) -C userspace/serial clean

clean-initrd:
	rm -rf $(INITRD_ROOT) $(INITRD_OUT)
