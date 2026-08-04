# akernel project state

Thin orientation only. Details live in topic docs; read the one matching
your task instead of everything.

- `docs/NEXT.md` — current work queue (read this first)
- `docs/IPC.md` — agreed IPC/namespace/spawn-v2 design
- `docs/ARCH_RISCV64.md` — boot, MMU/address spaces, trap/syscall path, devices
- `docs/KERNEL.md` — PMM, initrd, ELF, caps, tasks, scheduler, objects, processes
- `docs/USERSPACE.md` — syscall ABI, RTS scaffold, init, drivers, fuzzer, manifest

## Goal

Ada bare-metal microkernel for hobby OS. Initial target: RISC-V64 QEMU
`virt` under OpenSBI in S-mode. Long-term: multiple architectures/boards,
user-mode drivers, capability-based resource management, initrd-loaded
userspace, per-process namespaces (Plan 9 influence), custom Ada RTS.

## Workflow rules

- Git commit between each completed step. Do not batch multiple completed
  steps without committing.
- Keep docs current-state only; no changelog narrative in STATE/topic docs.

## Build/run

```sh
make all
make run        # qemu-system-riscv64 -machine virt -kernel bin/akernel.elf \
                #   -device loader,file=initrd/out/akernel-initrd.img,addr=0x84000000
make clean
make run QEMU_MEMORY=8G QEMU_SMP=4 INITRD_ADDR=0x84000000   # knobs
```

## Current successful boot output

```text
Hello world!
kernel address space online
memory manager online
ram MiB: 4096
dtb devices online
pmm selftest online
cap table online
objects selftest online
ipc online
bootinfo online
entering initrd init
init online from Ada
boot manifest visible
launching manifest programs
devmgr: spawned Drivers/Serial
console server online
devmgr: spawned Drivers/VirtioRng
devmgr: spawned Drivers/VirtioBlk
(virtio driver self-tests)
fileserver spawned
fileserver online
fs name table pushed
fuzz spawned
program spawned
partmgr gpt online
fat32 online
init resumed
fuzz online          (via console server endpoint stream)
spin online          (via console server)
timer interrupt online
... 167/167 directed PASS (console stream RPC, echo IPC rounds,
grants, memory objects, RTS heap, file protocol + volumes,
spawn-from-memory-object, notifications, block volume, cap_delete,
FAT32 reads + writes + delete/truncate/mkdir/rmdir/LFN through the
VFS, partition query + per-partition raw volumes, fs sync) ...
fuzz complete: calls=0x0000000000001000 unknowns=0x0000000000000155 failures=0x0000000000000000
fuzz exit test
```

Normal programs print through the console server (endpoint stream);
init and the kernel still use debug_putchar, as does the fuzzer's
random phase (printable garbage in the log is that fuzz traffic).

## Repository layout

```text
src/kernel/                     kernel-neutral code
src/arch/riscv64/               RISC-V64 arch code
src/board/qemu_virt_riscv64/    QEMU virt board/platform code
userspace/rts/akernel/          user-mode Ada syscall/RTS scaffold
userspace/init|serial|fuzz/     standalone Alire projects
userspace/virtio/               virtio lib crate (MMIO + virtqueues)
userspace/virtio_rng/           virtio-rng driver (pins the lib)
initrd/                         generated initrd root/output
tools/mkinitrd.py               wraps cpio in AKRD header
docs/                           this file + topic docs
Makefile                        top-level build/run
```

`akernel.gpr` vars: `AKERNEL_ARCH` (riscv64), `AKERNEL_BOARD`
(qemu_virt_riscv64).

## Important constants

```text
kernel link/load:       0x80200000
kernel VMA base:        0xFFFFFFFF80200000
physmap base:           0xFFFFFFC000000000
initrd load PA:         0x84000000
user stack top:         0x70000000
IPC buffer VA (design): 0x6FFF0000
bootinfo page VA:       0x6FFE0000
user VA range:          0x40000000..0x80000000
UART PA:                0x10000000
PLIC PA:                0x0c000000
PLIC UART source:       10
QEMU virt RAM base:     0x80000000
```

## Current limitations

- Preemptive scheduler (50 ms user-thread timeslice) with wakeup
  boost: a thread woken by IPC/notification re-enters at the FRONT
  of the ready queue (boost flag cleared on every block path), so
  rendezvous handoffs never wait behind a CPU hog; kernel itself
  serialized by a big kernel lock (SMP: all harts run user code in
  parallel, kernel execution single-file; shared ready queue + IPI
  wakeup); small fixed process/thread tables.
- Spawn ABI v2: images are `Boot_File_Object` caps (grant lists in
  spawner's IPC buffer, rights-subset enforced); init discovers its
  caps by name in the read-only bootinfo page. Boot byte API is
  cap-based; memory objects (alloc/map/unmap, borrowed mappings,
  refcounted PMM frames) exist but boot files are not memory objects
  yet.
- No IOMMU/DMA isolation; no full custom GNAT RTS (light runtime +
  stubs); initrd load address fixed.
- UART/PLIC bases and the UART IRQ source come from DTB discovery
  (board constants as fallback); the kernel keeps only its own
  polled console on that UART. All device runtime objects — the
  UART included — are enumerated by init's device manager from the
  DTB (exposed as the "dtb" boot file) and the System/Drivers
  database, with per-instance MMIO/IRQ caps minted via
  io_map/irq_create (device_resource authority). Drivers/Serial is
  an ordinary spawned driver (class 0: console endpoint Receive);
  virtio-mmio devices run as user-mode drivers (virtio-rng live;
  virtio-blk live with a block-backed BD0 raw volume). The block
  stack is driver -> partition -> filesystem: System/Partmgr
  probes GPT (MBR primary entries as fallback, slot 0 = whole
  disk without either) and serves block protocol with
  badge-selected partition offset translation, zero-copy cap
  forwarding, plus a part_query op (slot -> first LBA / size /
  populated count); init enumerates the slots and mounts each as
  a raw PDN volume on the VFS (Op_Add_Block with a cap_mint'd
  partN-badged cap). System/Fat32 serves
  partition 1 of the GPT disk as HD0/AKDISK (reads + writes:
  subdirectory traversal, LFN matching, file create (8.3 or
  LFN + numeric-tail alias), cluster chain extension with
  mirrored FAT + FSInfo updates, delete/truncate/mkdir/rmdir
  (Op 8..11), fixed dirent timestamps; no sparse writes), over
  an 8-slot write-through metadata sector cache (FAT/dir/
  FSInfo; file data bypasses) — Op_Sync = 12 is a write-through
  no-op passthrough today, flush hook for later. The
  file server is a VFS in front, forwarding verbatim with
  per-op buffer caps cap_delete'd at every layer.
- The PMM honors reserved ranges (initrd, DTB); mem_object_pa
  exposes memory-object frame PAs for DMA; spawned processes get
  4 user stack pages.
