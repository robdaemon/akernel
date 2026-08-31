# Kernel subsystems

## Physical memory manager

`src/kernel/kernel-physical_memory.ads/.adb`

Bump frame allocator plus singly-linked free list stored in freed frames.
Initialized from linker `_end` to RAM end (from DTB). `Allocate_Frame`
reuses free-list frames before bumping. `Deallocate_Frame` validates
managed/aligned/allocated frames, rejects double frees, shrinks bump
pointer for most-recent frame, else pushes onto free list. `Free_Bytes`/
`Free_Frame_Count` diagnostics. Mark/rewind kept for early code; process
spawn uses explicit cleanup plus mark/rewind on failure. Boot selftest:
free-list reuse, free-count restore, double-free rejection, interleaved
32-frame stress (allocate batch, free every other, reallocate holes,
free all; count tracks exactly each phase). Prints `pmm selftest online`.

## Initrd

QEMU loader device, fixed PA `0x84000000`. Format: `AKRD` header (magic,
u32 version=1, u64 cpio_size, u64 reserved) + cpio newc payload. Tool:
`tools/mkinitrd.py`. Parser: `src/kernel/kernel-initrd.*`.

Contents (Amiga-ish naming): `System/Init`, `System/Manifest`,
`Drivers/Serial`, `Tests/Fuzz`.

## ELF loader

`src/kernel/kernel-elf.*`. `Load_Into_Address_Space`: validates ELF64
LE RISC-V, iterates `PT_LOAD`, allocates frames, copies segments, zeroes
bss/slack, maps with user permissions from ELF flags, returns entry.
Old `Load_User_Alias` is fallback/debug only; avoid.

## Capabilities

`src/kernel/kernel-capabilities.*`. Flat per-process table, 256 entries,
handle 0 invalid. Entries: kind, object address, rights, badge.
`Insert`, `Insert_At`, `Lookup`, `Duplicate` (rights-reduced copy with
new badge — basis for namespace grants/minting), `Close`, `Reset`.
Rights record: Read/Write/Execute/Map/Send/Receive/Wait/Ack/Transfer/
Manage. `Object_Kind` has placeholders incl. `Endpoint_Object`,
`DMA_Object`, `Frame_Object`.

Reserved handles: 254 reply cap, 255 process self `Address_Space_Object`
cap (both per docs/IPC.md; 255 implemented, 254 pending IPC work).

## Tasks / scheduler

`src/kernel/kernel-tasks.*`, `src/kernel/kernel-scheduler.*`

- `Process_Control_Block`: process id, address-space root, cap table,
  lifecycle state.
- `Thread_Control_Block`: thread id, scheduling state, opaque arch
  context, ready-queue membership, owning process pointer, per-thread
  kernel stack top.
- Bootstrap tasks have explicit process+thread objects. Spawn creates
  process slot + main thread slot, marks alive before publishing cap.
- No main thread cap returned from spawn (no thread-targeting syscall
  exists; add when one appears).
- Per-thread IPC buffer page: fixed user VA `0x6FFF0000`
  (`Kernel.Tasks.IPC_Buffer_VA`), kernel-allocated + zeroed at spawn
  (init thread in akernel.adb, children in `Spawn_Image`), mapped
  User_RW, freed by user-address-space teardown. PA stored in TCB
  (`Set_IPC_Buffer`/`IPC_Buffer_PA`); kernel access via physmap. One
  buffer per address space while processes are single-threaded.
- Scheduler: fixed ready queue + current pointer; duplicate-membership
  protection; dead threads rejected on push, skipped on pop;
  `Remove_Thread` for teardown. Preemptive for user threads: 100 ms
  timer tick saves the interrupted frame and reschedules (only when
  the trap came from U-mode; kernel threads/idle wfi stay cooperative,
  syscall handlers run with interrupts off so the kernel is never
  preempted). Blocked-current + empty-ready idles with `wfi` until
  wakeup. Single hart; SMP (per-hart queues/locks, IPIs) deferred.

## Objects / interrupts

`src/kernel/kernel-objects.*`, `src/kernel/kernel-interrupts.*`

Objects: `MMIO_Region` (Physical_Base, Length), `IRQ_Line` (Source,
Pending, In_Flight, Waiter). Kernel-owned pinned statics.

Refcounting: dynamically-owned shared objects embed
`Kernel.Objects.Object_Header` (first component); `Pinned_Refcount`
sentinel = never destroyed. Kind-owning package implements
Retain/Release (endpoints: `Kernel.IPC`); `Kernel.Objects.Retain_Cap`
dispatches by kind and runs from the `Kernel.Tasks` cap-insert
wrappers (choke point for all inserts). MMIO/IRQ/address-space/
process/thread/kernel kinds are pinned-by-kind (no header, no release).
`Cleanup_Thread_Cap_Object` is the decrement-and-maybe-destroy
dispatcher: kind-specific waiter cleanup, then one release; endpoint
finalizer clears pending message and both waiter slots (dynamic
endpoint storage reclamation arrives with `ep_create`). Boot selftest
(dynamic retain/release cycle + pinned no-release) prints
`objects selftest online`. Cap close on exit/reap closes every cap so
refcounted objects release exactly once (cleanup runs at both exit
and reap).

Endpoint/IRQ waiter cleanup hooks stay kind-local.

Init gets cap 1 = UART MMIO (PA 0x10000000, 4096, Map|Read|Write),
cap 2 = UART IRQ (source 10, Wait|Ack).

IRQ rules: one waiter per line; dead waiter cleared first; `irq_wait`
returns immediately only when `Pending and In_Flight`; delivery wakes
waiter once and clears slot; second different waiter -> invalid/denied;
`irq_ack` clears Pending/In_Flight/waiter; no in-flight -> would-block.
`Board.Interrupts.Handle_External_Interrupt` claims PLIC source,
`Kernel.Interrupts.Deliver`; unregistered sources logged + completed.

## IPC

`src/kernel/kernel-ipc.*`. Synchronous rendezvous (docs/IPC.md).
96-byte messages live in per-thread IPC buffer pages; transfer is one
copy sender buffer -> receiver buffer via physmap overlays
(`Buffer_Of`). Callers block in a per-endpoint FIFO queue (TCB
`Queue_Next` link); receiver dequeues head, transfers, mints one-shot
reply cap at handle 254 (`Reply_Object` pointing at caller TCB);
caller stays blocked (`Awaiting_Reply` flag) until reply. Replies
carry label+words+caps (m75: `Reply` runs the same `Transfer_Message`
as the send direction; a transfer failure still wakes the caller with
2). Caller badge recorded in TCB at call time.

Cap transfer: up to 4 buffer cap slots (0 = none); each must be valid
with Transfer right (and not `Reply_Object`, m75 — a rollback close
would wrongly fire `Fail_Reply_Target`); duplicated full-rights into
receiver table; receiver buffer slots rewritten to new handles;
rollback closes partial inserts (no partial delivery).

Wake-with-status: waker writes result code into blocked thread's saved
a0 (`Kernel.Tasks.Set_Saved_Result` -> `Arch.Context.Set_Saved_Result`,
frame word 9) then `Scheduler.Wake`. Userspace codes: 0 ok, 1 invalid,
2 transfer failed, 3 endpoint gone, 4 reply gone.

Reply cap lifecycle: minted by `Mint_Reply_Cap` with the caller's
thread-slot generation stamped in the badge (m75 — the counter lives
outside the TCB in Kernel.Processes and bumps per slot reuse, same
as process `Slot_Generation`); `Reply` and `Fail_Reply_Target` (which
now takes the badge) refuse a stale cap, so a reply cap left dangling
by a dead caller can never cross-deliver to the slot's new owner
(TCB-address ABA). Consumed by `Reply` via `Tasks.Forget_Cap` (raw
close, no hooks); failed via dispatcher `Reply_Object` case ->
`Fail_Reply_Target` on server exit/reap or cap_delete.
Endpoint finalizer fails all queued callers + waiting receiver with
endpoint-gone.

Endpoints: PMM-backed slab (grows per frame, free-list reuse, frames
never returned). Refcount = referencing caps; fresh endpoint 0, first
insert retains; `Discard` for create-then-fail. `ep_create` (11),
`call` (12), `recv` (13), `reply` (14). Boot selftest covers slab
growth/reuse and pinned no-release; blocking paths and end-to-end
echo are exercised by the userspace fuzzer (directed, non-blocking
cases so far).

## Processes / spawn / boot files

`src/kernel/kernel-processes.*`, `kernel-boot_files.*`,
`kernel-bootinfo.*`

`Spawn_Boot_Image` (syscall 8): parent's `Boot_File_Object` image cap
(Read + Execute) + grant count -> PMM mark
-> address space + stack -> ELF load -> process + main thread + context
-> `Grant_List_Caps` mints the parent's grant list (in the parent's IPC
buffer at offset 128, up to 32 entries of handle/rights-mask/badge)
into the child at handles 1..N; each entry must be open in the parent,
not a reply cap, mask within `Valid_Rights_Mask`, rights a subset of
the parent entry's (monotonically decreasing; mask encoding via
`Kernel.Capabilities.To_Rights`/`To_Mask`) -> `Process_Object` cap into
parent -> queue thread last; failure paths discard the slot (caps
closed through the dispatcher once the thread exists, so partial
grants release refcounts).

Spawn status: 0 ok (a1 = process cap), 1 invalid program/image cap,
2 no slot, 3 load failed, 4 cap grant failed, 5 scheduler failed,
6 invalid parent.

`exit` (syscall 9): cap/object cleanup hooks for current process caps,
mark thread+process dead, schedule next or idle.

`reap_process` (syscall 10): parent holding managed `Process_Object` cap
closes it, reruns cleanup hooks, destroys child user address space,
frees frames/page tables, resets child cap table, frees slot. Live child
-> status 2. Statuses: 0 ok, 1 invalid, 2 not exited.

Boot files: `Kernel.Boot_Files.Enumerate` walks the initrd at boot
(`Kernel.Initrd.Next` iteration) into a static table of pinned
`Boot_File_Object`s (physmap base + length, one per non-empty file).
Init gets one cap per file at handles 3..N (Read + Execute +
Transfer). `boot_file_size`/`boot_read_byte` are cap-based (a0 = boot
file cap with Read); transitional, retired once memory-object
mapping lets init map files directly.

Bootinfo page (`Kernel.Bootinfo`): read-only page at `0x6FFE0000` in
init's address space; kernel writes (handle, kind, rights mask, name)
entries via the physmap before init enters user mode, covering the
device caps and every boot file cap.

Spawn image backend: initrd `Boot_File_Object` only. Later:
`Memory_Object` image caps (file server stages the ELF) make the
backend irrelevant to spawn.

## Lifecycle/cleanup decisions

- Object refcounts exist for refcounted kinds (endpoints first);
  memory objects join when implemented.
- No main thread cap from spawn until a thread-targeting syscall exists.
- Spawn authority is a general user capability, not init-privileged.
