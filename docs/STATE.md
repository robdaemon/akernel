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
kernel address space online
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
userspace/fuzz/                 standalone syscall fuzzer Alire project
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

Early Sv39 root currently maps (boot transition only, abandoned after `Arch.MMU.Enter_Kernel_Address_Space`):

```text
root[2..5]    RAM 0x80000000..0x17fffffff identity, supervisor RWX (satp-switch instructions)
root[0x100]   physmap PA 0x00000000.. (MMIO) at PHYSMAP_BASE, supervisor RW
root[0x102..5] physmap RAM 0x80000000.. at PHYSMAP_BASE + PA, supervisor RW
root[0x1FE]   kernel VMA gigapage -> PA 0x80000000, supervisor RWX (temp)
```

## Kernel address space

The kernel is linked at `Kernel_Virt_Base = 0xFFFFFFFF80200000` (VMA = PA + `0xFFFFFFFF00000000`; the offset is a whole gigapage so the kernel VMA gigapage maps the image 1:1, and the base stays inside the medlow top-2GiB window so the precompiled light runtime still links). All physical memory — PMM free-list links, page tables, MMIO, initrd, DTB, ELF staging — is accessed through the physmap at `Physmap_Base = 0xFFFFFFC000000000` + PA (`Arch.Phys_To_Virt`).

Shortly after PMM init the kernel builds a dedicated address space (`Arch.MMU.Enter_Kernel_Address_Space`) and switches satp to it, publishing its satp value to `kernel_satp_slot` before activation. It contains no identity mappings; permissions are least-privilege (W^X):

- kernel image `.text`+`.trampoline`+`.rodata` at kernel VAs (`__rx_start`..`__rx_end` from linker script): RX 4 KiB pages
- `.data`/`.bss`/stacks at kernel VAs: RW 4 KiB pages
- physmap gigapages (MMIO PA 0 + all RAM) at `Physmap_Base`: RW gigapage leaves
- no user alias gigapage; the old `user_init` fallback path is removed (initrd init is mandatory)

Kernel root frames are PMM-owned and never freed. `Arch.MMU.Kernel_Root` reports the dedicated root after the switch, the early root before it.

User address spaces map only the trap trampoline page (at its kernel VMA, supervisor RX, global), their own user pages, and their threads' kernel trap stacks (at their physmap VAs, supervisor RW, global). They no longer copy any early-root gigapages.

## Trap/syscall path

Trap vector:

```text
src/arch/riscv64/startup.s:trap_vector
```

Trap vector lives in the page-aligned `.trampoline` linker section (single page, exports `trampoline_start`/`trampoline_end`). The page is mapped at its kernel VMA in every user address space so satp switching works, xv6-style. The kernel satp value is published in `kernel_satp_slot` inside the trampoline page.

Trampoline entry (`sscratch` always holds the current thread kernel stack top as a physmap VA — or a kernel VMA for the boot trap stack — in both S-mode and U-mode; every frame address is therefore valid in both the owning user root and the kernel address space, so no pointer conversion is needed around satp switches):
- switches `sp` to the current thread kernel stack (mapped at its physmap VA, supervisor RW, global, in the owning user root)
- builds a 272-byte trap frame: x1..x31, `sepc` (offset 248, frame-authoritative), `satp` (offset 256)
- loads `kernel_satp_slot`, switches satp to the kernel root, calls the Ada handler

Trampoline exit locates the frame via `sscratch` (so a scheduled-away trap returns through the newly current thread's own kernel stack frame), installs the frame's satp slot, restores registers, and `sret`s. `sepc` is advanced in the frame (`trap_frame_advance_sepc`), never in the CSR. Scheduler restore writes the saved context into the newly current thread's kernel stack frame (`trap_frame_for_stack`) and updates `sscratch`; `Arch.MMU.Activate` is no longer called on the switch path. Kernel-mode traps (idle `wfi` wakeups, faults) take the same path and are no-ops satp-wise.

`riscv_enter_user_mode` also lives in the trampoline page; it takes entry, stack, and the target root's satp value (`Arch.MMU.Satp_Value`), switches satp, then `sret`s.

Trap handler (runs on the kernel root after trampoline satp switch):

```text
src/arch/riscv64/arch-traps.adb
```

Trap entry uses `sscratch` to switch from user stack to the per-thread kernel trap stack, builds the frame on it, then switches satp to the kernel root via the trampoline. Init and spawned user threads own per-thread kernel stack frames; scheduler restore writes `sscratch` from the current thread stack top and restores context into that thread's kernel stack frame before returning to user. It passes trap-frame pointer to Ada handler. `Arch.Context` owns RISC-V trap-frame layout and saved `sepc`; `Kernel.Tasks` stores opaque arch thread context and calls arch context save/restore wrappers.

Syscall ABI:

```text
a7 = syscall number
a0..a4 = args
a0 = return/status
```

Dispatcher invariant: handlers that `Handle_Syscall` returns from immediately
(currently `irq_wait`, `exit`) must `Advance_SEPC` themselves on every
non-scheduling exit path; all other handlers fall through to the dispatcher's
single advance.  Violating this re-executes the `ecall` forever (found by the
syscall fuzzer, `irq_wait` invalid-cap case).

Current syscalls:

```text
0 yield
1 debug_putchar(a0 = char)
2 map_mmio(a0 = address_space_cap, a1 = mmio_cap, a2 = va, a3 = offset, a4 = length, a5 = flags)
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

Trap syscall handlers validate user-supplied capability handle integers before converting to `Kernel.Capabilities.Handle`; out-of-range handles return invalid/denied instead of raising kernel constraint errors.

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
- caller supplies address-space cap; cap kind is `Address_Space_Object`, has `Map`, and object root matches current process root
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
userspace/fuzz/alire.toml
userspace/fuzz/fuzz.gpr
userspace/fuzz/fuzz.adb
userspace/fuzz/fuzz-riscv64.s
```

Build to:

```text
bin/userspace/init.elf
bin/userspace/serial.elf
bin/userspace/fuzz.elf
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
- fixed cap handle 255 is reserved as process self `Address_Space_Object` cap; VM syscalls take explicit address-space cap arguments for authority
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
- spawn creates process plus main kernel thread, returning process cap (main thread cap deliberately not returned: no syscall targets a specific thread yet; `exit` acts on current thread, `reap_process` uses process cap; add thread caps only when a thread-targeting syscall appears)
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

Endpoint/message scaffold exists. One waiting sender/receiver, badges, caps reserved but no cap transfer yet. Send/receive drop dead waiting sender/receiver slots before matching, avoiding stale dead-thread endpoint blockage. `Kernel.Objects.Cleanup_Thread_Cap_Object` dispatches endpoint cleanup for process exit/reap and thread cap close, clearing matching waiting sender/receiver slots before cap table reset. Public process-only cap close was removed; thread-affine cap close must go through `Kernel.Tasks.Close_Cap (Thread_Access, ...)` so cleanup owner is known.

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
- process exit/reap walks owned caps through `Kernel.Objects.Cleanup_Thread_Cap_Object`; IRQ cleanup clears matching waiter slots
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
- Kernel runs at high-half VAs (`0xFFFFFFFF80200000+`) on a dedicated least-privilege address space (W^X split, physmap, no identity mappings); early broad RWX root abandoned after boot.
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
   - address-space self cap exists and `map_mmio` takes it explicitly
   - decision: no main thread cap returned for now (no thread-targeting syscall exists; add when one appears)
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
   - endpoint/IRQ cap cleanup hooks run through generic object cleanup dispatcher on exit/reap and thread cap close
   - public process-only cap close removed to avoid bypassing thread-affine cleanup
   - no object refcounts yet by decision: shared resource objects (`MMIO_Region`, `IRQ_Line`, endpoints) are kernel-owned statics that are never freed, so cleanup hooks on cap close/exit/reap suffice; add refcounts only when dynamically-owned shared objects appear
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

5. Improve VM isolation further:
   - trap trampoline + satp switch done; user roots carry no kernel/device mappings beyond trampoline page and own kernel stacks
   - high-half kernel VAs done: kernel linked at `0xFFFFFFFF80200000`, physmap at `0xFFFFFFC000000000`, dedicated root carries no identity mappings
   - per-thread kernel stacks/opaque arch context exist
   - per-thread kernel stacks/opaque arch context exist
   - scheduler context switch switches `satp`
