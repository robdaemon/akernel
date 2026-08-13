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
ECHO_SERVER_ELF := bin/userspace/echo_server.elf
TEARDOWN_ELF := bin/userspace/teardown.elf
FILESERVER_ELF := bin/userspace/fileserver.elf
FAT32_ELF := bin/userspace/fat32.elf
PARTMGR_ELF := bin/userspace/partmgr.elf
PROCFS_ELF := bin/userspace/procfs.elf
VIRTIO_RNG_ELF := bin/userspace/virtio_rng.elf
VIRTIO_BLK_ELF := bin/userspace/virtio_blk.elf
VIRTIO_INPUT_ELF := bin/userspace/virtio_input.elf
VIRTIO_GPU_ELF := bin/userspace/virtio_gpu.elf
BUREAU_ELF := bin/userspace/bureau.elf
TERMINAL_ELF := bin/userspace/terminal.elf
DEMO_ELF := bin/userspace/demo.elf
SHELL_ELF := bin/userspace/shell.elf
DIR_ELF := bin/userspace/dir.elf
TYPE_ELF := bin/userspace/type.elf
DISK_IMG := disk.img
INITRD_ROOT := initrd/root
INITRD_OUT := initrd/out
INITRD_CPIO := $(INITRD_OUT)/initramfs.cpio
INITRD_IMG := $(INITRD_OUT)/akernel-initrd.img

#  Crate inventory (milestone 40c): every userspace crate builds
#  through the generic $(CRATES) rule; disk-resident crates are
#  installed by capitalized name into Sys:System/ or Sys:C/.
#  `make new-crate NAME=foo DEST=c|system` appends here.
INITRD_CRATES := init serial fuzz spin memstage echo_server teardown fileserver fat32 partmgr procfs virtio_rng virtio_blk virtio_input virtio_gpu
DISK_CRATES_SYSTEM := bureau terminal demo shell elevated shutdown reboot
DISK_CRATES_C := dir type copy delete rename makedir info set get unset assign echo which version fault join search sort list cd path elevate
CRATES := $(INITRD_CRATES) $(DISK_CRATES_SYSTEM) $(DISK_CRATES_C)

.PHONY: all kernel userspace $(CRATES) initrd run clean clean-kernel clean-userspace clean-initrd new-crate

all: kernel initrd $(DISK_CRATES_SYSTEM) $(DISK_CRATES_C)

kernel:
	alr build

userspace: $(CRATES)

$(CRATES):
	$(MAKE) -C userspace/$@






















#  64 MiB GPT data disk (host sgdisk + mkfs.vfat --offset +
#  mtools @@offset): partition 1 at sector 2048, 60 MiB FAT32 with
#  README.TXT, BIG.BIN (byte i = (i*7+3) mod 256, 64 KiB
#  multi-cluster chain), SUBDIR/HELLO.TXT and LongFileName.txt.
#  System/Partmgr serves the partition to System/Fat32 behind the
#  file server's VFS; the raw device (incl. GPT) stays WD0:disk
#  (BD0 = the FAT32 filesystem, label Sys, milestone 29).
#  Phony crate deps (not the ELF files: those have no rule) so
#  the images actually rebuild before being mcopy'd.
$(DISK_IMG): $(DISK_CRATES_SYSTEM) $(DISK_CRATES_C)
	rm -f $@
	@command -v sgdisk >/dev/null && command -v mkfs.vfat >/dev/null && command -v mcopy >/dev/null \
	  || { echo "disk image needs host sgdisk + mkfs.vfat + mtools"; exit 1; }; \
	mkdir -p $(INITRD_OUT); \
	printf 'Hello from the akernel FAT32 volume.\n' > $(INITRD_OUT)/readme.txt; \
	python3 -c "open('$(INITRD_OUT)/big.bin','wb').write(bytes(((i * 7 + 3) & 0xFF) for i in range(65536)))"; \
	printf 'Subdir hello!\n' > $(INITRD_OUT)/hello.txt; \
	printf 'A long file name body.\n' > $(INITRD_OUT)/longfile.txt; \
	truncate -s 67108864 $@; \
	sgdisk -n 1:2048:+60M -t 1:0700 -c 1:Sys $@ >/dev/null; \
	mkfs.vfat -F 32 -S 512 -s 8 -n Sys --offset 2048 $@ 61440 >/dev/null; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/readme.txt ::README.TXT; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/big.bin ::BIG.BIN; \
	mmd -i $@@@1048576 ::SUBDIR; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/hello.txt ::SUBDIR/HELLO.TXT; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/longfile.txt "::LongFileName.txt"; \
	mmd -i $@@@1048576 ::System; \
	mmd -i $@@@1048576 ::C; \
	for c in $(DISK_CRATES_SYSTEM); do \
	  alr exec -- riscv64-elf-strip -o /tmp/ak-$$c.elf bin/userspace/$$c.elf; \
	  mcopy -i $@@@1048576 /tmp/ak-$$c.elf "::System/$$(printf '%s' $$c | sed 's/^./\u&/')"; done; \
	for c in $(DISK_CRATES_C); do \
	  alr exec -- riscv64-elf-strip -o /tmp/ak-$$c.elf bin/userspace/$$c.elf; \
	  mcopy -i $@@@1048576 /tmp/ak-$$c.elf "::C/$$(printf '%s' $$c | sed 's/^./\u&/')"; done; \
	printf 'System/Bureau\nSystem/Terminal\nSystem/Demo\n' > $(INITRD_OUT)/startup; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/startup ::System/Startup

initrd: $(INITRD_IMG)

#  Bureau/Terminal deliberately NOT in the initrd (milestone 29):
#  they live on the Sys filesystem (disk.img :System/) and the
#  devmgr spawns them from there via Sys:System/Startup.
#  Milestone 53a: images install STRIPPED ELFs (the full runtime's
#  debug info + unwind tables tripled file sizes; staging buffers
#  are sized from the file). Symbols stay in bin/userspace/*.elf.
$(INITRD_IMG): $(INITRD_CRATES) tools/mkinitrd.py
	rm -rf $(INITRD_ROOT)
	mkdir -p $(INITRD_ROOT)/System $(INITRD_ROOT)/Drivers $(INITRD_ROOT)/Tests $(INITRD_OUT)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Init $(INIT_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Fileserver $(FILESERVER_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Fat32 $(FAT32_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Partmgr $(PARTMGR_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Procfs $(PROCFS_ELF)
	printf '%s\n' 'driver ns16550a Drivers/Serial none 0' > $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioRng pci 4' >> $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioBlk pci 2' >> $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioInput pci 18' >> $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioGpu pci 16' >> $(INITRD_ROOT)/System/Drivers
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/VirtioRng $(VIRTIO_RNG_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/VirtioBlk $(VIRTIO_BLK_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/VirtioInput $(VIRTIO_INPUT_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/VirtioGpu $(VIRTIO_GPU_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/Serial $(SERIAL_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Fuzz $(FUZZ_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Spin $(SPIN_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Memstage $(MEMSTAGE_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Echo_Server $(ECHO_SERVER_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Teardown $(TEARDOWN_ELF)
	mkdir -p $(INITRD_ROOT)/Tests/Gen
	for i in $$(seq -w 0 63); do \
		printf 'GENFILE f%s\n' $$i > $(INITRD_ROOT)/Tests/Gen/f$$i; \
	done
	printf '%s\n' 'volume RD0 Initrd ci' > $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 2 System/Fileserver fs_server console boot_files' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 3 Tests/Fuzz ipc_test console Tests/Echo_Server fs System/Manifest part0 device_resource admin elevated_svc' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 4 Tests/Spin console' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 5 System/Partmgr console blk part_server' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 6 System/Fat32 console part0 fat32_server' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 7 System/Procfs console procfs_server device_resource admin' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' '# file Tests/Echo_Server' >> $(INITRD_ROOT)/System/Manifest
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
	for c in $(CRATES); do $(MAKE) -C userspace/$$c clean; done
	rm -rf obj/userspace lib/userspace

#  Crate scaffolding (milestone 40c): make new-crate NAME=foo
#  DEST=c|system generates the crate wired to the RTS and
#  registers it in this Makefile. The skeleton main is a CLI
#  command (Akernel_User.CLI); DEST=system installs into
#  Sys:System/, DEST=c into Sys:C/.
new-crate:
	@test -n "$(NAME)" || { echo "usage: make new-crate NAME=foo DEST=c|system"; exit 1; }
	@test "$(DEST)" = "c" -o "$(DEST)" = "system" || { echo "DEST must be c or system"; exit 1; }
	@test ! -e userspace/$(NAME) || { echo "userspace/$(NAME) exists"; exit 1; }
	mkdir -p userspace/$(NAME)
	printf '.PHONY: all clean\n\nall:\n\talr build\n\nclean:\n\talr clean\n' > userspace/$(NAME)/Makefile
	printf 'name = "akernel_$(NAME)"\ndescription = "akernel $(NAME)"\nversion = "0.1.0-dev"\n\nauthors = ["Robert Roland"]\nmaintainers = ["Robert Roland <rob@retronauts.org>"]\nlicenses = "MIT OR Apache-2.0 WITH LLVM-exception"\ntags = []\n\nproject-files = ["$(NAME).gpr"]\nexecutables = ["$(NAME).elf"]\n\n[[depends-on]]\ngnat_riscv64_elf = "*"\n' > userspace/$(NAME)/alire.toml
	cap=$$(printf '%s' $(NAME) | sed 's/^./\u&/'); \
	printf 'project %s extends "../rts/akernel_program.gpr" is\n   for Source_Dirs use (".");\n   for Exec_Dir use "../../bin/userspace";\n   for Object_Dir use "../../obj/userspace/%s";\n   for Main use ("%s.adb");\n\n   package Builder is\n      for Executable ("%s.adb") use "%s.elf";\n   end Builder;\nend %s;\n' $$cap $(NAME) $(NAME) $(NAME) $(NAME) $$cap > userspace/$(NAME)/$(NAME).gpr; \
	printf 'with Akernel_User.CLI;\nwith Akernel_User.Console;\n\nprocedure %s is\n   package CLI renames Akernel_User.CLI;\nbegin\n   if CLI.Arg_Count = 0 then\n      Akernel_User.Console.Put_Line ("usage: %s <args>");\n      CLI.Exit_With (CLI.RC_Error);\n   end if;\n   CLI.Exit_With (CLI.RC_Ok);\nend %s;\n' $$cap $$cap $$cap > userspace/$(NAME)/$(NAME).adb
	@if [ "$(DEST)" = "c" ]; then \
	  sed -i 's/^DISK_CRATES_C := \(.*\)/DISK_CRATES_C := \1 $(NAME)/' Makefile; \
	  echo "$(NAME) registered: builds via all/disk.img, installs in Sys:C/"; \
	else \
	  sed -i 's/^DISK_CRATES_SYSTEM := \(.*\)/DISK_CRATES_SYSTEM := \1 $(NAME)/' Makefile; \
	  echo "$(NAME) registered: builds via all/disk.img, installs in Sys:System/ (add to System/Startup in the disk recipe to launch)"; \
	fi

clean-initrd:
	rm -rf $(INITRD_ROOT) $(INITRD_OUT)
