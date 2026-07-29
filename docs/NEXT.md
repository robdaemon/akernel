# Next step

Implement IPC per the agreed design in `docs/IPC.md` (read it first).
Design decisions locked: sync rendezvous, IPC buffer canonical ABI,
call/recv/reply trio with reply cap at handle 254, cap transfer in
messages, dynamic endpoints + object refcounting, namespace grant lists
at spawn, init as fatal-fault domain with authority concentrated in
kernel cap tables.

## Milestone order

1. ~~Object refcounting infra~~ — done: `Object_Header` +
   `Pinned_Refcount` in `Kernel.Objects`, endpoint `Retain`/`Release`,
   `Retain_Cap` in cap-insert wrappers, dispatcher releases once
   (caps closed at exit/reap cleanup).
2. ~~Dynamic endpoints~~ — done: `ep_create` (syscall 11) +
   RTS wrapper; PMM-backed slab pool (grows per frame, RAM-limited,
   free-list reuse, frames never returned); finalizer wakes waiters
   and frees slot on last release.
3. ~~Per-thread IPC buffer page~~ — done: VA `0x6FFF0000`, allocated
   + zeroed + mapped at spawn (init + children), PA in TCB, kernel
   access via physmap; freed by AS teardown. One buffer per AS while
   single-threaded.
4. ~~`call`/`recv`/`reply`~~ — done (4b): FIFO blocked-caller queue
   per endpoint (not single-waiter), rendezvous transfer buffer->
   buffer, badge stamping, cap transfer with rollback, reply cap at
   254 with full lifecycle (consumed/failed/overwrite/endpoint-gone),
   wake-with-status via saved-context a0.
5a. ~~Preemption~~ — done: 100 ms timer tick preempts running user
    threads (SPP check; kernel threads/idle stay cooperative), reusing
    blocking-syscall context machinery; `Tests/Spin` canary proves a
    forever-spinner no longer hangs the system. SMP deferred: per-hart
    ready queues or shared queue + lock, IPIs, per-hart timers, cap
    table locking.
5. ~~Fuzzer~~ — done: grant-list spawn replaced grant_mask outright
   (syscall 8 a2 = grant count; entries in spawner's IPC buffer,
   rights-subset enforced); end-to-end echo (badge stamping,
   round-trip, one-shot reply cap, cap transfer + handle rewrite,
   reap), grant validation cases (unopened handle, escalation,
   unknown bits, count limit); 40/40 directed PASS. Session-manager
   badge pattern exercised: init mints badged endpoint to fuzzer.
6. Spawn ABI v2 remainder: image cap instead of path slice
   (`Boot_File_Object` caps for initrd files handed to init); bootinfo
   page for init bootstrap; retire manifest path slices and
   boot_read_byte once migrated. Grant-list mechanism already in
   place from milestone 5.
7. RTS core: `Akernel.IPC` typed wrappers; init migrated to namespace
   composition (manifest becomes data for grant lists only).

Commit between each milestone.

## Deferred (do not build yet)

- Plain `send`, register fast path, notification objects, >4 caps/msg.
- Kernel introspection syscalls for init state reconstruction.
- SMP: per-hart scheduling, IPIs, cap-table/endpoint locking.
- Memory object alloc/map syscalls (needed by RTS heap + DMA later).
- DTB device enumeration, IOMMU, tasking runtime, 9P-ish file protocol.

## Start by reading

- `docs/IPC.md`
- `src/kernel/kernel-ipc.*` (existing scaffold)
- `src/kernel/kernel-capabilities.*` (Duplicate/minting basis)
- `src/kernel/kernel-objects.*` (cleanup dispatcher, object kinds)
- `src/kernel/kernel-tasks.*` (cap table ownership, thread access)
- `src/arch/riscv64/arch-traps.adb` (syscall dispatcher)
