# akernel

A small RISC-V 64 bare-metal kernel and Ada/SPARK userspace, built with
[Alire](https://alire.ada.dev/) and GPRbuild.  The kernel runs under QEMU
`virt` and boots from an in-memory initrd plus a FAT32 GPT disk image.

## Host dependencies

* **Alire** (`alr`) — the Ada package manager / build driver.
* **QEMU** with RISC-V system emulation: `qemu-system-riscv64`.
* **Host disk-image tools**: `sgdisk` (gdisk), `mkfs.vfat` (dosfstools),
  `mcopy`/`mmd` (mtools).
* **Standard build utilities**: `cpio`, `python3`, `truncate`, `make`.

The RISC-V cross compiler (`gnat_riscv64_elf`) is **not** installed through
your system package manager; Alire downloads it automatically on first build.

### Debian / Ubuntu example

```bash
sudo apt-get update
sudo apt-get install -y alr qemu-system-riscv gdisk dosfstools mtools \
                        cpio python3 coreutils make
```

(On some distributions the QEMU package is named `qemu-system-misc` or
`qemu-system-riscv`.)

## Initial build

1. Ensure `alr` is on your `PATH`.
2. Build the kernel and userspace:

```bash
make all
```

On a fresh clone this will:

* Resolve and fetch `gnat_riscv64_elf` through Alire (network required).
* Build the kernel (`alr build` / `akernel.gpr`).
* Build the custom userspace GNAT runtime under `userspace/gnat-rts`.
* Build all userspace crates and produce `initrd/out/akernel-initrd.img`.

`make all` intentionally does **not** build `disk.img`; that is produced by
`make run` / `make test` because it requires the disk-image host tools above.

## Running

Interactive session (headless, serial on stdio):

```bash
make run
```

Interactive session with the GTK display:

```bash
make run QEMU_ARGS="-display gtk"
```

Run the automated test suite:

```bash
make test
```

`make test` is the same as `make run INITRD_MODE=test`; it boots the same
system but with the test manifest (the `Fuzz` and `Spin` slots) and expects
the suite to shut QEMU down on its own.

Useful `make` variables:

* `QEMU_SMP=1|4|8` — number of cores (default `4`).
* `QEMU_MEMORY=...` — RAM size (default `4G`).
* `QEMU_ARGS=...` — extra QEMU flags (default `-nographic`).

## Useful commands

```bash
# Clean everything Alire/GPRbuild generated (kernel, userspace, initrd)
make clean

# Scaffold a new userspace command crate
make new-crate NAME=foo DEST=c      # installs into Sys:C/
make new-crate NAME=bar DEST=system # installs into Sys:System/
```

## Common problems

* **"disk image needs host sgdisk + mkfs.vfat + mtools"** — install
  `gdisk`, `dosfstools`, and `mtools`.
* **"Cannot find: s-stalib.ali"** — the custom runtime has not been built;
  run `make all` or rebuild it explicitly (see above).
* A stale `qemu-system-riscv64` may hold `disk.img` open.  Kill it before
  rebuilding or rerunning:

  ```bash
  pkill -f "[q]emu-system-riscv64"
  ```

  (Use the bracket form so the `pkill` command itself does not match.)
