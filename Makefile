QEMU ?= qemu-system-riscv64
QEMU_MEMORY ?= 4G
QEMU_SMP ?= 4
#  Host disk-image tools (sgdisk, mkfs.vfat, mcopy) live in
#  /usr/sbin on Debian-derived systems; ensure that directory is on
#  PATH for recipes even when the invoking shell omits it.
export PATH := /usr/local/sbin:/usr/sbin:/sbin:$(PATH)
#  Manifest mode: interactive (default, `make run` — no test
#  programs) vs test (`make test` — Fuzz/Spin slots boot).
#  The initrd regenerates on every build (FORCE below) so a
#  mode switch can never boot a stale manifest.
INITRD_MODE ?= interactive
#  Extra flags appended to the qemu command line. Default is
#  headless (-nographic: serial on stdio for the test harness);
#  override for interactive testing, e.g.
#  make run QEMU_ARGS="-display gtk" — the later -display wins
#  and serial stays on stdio.
QEMU_ARGS ?= -nographic
#  virtio-9p host share (m79): the Host: volume is runtime opt-in —
#  the guest reacts to the device on the PCI bus, there is no
#  guest-side configuration. `make test` appends QEMU_9P_FLAGS so
#  the suite gates the share; interactive boots opt in with qemu
#  args, e.g.
#    make run QEMU_ARGS="-nographic $(QEMU_9P_FLAGS)"
#  Set QEMU_9P_FLAGS= (empty) to run the suite without the device
#  (fuzz then prints SKIP for the Host: checks).
SHARE_DIR ?= $(CURDIR)/share
QEMU_9P_FLAGS ?= -fsdev local,id=fs0,path=$(SHARE_DIR),security_model=none -device virtio-9p-pci,fsdev=fs0,mount_tag=host,addr=0x9
#  m80g: display geometry opt-in — the driver/bureau/terminal
#  ceilings are 1920x1080 but the device default stays 1024x768.
#  Boot big with e.g. QEMU_GPU_FLAGS=",xres=1920,yres=1080".
#  Overrides the saved ENV:Screen.Width/Height (M90); with neither,
#  QEMU's default (1280x800) applies.
QEMU_GPU_FLAGS ?=
INITRD_ADDR ?= 0x84000000

KERNEL_ELF := bin/akernel.elf
INIT_ELF := bin/userspace/init.elf
SERIAL_ELF := bin/userspace/serial.elf
FUZZ_ELF := bin/userspace/fuzz.elf
SPIN_ELF := bin/userspace/spin.elf
THREAD_TEST_ELF := bin/userspace/thread_test.elf
TASK_TEST_ELF := bin/userspace/task_test.elf
MEMSTAGE_ELF := bin/userspace/memstage.elf
ECHO_SERVER_ELF := bin/userspace/echo_server.elf
TEARDOWN_ELF := bin/userspace/teardown.elf
FILESERVER_ELF := bin/userspace/fileserver.elf
FAT32_ELF := bin/userspace/fat32.elf
PARTMGR_ELF := bin/userspace/partmgr.elf
PROCFS_ELF := bin/userspace/procfs.elf
NETSERV_ELF := bin/userspace/netserv.elf
NET_TEST_ELF := bin/userspace/net_test.elf
UDP_TEST_ELF := bin/userspace/udp_test.elf
TCP_TEST_ELF := bin/userspace/tcp_test.elf
GSOCK_TEST_ELF := bin/userspace/gsock_test.elf
DHCP_TEST_ELF := bin/userspace/dhcp_test.elf
BFS_ELF := bin/userspace/bfs.elf
VIRTIO_RNG_ELF := bin/userspace/virtio_rng.elf
VIRTIO_BLK_ELF := bin/userspace/virtio_blk.elf
VIRTIO_NET_ELF := bin/userspace/virtio_net.elf
VIRTIO_9P_ELF := bin/userspace/virtio_9p.elf
VIRTIO_INPUT_ELF := bin/userspace/virtio_input.elf
VIRTIO_GPU_ELF := bin/userspace/virtio_gpu.elf
LIBMAN_ELF := bin/userspace/libman.elf
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
INITRD_CRATES := init serial fuzz spin thread_test task_test memstage echo_server teardown fileserver fat32 bfs partmgr procfs netserv net_test udp_test tcp_test gsock_test dhcp_test virtio_rng virtio_blk virtio_net virtio_9p virtio_input virtio_gpu libman
DISK_CRATES_SYSTEM := bureau terminal demo tdemo edit shell elevated shutdown reboot fileman drawer
DISK_CRATES_C := dir type copy delete rename makedir info set get unset assign echo which version fault join search sort list cd path elevate testlib_client date wait execute ping query
DISK_CRATES_LIBS := testlib
#  Prefs drawer apps (M89): nested crates userspace/prefs/<name>;
#  binaries install in Sys:Prefs/<Capitalized>. Path entries ride
#  the generic $(CRATES) rule (make -C userspace/prefs/<name>).
DISK_CRATES_PREFS :=  prefs/font prefs/screenmode
CRATES := $(INITRD_CRATES) $(DISK_CRATES_SYSTEM) $(DISK_CRATES_C) $(DISK_CRATES_LIBS) $(DISK_CRATES_PREFS)

#  The userspace crates link against a custom GNAT runtime that is
#  vendored under userspace/gnat-rts.  It is not part of Alire's
#  dependency resolution, so a fresh clone has an empty adalib/ and
#  every userspace program fails to bind with "Cannot find: s-stalib.ali".
#  Build the runtime once before any userspace crate.
RTS_GPR := userspace/gnat-rts/runtime_build.gpr
RTS_LIB := userspace/gnat-rts/adalib/libgnat.a
#  The library must track its SOURCES too: depending on the gpr
#  alone left adalib/ stale after vendored-runtime edits (the m64
#  adaint.c __gnat_rename patch silently never linked).
RTS_SRCS := $(shell find userspace/rts/akernel userspace/gnat-rts/gnarl_user userspace/gnat-rts/gnat_full userspace/gnat-rts/gnat_user userspace/gnat-rts/gnat -type f)

.PHONY: all kernel rts userspace $(CRATES) initrd run test test-replay clean clean-kernel clean-rts clean-userspace clean-initrd new-crate FORCE

all: kernel initrd $(DISK_CRATES_SYSTEM) $(DISK_CRATES_C) $(DISK_CRATES_LIBS)

kernel:
	alr build

userspace: $(CRATES)

$(RTS_LIB): $(RTS_GPR) $(RTS_SRCS)
	printf '%s\n' gnarl_user gnat_user gnat_full gnat > userspace/gnat-rts/ada_source_path
	printf '%s\n' adalib > userspace/gnat-rts/ada_object_path
	alr exec -- gprbuild -P $(RTS_GPR)
	set -e; \
	RTS_OBJ=userspace/gnat-rts/obj; \
	RTS_LIBDIR=userspace/gnat-rts/adalib; \
	CORE_KEEP="system s-init s-soflin s-multip s-rident"; \
	rm -f $$RTS_LIBDIR/libgnarl.a; \
	alr exec -- riscv64-elf-ar rcs $$RTS_LIBDIR/libgnarl.a; \
	for src in userspace/gnat-rts/gnarl_user/*.adb userspace/gnat-rts/gnarl_user/*.ads; do \
	   base=$$(basename "$$src" .adb); base=$${base%.ads}; \
	   obj="$$RTS_OBJ/$${base}.o"; \
	   [ -f "$$obj" ] || continue; \
	   case " $$CORE_KEEP " in *" $$base "*) continue;; esac; \
	   alr exec -- riscv64-elf-ar rcs $$RTS_LIBDIR/libgnarl.a "$$obj"; \
	   alr exec -- riscv64-elf-ar d $$RTS_LIBDIR/libgnat.a "$${base}.o"; \
	done

#  NOT order-only: gprbuild does not see the RTS archives as
#  dependencies of a crate's .elf, so an order-only prereq leaves
#  stale binaries linked against the previous RTS (the m80e
#  debugging trap: rebuilt s-osinte.o, untouched fuzz.elf).
$(CRATES): $(RTS_LIB)
	$(MAKE) -C userspace/$@

#  Third-party fetch-at-build (milestone 72): vendored C libraries
#  are downloaded, checksum-verified, extracted and patched on
#  demand under third_party/ (gitignored; only third_party/patches/
#  is tracked). lwIP 2.2.1 is the first consumer: netserv links it
#  via userspace/lwip/lwip.gpr. GitHub mirror of the savannah
#  release tag (the savannah release mirrors 404 as of 2026-08).
LWIP_VER := 2.2.1
LWIP_TAG := STABLE-2_2_1_RELEASE
LWIP_TARBALL := third_party/download/lwip-$(LWIP_VER).tar.gz
LWIP_SHA256 := ce0b7461c0ad9602c376f0bf07c5eb7253b48c7bf66f011c6bf3e2a96731c539
LWIP_STAMP := third_party/lwip/.stamp-$(LWIP_VER)

$(LWIP_TARBALL):
	mkdir -p third_party/download
	curl -sL --fail --max-time 600 -o $@.tmp \
	  https://github.com/lwip-tcpip/lwip/archive/refs/tags/$(LWIP_TAG).tar.gz
	echo "$(LWIP_SHA256)  $@.tmp" | sha256sum -c -
	mv $@.tmp $@

$(LWIP_STAMP): $(LWIP_TARBALL) $(wildcard third_party/patches/lwip-*.patch)
	rm -rf third_party/lwip third_party/.lwip-extract
	mkdir -p third_party/.lwip-extract
	tar xzf $(LWIP_TARBALL) -C third_party/.lwip-extract
	mv third_party/.lwip-extract/lwip-$(LWIP_TAG) third_party/lwip
	rmdir third_party/.lwip-extract
	set -e; for p in third_party/patches/lwip-*.patch; do \
	  [ -e "$$p" ] || break; \
	  patch -d third_party/lwip -p1 < "$$p"; \
	done
	touch $@

netserv: $(LWIP_STAMP)

#  Terminus font (milestone 89): OFL-licensed BDFs for Sys:Fonts/
#  so Prefs/Font has real families/sizes to offer. Fetch is
#  sha256-pinned per the no-vendored-code rule; the disk recipe
#  copies the three <=8px-wide normal weights plus OFL.TXT.
TERMINUS_VER := 4.49.1
TERMINUS_TARBALL := third_party/download/terminus-font-$(TERMINUS_VER).tar.gz
TERMINUS_SHA256 := d961c1b781627bf417f9b340693d64fc219e0113ad3a3af1a3424c7aa373ef79
TERMINUS_STAMP := third_party/terminus/.stamp-$(TERMINUS_VER)

$(TERMINUS_TARBALL):
	mkdir -p third_party/download
	curl -sL --fail --max-time 600 -o $@.tmp \
	  https://sourceforge.net/projects/terminus-font/files/terminus-font-4.49/terminus-font-$(TERMINUS_VER).tar.gz/download
	echo "$(TERMINUS_SHA256)  $@.tmp" | sha256sum -c -
	mv $@.tmp $@

$(TERMINUS_STAMP): $(TERMINUS_TARBALL)
	rm -rf third_party/terminus third_party/.terminus-extract
	mkdir -p third_party/.terminus-extract
	tar xzf $(TERMINUS_TARBALL) -C third_party/.terminus-extract
	mv third_party/.terminus-extract/terminus-font-$(TERMINUS_VER) third_party/terminus
	rmdir third_party/.terminus-extract
	touch $@























#  72 MiB GPT data disk (host sgdisk + mkfs.vfat --offset +
#  mtools @@offset): partition 1 at sector 2048, 60 MiB FAT32 with
#  README.TXT, BIG.BIN (byte i = (i*7+3) mod 256, 64 KiB
#  multi-cluster chain), SUBDIR/HELLO.TXT and LongFileName.txt.
#  Partition 2 (milestone 82b): 8 MiB BeFS fixture generated by
#  tools/mkbefs.py (GPT type GUID is Haiku's registered BeFS GUID;
#  the M82c BFS server will serve it) and dd'd in at the partition
#  offset that sgdisk reports.
#  System/Partmgr serves the partition to System/Fat32 behind the
#  file server's VFS; the raw device (incl. GPT) stays WD0:disk
#  (BD0 = the FAT32 filesystem, label Sys, milestone 29).
#  Phony crate deps (not the ELF files: those have no rule) so
#  the images actually rebuild before being mcopy'd.
$(DISK_IMG): $(DISK_CRATES_SYSTEM) $(DISK_CRATES_C) $(DISK_CRATES_LIBS) $(DISK_CRATES_PREFS) $(TERMINUS_STAMP)
	@if [ -f $@ ]; then \
	  rm -rf /tmp/ak-prefs-env; \
	  mcopy -s -i $@@@1048576 ::Prefs/Env /tmp/ak-prefs-env 2>/dev/null || true; \
	fi
	rm -f $@
	@command -v sgdisk >/dev/null && command -v mkfs.vfat >/dev/null && command -v mcopy >/dev/null \
	  || { echo "disk image needs host sgdisk + mkfs.vfat + mtools"; exit 1; }; \
	mkdir -p $(INITRD_OUT); \
	printf 'Hello from the akernel FAT32 volume.\n' > $(INITRD_OUT)/readme.txt; \
	python3 -c "open('$(INITRD_OUT)/big.bin','wb').write(bytes(((i * 7 + 3) & 0xFF) for i in range(65536)))"; \
	printf 'Subdir hello!\n' > $(INITRD_OUT)/hello.txt; \
	printf 'A long file name body.\n' > $(INITRD_OUT)/longfile.txt; \
	truncate -s 75497472 $@; \
	sgdisk -n 1:2048:+60M -t 1:0700 -c 1:Sys $@ >/dev/null; \
	sgdisk -n 2:0:+8M -t 2:42465331-3ba3-10f1-802a-4861696b7521 -c 2:Befs $@ >/dev/null; \
	BEFS_START=$$(sgdisk -i 2 $@ | sed -n 's/^First sector: \([0-9]*\).*/\1/p'); \
	python3 tools/mkbefs.py $(INITRD_OUT)/befs.img; \
	dd if=$(INITRD_OUT)/befs.img of=$@ bs=512 seek=$$BEFS_START conv=notrunc status=none; \
	mkfs.vfat -F 32 -S 512 -s 8 -n Sys --offset 2048 $@ 61440 >/dev/null; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/readme.txt ::README.TXT; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/big.bin ::BIG.BIN; \
	mmd -i $@@@1048576 ::SUBDIR; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/hello.txt ::SUBDIR/HELLO.TXT; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/longfile.txt "::LongFileName.txt"; \
	mmd -i $@@@1048576 ::System; \
	mmd -i $@@@1048576 ::C; \
	mmd -i $@@@1048576 ::Fonts; \
	python3 tools/font2bdf.py userspace/rts/akernel/font8x8.ads > $(INITRD_OUT)/font8x8.bdf; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/font8x8.bdf ::Fonts/FONT8X8.BDF; \
	python3 tools/font2bdf.py userspace/rts/akernel/font8x8.ads --proportional > $(INITRD_OUT)/font8x8p.bdf; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/font8x8p.bdf ::Fonts/FONT8X8P.BDF; \
	python3 tools/font2bdf.py userspace/rts/akernel/font8x8.ads --tall > $(INITRD_OUT)/font8x8t.bdf; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/font8x8t.bdf ::Fonts/FONT8X8T.BDF; \
	for f in ter-u12n ter-u14n ter-u16n; do \
	  up=$$(printf '%s' $$f | tr a-z A-Z); \
	  mcopy -i $@@@1048576 third_party/terminus/$$f.bdf "::Fonts/$$up.BDF"; done; \
	mcopy -i $@@@1048576 third_party/terminus/OFL.TXT ::Fonts/OFL.TXT; \
	mmd -i $@@@1048576 ::Tests; \
	mmd -i $@@@1048576 ::Tests/Img; \
	python3 tools/gen_images.py $(INITRD_OUT)/img; \
	for f in bars keyed grad32 trunc; do \
	  mcopy -i $@@@1048576 $(INITRD_OUT)/img/$$f.bmp "::Tests/Img/$$(printf '%s' $$f | tr a-z A-Z).BMP"; done; \
	for f in checker cpp2 bad; do \
	  mcopy -i $@@@1048576 assets/tests/$$f.xpm "::Tests/Img/$$(printf '%s' $$f | tr a-z A-Z).XPM"; done; \
	mmd -i $@@@1048576 ::System/Icons; \
	for f in defdraw deffile deftool; do \
	  mcopy -i $@@@1048576 assets/icons/$$f.xpm "::System/Icons/$$(printf '%s' $$f | tr a-z A-Z).XPM"; done; \
	mmd -i $@@@1048576 ::System/Icons32; \
	for f in volume drawer file tool fileman terminal edit font screenmode; do \
	  mcopy -i $@@@1048576 assets/icons32/$$f.xpm "::System/Icons32/$$(printf '%s' $$f | tr a-z A-Z).XPM"; done; \
	mmd -i $@@@1048576 ::Libs; \
	for c in $(DISK_CRATES_LIBS); do \
	  alr exec -- riscv64-elf-strip -o /tmp/ak-$$c.elf bin/userspace/$$c.elf; \
	  mcopy -i $@@@1048576 /tmp/ak-$$c.elf "::Libs/$$(printf '%s' $$c | sed 's/^./\u&/')"; done; \
	for c in $(DISK_CRATES_SYSTEM); do \
	  alr exec -- riscv64-elf-strip -o /tmp/ak-$$c.elf bin/userspace/$$c.elf; \
	  mcopy -i $@@@1048576 /tmp/ak-$$c.elf "::System/$$(printf '%s' $$c | sed 's/^./\u&/')"; done; \
	for c in $(DISK_CRATES_C); do \
	  alr exec -- riscv64-elf-strip -o /tmp/ak-$$c.elf bin/userspace/$$c.elf; \
	  mcopy -i $@@@1048576 /tmp/ak-$$c.elf "::C/$$(printf '%s' $$c | sed 's/^./\u&/')"; done; \
	mmd -i $@@@1048576 ::Prefs; \
	for c in $(DISK_CRATES_PREFS); do \
	  n=$$(basename $$c); \
	  alr exec -- riscv64-elf-strip -o /tmp/ak-$$n.elf bin/userspace/$$n.elf; \
	  mcopy -i $@@@1048576 /tmp/ak-$$n.elf "::Prefs/$$(printf '%s' $$n | sed 's/^./\u&/')"; done; \
	if [ -d /tmp/ak-prefs-env ]; then \
	  mmd -i $@@@1048576 ::Prefs/Env; \
	  mcopy -i $@@@1048576 /tmp/ak-prefs-env/* ::Prefs/Env 2>/dev/null || true; \
	  rm -rf /tmp/ak-prefs-env; \
	fi; \
	printf 'System/Bureau\nSystem/Demo\nSystem/Tdemo\nSystem/Fileman\nSystem/Terminal\n' > $(INITRD_OUT)/startup; \
	mcopy -i $@@@1048576 $(INITRD_OUT)/startup ::System/Startup

initrd: $(INITRD_IMG)

#  Bureau/Terminal deliberately NOT in the initrd (milestone 29):
#  they live on the Sys filesystem (disk.img :System/) and the
#  devmgr spawns them from there via Sys:System/Startup.
#  Milestone 53a: images install STRIPPED ELFs (the full runtime's
#  debug info + unwind tables tripled file sizes; staging buffers
#  are sized from the file). Symbols stay in bin/userspace/*.elf.
$(INITRD_IMG): $(INITRD_CRATES) tools/mkinitrd.py FORCE
	rm -rf $(INITRD_ROOT)
	mkdir -p $(INITRD_ROOT)/System $(INITRD_ROOT)/Drivers $(INITRD_ROOT)/Tests $(INITRD_OUT)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Init $(INIT_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Fileserver $(FILESERVER_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Fat32 $(FAT32_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Bfs $(BFS_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Partmgr $(PARTMGR_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Procfs $(PROCFS_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Netserv $(NETSERV_ELF)
	printf '%s\n' 'driver ns16550a Drivers/Serial none 0' > $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioRng pci 4' >> $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioBlk pci 2' >> $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioNet pci 1' >> $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/Virtio9p pci 9' >> $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioInput pci 18' >> $(INITRD_ROOT)/System/Drivers
	printf '%s\n' 'driver pci,1af4 Drivers/VirtioGpu pci 16' >> $(INITRD_ROOT)/System/Drivers
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/VirtioRng $(VIRTIO_RNG_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/VirtioBlk $(VIRTIO_BLK_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/VirtioNet $(VIRTIO_NET_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/Virtio9p $(VIRTIO_9P_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/VirtioInput $(VIRTIO_INPUT_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/VirtioGpu $(VIRTIO_GPU_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Drivers/Serial $(SERIAL_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Fuzz $(FUZZ_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Spin $(SPIN_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Thread_Test $(THREAD_TEST_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Task_Test $(TASK_TEST_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Memstage $(MEMSTAGE_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Echo_Server $(ECHO_SERVER_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Teardown $(TEARDOWN_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Net_Test $(NET_TEST_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Udp_Test $(UDP_TEST_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Tcp_Test $(TCP_TEST_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Gsock_Test $(GSOCK_TEST_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/Tests/Dhcp_Test $(DHCP_TEST_ELF)
	alr exec -- riscv64-elf-strip -o $(INITRD_ROOT)/System/Libman $(LIBMAN_ELF)
	mkdir -p $(INITRD_ROOT)/Tests/Gen
	for i in $$(seq -w 0 63); do \
		printf 'GENFILE f%s\n' $$i > $(INITRD_ROOT)/Tests/Gen/f$$i; \
	done
	printf '%s\n' 'volume RD0 Initrd ci' > $(INITRD_ROOT)/System/Manifest
	printf '%s\n' "$$(date +%s)" > $(INITRD_ROOT)/System/Epoch
	printf '%s\n' 'program 2 System/Fileserver fs_server console boot_files' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 8 System/Libman console fs libman_server' >> $(INITRD_ROOT)/System/Manifest
ifeq ($(INITRD_MODE),task_test)
	printf '%s\n' 'program 3 Tests/Task_Test console' >> $(INITRD_ROOT)/System/Manifest
endif
ifeq ($(INITRD_MODE),test)
	printf '%s\n' 'program 3 Tests/Fuzz ipc_test console Tests/Echo_Server fs System/Manifest libman part0 device_resource admin elevated_svc net' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 4 Tests/Spin console' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 9 Tests/Thread_Test' >> $(INITRD_ROOT)/System/Manifest
endif
	printf '%s\n' 'program 5 System/Partmgr console blk part_server' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 6 System/Fat32 console part0 fat32_server' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 17 System/Bfs console part1 bfs_server' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 7 System/Procfs console procfs_server device_resource admin' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 10 System/Netserv console fs netdev net_server net_register' >> $(INITRD_ROOT)/System/Manifest
ifeq ($(INITRD_MODE),test)
	printf '%s\n' 'program 11 Tests/Net_Test console net' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 12 Tests/Udp_Test console fs net' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 13 Tests/Tcp_Test console fs net' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 14 Tests/Gsock_Test console fs net' >> $(INITRD_ROOT)/System/Manifest
	printf '%s\n' 'program 15 Tests/Dhcp_Test console fs net' >> $(INITRD_ROOT)/System/Manifest
endif
	printf '%s\n' '# file Tests/Echo_Server' >> $(INITRD_ROOT)/System/Manifest
	cd $(INITRD_ROOT) && find . -print | sort | cpio --quiet -o -H newc > ../../$(INITRD_CPIO)
	python3 tools/mkinitrd.py $(INITRD_CPIO) $(INITRD_IMG)

$(INIT_ELF):
	$(MAKE) -C userspace/init

#  SKIP_DISK=1 skips the disk-image dependency (test-replay
#  injects a dirty journal into the built image; a rebuild would
#  wipe it).
#  M90: the GPU's boot resolution comes from the saved ScreenMode
#  prefs (ENV:Screen.Width/Height on the FAT partition) unless
#  QEMU_GPU_FLAGS is given explicitly.
run: all $(if $(SKIP_DISK),,$(DISK_IMG))
	@GPU="$(QEMU_GPU_FLAGS)"; \
	if [ -z "$$GPU" ]; then \
	  W=$$(mtype -i $(DISK_IMG)@@1048576 ::Prefs/Env/SCREEN.WIDTH 2>/dev/null | tr -d '\r\n'); \
	  H=$$(mtype -i $(DISK_IMG)@@1048576 ::Prefs/Env/SCREEN.HEIGHT 2>/dev/null | tr -d '\r\n'); \
	  case $$W in ''|*[!0-9]*) W= ;; esac; \
	  case $$H in ''|*[!0-9]*) H= ;; esac; \
	  if [ -n "$$W" ] && [ -n "$$H" ]; then GPU=",xres=$$W,yres=$$H"; fi; \
	fi; \
	if [ -n "$$GPU" ]; then echo "gpu flags:$$GPU"; fi; \
	$(QEMU) \
	  -semihosting \
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
	  -device virtio-gpu-pci,addr=0x7$$GPU \
	  -netdev user,id=n0 \
	  -device virtio-net-pci,netdev=n0,addr=0x8 \
	  -monitor unix:/tmp/qmon.sock,server,nowait \
  -qmp unix:/tmp/qqmp.sock,server,nowait \
  $(QEMU_ARGS)

FORCE:

#  `make test` boots the SAME system with the test manifest
#  (Fuzz + Spin program slots) — the fuzz suite self-runs and
#  shuts the machine down, exactly like the old `make run`.
#  m72c: Tests/Tcp_Test's wire half echoes through slirp to a
#  host-side server (guest 10.0.2.2 -> host 127.0.0.1), started
#  here for the duration of the boot.
test:
	@python3 tools/tcp_echo.py 10007 >/tmp/ak_tcp_echo.log 2>&1 & \
	PID=$$!; \
	if [ -n "$(QEMU_9P_FLAGS)" ]; then mkdir -p $(SHARE_DIR) && printf 'hello from the host\n' > $(SHARE_DIR)/host_seed.txt && printf 'delete me\n' > $(SHARE_DIR)/host_delete_me.txt; fi; \
	$(MAKE) run INITRD_MODE=test QEMU_ARGS="$(QEMU_ARGS) $(QEMU_9P_FLAGS)"; ST=$$?; \
	if [ -n "$(QEMU_9P_FLAGS)" ]; then \
	  grep -q "guest was here" $(SHARE_DIR)/FZHOST.TXT || { echo "FAIL host share guest write missing on host"; ST=1; }; \
	  test ! -e $(SHARE_DIR)/host_delete_me.txt || { echo "FAIL host share guest delete not visible on host"; ST=1; }; \
	fi; \
	kill $$PID 2>/dev/null; wait $$PID 2>/dev/null; \
	BEFS_START=$$(sgdisk -i 2 $(DISK_IMG) | sed -n 's/^First sector: \([0-9]*\).*/\1/p'); \
	python3 tools/befs_dump.py $(DISK_IMG) $$((BEFS_START * 512)) > $(INITRD_OUT)/befs_after.txt || { echo "FAIL befs post-test dump unparsable"; ST=1; }; \
	grep -q "(empty)" $(INITRD_OUT)/befs_after.txt || { echo "FAIL befs log not checkpointed after test"; ST=1; }; \
	grep -q "README.TXT  (36 bytes)" $(INITRD_OUT)/befs_after.txt || { echo "FAIL befs README missing after test"; ST=1; }; \
	grep -q "HELLO.TXT  (24 bytes)" $(INITRD_OUT)/befs_after.txt || { echo "FAIL befs HELLO missing after test"; ST=1; }; \
	grep -q "  name: 5 entries" $(INITRD_OUT)/befs_after.txt || { echo "FAIL befs name index out of sync after test"; ST=1; }; \
	grep -q "  size: 0 entries" $(INITRD_OUT)/befs_after.txt || { echo "FAIL befs size index out of sync after test"; ST=1; }; \
	grep -q "  last_modified: 0 entries" $(INITRD_OUT)/befs_after.txt || { echo "FAIL befs last_modified index out of sync after test"; ST=1; }; \
	if [ $$ST -eq 0 ]; then echo "befs post-test image check ok"; fi; \
	exit $$ST

clean: clean-kernel clean-rts clean-userspace clean-initrd

#  m82e: journal replay end-to-end. Injects a pending transaction
#  into the BeFS partition (tools/befs_mkdirty.py — README.TXT's
#  own data block re-journaled with identical content, superblock
#  DIRT), boots the fuzz suite: the mount must replay it
#  ("bfs: journal replayed"), every check must pass unchanged, and
#  the image must be checkpointed clean afterwards.
test-replay: $(DISK_IMG)
	@python3 tools/tcp_echo.py 10007 >/tmp/ak_tcp_echo.log 2>&1 & \
	PID=$$!; \
	BEFS_START=$$(sgdisk -i 2 $(DISK_IMG) | sed -n 's/^First sector: \([0-9]*\).*/\1/p'); \
	python3 tools/befs_mkdirty.py $(DISK_IMG) $$((BEFS_START * 512)) || { kill $$PID; exit 1; }; \
	$(MAKE) run INITRD_MODE=test SKIP_DISK=1 > $(INITRD_OUT)/replay.log 2>&1; \
	kill $$PID 2>/dev/null; wait $$PID 2>/dev/null; \
	grep -q "bfs: journal replayed" $(INITRD_OUT)/replay.log || { echo "FAIL journal replay not observed"; exit 1; }; \
	grep -q "fuzz complete" $(INITRD_OUT)/replay.log || { echo "FAIL fuzz suite did not complete"; exit 1; }; \
	test "$$(grep -c '^FAIL' $(INITRD_OUT)/replay.log)" = 0 || { echo "FAIL fuzz checks failed after replay"; exit 1; }; \
	BEFS_START=$$(sgdisk -i 2 $(DISK_IMG) | sed -n 's/^First sector: \([0-9]*\).*/\1/p'); \
	python3 tools/befs_dump.py $(DISK_IMG) $$((BEFS_START * 512)) | grep -q "(empty)" || { echo "FAIL log not clean after replay"; exit 1; }; \
	echo "journal replay test ok"

clean-kernel:
	alr clean

clean-rts:
	rm -rf userspace/gnat-rts/adalib userspace/gnat-rts/obj

clean-userspace:
	for c in $(CRATES); do $(MAKE) -C userspace/$$c clean; done
	rm -rf obj/userspace lib/userspace

#  Crate scaffolding (milestone 40c): make new-crate NAME=foo
#  DEST=c|system generates the crate wired to the RTS and
#  registers it in this Makefile. The skeleton main is a CLI
#  command (Akernel_User.CLI); DEST=system installs into
#  Sys:System/, DEST=c into Sys:C/.
new-crate:
	@test -n "$(NAME)" || { echo "usage: make new-crate NAME=foo DEST=c|system|prefs"; exit 1; }
	@test "$(DEST)" = "c" -o "$(DEST)" = "system" -o "$(DEST)" = "prefs" || { echo "DEST must be c, system or prefs"; exit 1; }
	@if [ "$(DEST)" = "prefs" ]; then dir="userspace/prefs/$(NAME)"; up="../.."; \
	else dir="userspace/$(NAME)"; up=".."; fi; \
	test ! -e $$dir || { echo "$$dir exists"; exit 1; }; \
	mkdir -p $$dir; \
	if [ "$(DEST)" = "prefs" ]; then \
	  rt='   for Runtime ("Ada") use "../../gnat-rts";\n'; else rt=''; fi; \
	printf '.PHONY: all clean\n\nall:\n\talr build\n\nclean:\n\talr clean\n' > $$dir/Makefile; \
	printf 'name = "akernel_$(NAME)"\ndescription = "akernel $(NAME)"\nversion = "0.1.0-dev"\n\nauthors = ["Robert Roland"]\nmaintainers = ["Robert Roland <rob@retronauts.org>"]\nlicenses = "MIT OR Apache-2.0 WITH LLVM-exception"\ntags = []\n\nproject-files = ["$(NAME).gpr"]\nexecutables = ["$(NAME).elf"]\n\n[[depends-on]]\ngnat_riscv64_elf = "15.3.1"\n' > $$dir/alire.toml; \
	cap=$$(printf '%s' $(NAME) | sed 's/^./\u&/'); \
	printf 'project %s extends "%s/rts/akernel_program.gpr" is\n%b   for Source_Dirs use (".");\n   for Exec_Dir use "%s/../bin/userspace";\n   for Object_Dir use "%s/../obj/userspace/%s";\n   for Main use ("%s.adb");\n\n   package Builder is\n      for Executable ("%s.adb") use "%s.elf";\n   end Builder;\nend %s;\n' $$cap $$up "$$rt" $$up $$up $(NAME) $(NAME) $(NAME) $(NAME) $$cap > $$dir/$(NAME).gpr; \
	printf 'with Akernel_User.CLI;\nwith Akernel_User.Console;\n\nprocedure %s is\n   package CLI renames Akernel_User.CLI;\nbegin\n   if CLI.Arg_Count = 0 then\n      Akernel_User.Console.Put_Line ("usage: %s <args>");\n      CLI.Exit_With (CLI.RC_Error);\n   end if;\n   CLI.Exit_With (CLI.RC_Ok);\nend %s;\n' $$cap $$cap $$cap > $$dir/$(NAME).adb
	@if [ "$(DEST)" = "c" ]; then \
	  sed -i 's/^DISK_CRATES_C := \(.*\)/DISK_CRATES_C := \1 $(NAME)/' Makefile; \
	  echo "$(NAME) registered: builds via all/disk.img, installs in Sys:C/"; \
	elif [ "$(DEST)" = "prefs" ]; then \
	  sed -i 's/^DISK_CRATES_PREFS :=\(.*\)/DISK_CRATES_PREFS :=\1 prefs\/$(NAME)/' Makefile; \
	  echo "$(NAME) registered: builds via all/disk.img, installs in Sys:Prefs/"; \
	else \
	  sed -i 's/^DISK_CRATES_SYSTEM := \(.*\)/DISK_CRATES_SYSTEM := \1 $(NAME)/' Makefile; \
	  echo "$(NAME) registered: builds via all/disk.img, installs in Sys:System/ (add to System/Startup in the disk recipe to launch)"; \
	fi

clean-initrd:
	rm -rf $(INITRD_ROOT) $(INITRD_OUT)
