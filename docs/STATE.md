# akernel project state

## Goal

Ada bare-metal microkernel for hobby OS. Initial target: RISC-V64 QEMU `virt` under OpenSBI in S-mode. Long-term: multiple architectures/boards, user-mode drivers, capability-based resource management, initrd-loaded userspace.

## Workflow rules

- Git commit between each completed step. Do not batch multiple completed steps without committing.

## Build/run

From repo root:

```sh
make all
make run
make clean
```

`make run` uses:

```sh
qemu-system-riscv64 \
  -machine virt \
  -smp 1 \
  -m 4G \
  -nographic \
  -kernel bin/akernel.elf \
  -device loader,file=initrd/out/akernel-initrd.img,addr=0x84000000
```

Override knobs:

```sh
make run QEMU_MEMORY=8G QEMU_SMP=4 INITRD_ADDR=0x84000000
```

## Current successful boot output

Important lines:

```text
Hello world!
memory manager online
ram MiB: 4096
pmm selftest online
cap table online
ipc online
scheduler online
entering initrd init
init online from Ada
boot manifest visible
launching manifest programs
serial spawned
serial driver online
init resumed
timer interrupt online
```

## Repository layout

```text
src/kernel/                     kernel-neutral code
src/arch/riscv64/               RISC-V64 arch code
src/board/qemu_virt_riscv64/    QEMU virt board/platform code
userspace/rts/akernel/          current user-mode Ada syscall/RTS scaffold
userspace/init/                 standalone user init Alire project
userspace/serial/               standalone user serial driver Alire project
initrd/                         generated initrd root/output
tools/mkinitrd.py               wraps cpio in AKRD header
Makefile                        top-level build/run
```

## Architecture/board split

`akernel.gpr` uses variables:

```gpr
AKERNEL_ARCH  default riscv64
AKERNEL_BOARD default qemu_virt_riscv64
```

Source dirs:

```text
src/kernel
src/arch/<arch>
src/board/<board>
config
```

## Boot/startup

RISC-V64 startup:

```text
src/arch/riscv64/startup.s
```

OpenSBI enters kernel in S-mode:

```text
a0 = hart id
a1 = DTB physical address
```

Only first arriving HART runs. Others park in `wfi`.

Kernel links at:

```text
0x80200000
```

OpenSBI firmware is at/near `0x80000000`, so do not link kernel there.

Startup sets:
- `gp`
- boot stack
- `stvec`
- `sscratch` to trap stack
- clears `.bss`
- saves `boot_hart_id`, `boot_dtb_pa`
- builds early Sv39 identity map
- enables MMU
- calls Ada binder `main`

Early Sv39 root currently maps:

```text
root[0] low MMIO 0x00000000..0x3fffffff, supervisor RWX
root[1] temporary broad user alias 0x40000000..0x7fffffff -> PA 0x80000000..0xbfffffff, U/R/W/X
root[2..5] RAM 0x80000000..0x17fffffff, supervisor RWX, up to 4GiB RAM
```

User address spaces do **not** copy root[1]. They copy supervisor mappings only.

## Trap/syscall path

Trap vector:

```text
src/arch/riscv64/startup.s:trap_vector
```

Trap handler:

```text
src/arch/riscv64/arch-traps.adb
```

Trap entry uses `sscratch` to switch from user stack to kernel trap stack. Init and spawned user threads own per-thread kernel stack frames; scheduler restore writes `sscratch` from current thread before returning to user. It passes trap-frame pointer to Ada handler. `Arch.Context` owns RISC-V trap-frame layout and saved `sepc`; `Kernel.Tasks` stores opaque arch thread context and calls arch context save/restore wrappers.

Syscall ABI:

```text
a7 = syscall number
a0..a4 = args
a0 = return/status
```

Current syscalls:

```text
0 yield
1 debug_putchar(a0 = char)
2 map_mmio(a0 = cap, a1 = va, a2 = offset, a3 = length, a4 = flags)
3 irq_wait(a0 = irq_cap)
4 irq_ack(a0 = irq_cap)
6 boot_file_size(a0 = file_id) -> byte length, U64'Last on failure
7 boot_read_byte(a0 = file_id, a1 = offset) -> byte 0..255, 256 EOF, U64'Last failure
8 spawn_boot_path(a0 = manifest path offset, a1 = path length, a2 = grant_mask) -> a0 status, a1 process cap on success
9 exit() -> does not return on success
10 reap_process(a0 = process_cap) -> 0 ok/reaped, 1 invalid, 2 not exited
```

Return convention for resource/lifecycle syscalls:

```text
0 = ok
1 = invalid/denied
2 = would block/no pending IRQ (older/nonblocking paths only)
```

Spawn status for syscall 8:

```text
0 = ok, a1 contains process cap
1 = invalid program/path
2 = no process slot
3 = load failed / program not found / bad image
4 = cap grant failed
5 = scheduler failed
6 = invalid parent
```

`map_mmio` checks:
- current thread exists
- current process owns fixed self address-space cap handle 255 (`Address_Space_Object`) with `Map`, object root matching current process root
- MMIO cap valid
- cap kind `MMIO_Object`
- cap has `Map`
- requested R/W flags don't exceed cap rights
- offset/length within object
- page alignment
- VA in user range `0x40000000..0x80000000`

Then maps pages into current process address-space root as `User_RW`.

## Memory / MMU

Physical allocator:

```text
src/kernel/kernel-physical_memory.ads/.adb
```

Current allocator: bump frame allocator plus singly-linked free list stored in freed frames. Initialized from linker `_end` to RAM end from DTB. `Allocate_Frame` reuses free-list frames before bumping. `Deallocate_Frame` validates managed/aligned/currently allocated frames, rejects double-free entries already in free list, shrinks bump pointer for most-recent frame, otherwise pushes frame onto free list. `Free_Bytes` includes bump space plus free-list frames. `Free_Frame_Count` exposes frame count diagnostics. Mark/rewind remains for early code but process spawn now uses explicit cleanup instead of relying on rewind. Boot-time PMM selftest checks free-list reuse, free-count restore, and double-free rejection, then prints `pmm selftest online`.

Device tree parser:

```text
src/kernel/kernel-device_tree.ads/.adb
```

Generic FDT parser, not arch-specific. Board exposes only boot DTB pointer:

```text
src/board/qemu_virt_riscv64/board-device_tree.ads/.adb
```

MMU:

```text
src/arch/riscv64/arch-mmu.ads/.adb
```

Supports:
- `New_Address_Space`
- `New_User_Address_Space`
- `Map_Page`
- `Activate`

User stack top:

```text
0x70000000
```

User VA policy range currently:

```text
0x40000000..0x80000000
```

## Initrd

Separate initrd image loaded by QEMU loader device, not embedded in kernel ELF.

Fixed load PA for now:

```text
0x84000000
```

Image format:

```text
AKRD header:
  magic "AKRD"
  u32 version = 1
  u64 cpio_size
  u64 reserved
then cpio newc payload
```

Tool:

```text
tools/mkinitrd.py
```

Kernel parser:

```text
src/kernel/kernel-initrd.ads/.adb
```

Current initrd contents use Amiga-ish naming, not POSIX-ish:

```text
System/Init
System/Manifest
Drivers/Serial
```

`System/Manifest` current text format:

```text
program 1 Drivers/Serial uart_mmio uart_irq
```

Kernel boots `System/Init`. Init can query boot files through syscalls. Current boot file id 1 is `System/Manifest`; init verifies it is visible. Init parses `System/Manifest`, builds grant masks, then calls `spawn_boot_path(path_offset, path_length, grant_mask)` for program entries. `Kernel.Processes` owns small spawned-task table and asks `Kernel.Program_Loader` to resolve that path slice from manifest to initrd image bytes. Process code loads it into its own user address space, applies caller-requested grants from `grant_mask` after checking parent owns matching resource caps, queues it in scheduler, and returns status plus parent process cap handle. Init remains alive and resumes after yielding. Launch/resource policy now lives mostly in init; kernel still has initrd boot-loader backend.

## ELF loader

```text
src/kernel/kernel-elf.ads/.adb
```

Current real loader:

```ada
Load_Into_Address_Space
```

Behavior:
- validates ELF64 little-endian RISC-V
- iterates `PT_LOAD`
- allocates frames
- copies segment bytes
- zeroes bss/page slack
- maps pages into target root with user permissions from ELF flags
- returns entry point

There is also old `Load_User_Alias`; avoid using it except fallback/debug.

## Userspace

Standalone Alire projects:

```text
userspace/init/alire.toml
userspace/init/init.gpr
userspace/init/init.adb
userspace/serial/alire.toml
userspace/serial/serial.gpr
userspace/serial/serial.adb
```

Build to:

```text
bin/userspace/init.elf
bin/userspace/serial.elf
```

Userspace RTS/syscall scaffold:

```text
userspace/rts/akernel/
  akernel_user.ads
  akernel_user-syscalls.ads
  akernel_user-syscalls.adb
  syscalls-riscv64.s
  start-riscv64.s
  runtime_stubs-riscv64.s
  linker-riscv64.ld
```

User init currently launches serial driver:

```ada
Debug_Put_Line ("init online from Ada");
Boot_File_Size (Boot_Manifest_File);
init-fatal/yield loop if unavailable; not kernel panic
prints "boot manifest visible" when readable
Debug_Put_Line ("launching manifest programs");
Parse_Manifest;
for each `program <id> <path> [grants...]` line:
  build grant mask from tokens
  Spawn_Boot_Path (path_offset, path_length, grant_mask, process_cap)
prints "serial spawned" for id 1 on nonzero process cap handle
Yield;
prints "init resumed"
```

User serial driver currently:

```ada
Map_MMIO cap 1 at 0x50000000
print "serial driver online" via mapped UART MMIO
loop IRQ_Wait cap 2; drain UART RX; IRQ_Ack cap 2
```

RTS is not full custom GNAT RTS yet. It uses `light-rv64imafdc` plus syscall wrappers/stubs.

## Capabilities/tasks/IPC/scheduler

Capabilities:

```text
src/kernel/kernel-capabilities.ads/.adb
```

Flat per-task cap table, 256 entries. Handle 0 invalid. Entries carry kind, object address, rights, and badge.

Tasks:

```text
src/kernel/kernel-tasks.ads/.adb
```

Process/thread split started in `Kernel.Tasks`:
- `Process_Control_Block` owns process id, address-space root, cap table, lifecycle state
- fixed cap handle 255 is reserved as process self `Address_Space_Object` cap; VM syscalls require it for address-space authority
- `Thread_Control_Block` owns thread id, scheduling state, saved user context snapshot, ready-queue membership, owning process pointer
- scheduler/IPC/IRQ/trap/process APIs use explicit `Thread_Access`/`Thread_Control_Block` names
- compatibility `Task_*` aliases/helper removed
- bootstrap/static tasks now have explicit process + thread objects
- spawn path creates separate process slot plus main thread slot and marks process alive before publishing cap
- failed spawn after process/thread initialization discards slot, marks process dead/thread dead, closes published cap if needed, and rewinds PMM mark
- syscall 9 `exit` runs cap/object cleanup hooks for current process caps, marks current thread dead and owning process dead, then schedules next ready thread or idles
- syscall 10 `reap_process` lets parent holding a managed `Process_Object` cap close that cap, run cap/object cleanup hooks again, destroy child user address space, free mapped user frames/page tables through PMM, reset child cap table, and free dead spawned slot for reuse; live child returns status 2

Boot files:

```text
src/kernel/kernel-boot_files.ads/.adb
```

Current user-visible boot file API:
- file id 1 = `System/Manifest`
- `boot_file_size(file_id)` returns byte length or `U64'Last`
- `boot_read_byte(file_id, offset)` returns byte, 256 EOF, or `U64'Last`
- byte-at-a-time API avoids user pointer copying for now

Program loader:

```text
src/kernel/kernel-program_loader.ads/.adb
```

Current backend:
- `Find_By_Manifest_Path` resolves path slice from `System/Manifest` to initrd image bytes
- current line format: `program <id> <path> [grants...]`
- executable bytes come from initrd for now
- later backend can use VFS/package server without changing process creation path

Processes:

```text
src/kernel/kernel-processes.ads/.adb
```

`Kernel.Processes.Spawn_Boot_Path` currently:
- accepts manifest path offset/length and explicit grant mask from caller
- requests executable image from `Kernel.Program_Loader.Find_By_Manifest_Path`
- marks PMM bump pointer before process allocations
- creates address space + stack
- loads ELF
- creates process plus main thread and initializes thread context
- grants caller-requested caps into child process cap table only if parent has matching resource caps
- inserts `Process_Object` cap into parent
- queues main thread in scheduler only after all prior steps succeed
- rewinds PMM mark on failure before child becomes visible

Process/thread split decision:
- kernel-visible threads are scheduled by kernel, with optional user-level fibers later
- process owns address space, cap table, resource/lifecycle state
- thread owns opaque arch context, scheduler state, and per-thread kernel stack top
- spawn creates process plus main kernel thread, returning process cap (main thread cap can be added later)
- kernel-visible threads chosen because blocking IPC/IRQ waits should block one thread, not whole address space/runtime
- user-level threading can still be M:N/fibers later above kernel threads

Scheduler:

```text
src/kernel/kernel-scheduler.ads/.adb
```

Simple fixed ready queue and current thread pointer. Yield/IRQ-block paths share arch trap helpers that save current trap-frame context, schedule, restore next context, and switch `satp`. Scheduler tracks queue membership to avoid duplicate ready-queue entries and ignores wakeups for already-ready/running threads. Dead threads are rejected on push and skipped on pop. Scheduler also has `Remove_Thread` to purge a thread from ready queue/current pointer during teardown. `exit` marks current thread dead, clears current, marks owning process dead, then schedules another ready thread or idles with `wfi`. If current thread blocks and ready queue is empty, scheduler leaves no current thread instead of reviving blocked thread; trap helper idles with `wfi` until a thread wakes. Still rough and cooperative-only.

IPC:

```text
src/kernel/kernel-ipc.ads/.adb
```

Endpoint/message scaffold exists. One waiting sender/receiver, badges, caps reserved but no cap transfer yet. Send/receive drop dead waiting sender/receiver slots before matching, avoiding stale dead-thread endpoint blockage. Process exit/reap walks owned caps and applies endpoint cleanup hooks to clear matching waiting sender/receiver slots before cap table reset.

## Resource objects

```text
src/kernel/kernel-objects.ads
src/kernel/kernel-interrupts.ads/.adb
```

Currently contains:

```ada
MMIO_Region:
  Physical_Base
  Length

IRQ_Line:
  Source
  Pending
  In_Flight
```

Kernel gives init cap handle 1 for UART MMIO:

```text
PA 0x10000000
Length 4096
Rights Map|Read|Write
```

Init maps it at VA:

```text
0x50000000
```

Kernel gives init cap handle 2 for UART IRQ:

```text
Source 10
Rights Wait|Ack
```

`Board.Interrupts.Handle_External_Interrupt` claims PLIC source and calls `Kernel.Interrupts.Deliver`. If source is registered, kernel marks IRQ pending/in-flight and does not complete PLIC until user calls `irq_ack`. If source is unregistered, board code logs and completes it.

IRQ state rules currently:
- one waiter per IRQ line
- dead waiter is cleared before installing/checking another waiter
- process exit/reap walks owned caps and applies IRQ cleanup hooks to clear matching waiter slots
- `irq_wait` returns immediately only when `Pending and In_Flight`
- if no IRQ pending, waiter is registered and task blocks
- second different waiter gets `Already_Waiting` internally and syscall returns invalid/denied
- delivery wakes waiter once and clears waiter slot
- `irq_ack` clears `Pending`, `In_Flight`, and waiter; no in-flight IRQ returns would-block

## UART/PLIC/timer

UART board driver:

```text
src/board/qemu_virt_riscv64/board-uart.ads/.adb
```

PLIC:

```text
src/board/qemu_virt_riscv64/board-plic.ads/.adb
src/board/qemu_virt_riscv64/board-interrupts.ads/.adb
```

Timer via SBI:

```text
src/arch/riscv64/arch-sbi.ads/.adb
src/arch/riscv64/sbi_asm.s
```

Timer interrupt works and prints first message/dots.

## Important constants

```text
kernel link/load:       0x80200000
initrd load PA:         0x84000000
user stack top:         0x70000000
user VA range:          0x40000000..0x80000000
UART PA:                0x10000000
PLIC PA:                0x0c000000
PLIC UART source:       10
QEMU virt RAM base:     0x80000000
```

## Temporary limitations / hacks

- PMM has a free list and can reclaim frames, but no sophisticated coalescing/accounting beyond page frames.
- Kernel supervisor mappings are broad identity mappings copied into user roots.
- No high-half kernel yet.
- Context switch works only as rough cooperative saved per-thread trap-frame switching.
- Process/thread split is partial; exited process cleanup still requires parent `reap_process`.
- Small fixed spawned process/thread tables only; failed unpublished spawns discard slot, exited published slots can be reused after `reap_process`, and mapped user frames/page tables are reclaimed by PMM free list.
- Initrd load address fixed at `0x84000000` via QEMU loader device.
- No DTB-based device capability enumeration yet.
- IRQ caps/syscalls exist; single-waiter state transitions hardened, but need more testing.
- No IPC syscalls yet.
- No cap transfer between processes yet.
- No IOMMU/DMA isolation.

## Recommended next steps

1. Move launch policy toward init/program-manager:
   - init now treats unreadable `System/Manifest` as fatal and enters yield loop; this is not kernel panic/shutdown
   - init parses `System/Manifest` and decides program ids/grants
   - syscall 8 spawns by boot manifest path slice; legacy id-based spawn syscall was removed
   - kernel should expose bootinfo/resource caps to init
   - future spawn should accept executable/source cap plus explicit grant/cap list, not manifest path slice
   - keep initrd as one program-loader backend; later add VFS/package backend
   - process/thread split started; explicit thread names now used outside `Kernel.Tasks`
   - compatibility `Task_*` aliases/helper removed; bootstrap code uses explicit process creation
   - address-space self cap exists and `map_mmio` requires it
   - add main thread caps only if needed
   - user-visible spawn status exists for syscall 8

2. Harden scheduler/context switching:
   - ready-queue duplicate protection exists
   - trap context save/schedule/restore helper exists for yield and IRQ wait
   - blocked-current/empty-ready idle path now uses `wfi` instead of reviving blocked task
   - IRQ single-waiter state transitions hardened
   - failed spawn rewinds PMM before child becomes visible
   - process/thread split started in data model and spawn path
   - process lifecycle states exist; failed unpublished spawn cleanup exists
   - exit syscall exists and marks current thread/process dead
   - reap syscall closes parent process cap, destroys child address space, frees frames/page tables, clears child cap table, and frees dead spawned slot for reuse
   - PMM boot selftest checks reuse/free-count/double-free rejection
   - endpoint/IRQ cap cleanup hooks run on exit/reap
   - add richer object cleanup/refcounts as object model grows
   - continue hardening process/thread lifecycle after successful spawn/exit
   - per-thread kernel stacks and opaque arch context exist for init/spawned user threads
   - raw trap-frame layout is hidden in `Arch.Context`

3. Improve blocking IRQ waits:
   - single-waiter IRQ wait/wakeup implemented
   - add tests/stress for repeated RX, lost wakeups, and waiter contention
   - move IRQ notification toward IPC/event objects

3. Add IPC syscalls:
   - send/receive endpoint caps
   - use badges
   - later cap transfer

4. Add DTB-based device enumeration:
   - parse `virtio,mmio`, `ns16550a`, interrupt props
   - create resource objects/caps dynamically
   - pass bootinfo/resource caps to init

5. Improve VM isolation:
   - proper kernel virtual map instead of broad identity
   - per-thread kernel stacks/opaque arch context exist
   - scheduler context switch switches `satp`
