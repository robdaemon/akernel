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
2. Dynamic endpoints: `ep_create` (syscall 11), endpoint finalizer
   (fail blocked caller + waiting receiver on last close).
3. Per-thread IPC buffer page at VA `0x6FFF0000`, created/mapped at
   thread spawn; kernel buffer access via user-root walk + physmap.
4. `call`/`recv`/`reply` (syscalls 12-14): rendezvous, badge stamping,
   cap transfer (Transfer right required, duplicate into receiver table,
     rewrite buffer slots), reply cap minting/one-shot/lifecycle edges.
5. Fuzzer: IPC/endpoint directed cases (all reply-cap lifecycle rows in
   docs/IPC.md) + random phase with endpoints; multi-process fuzz
   (spawn child that fuzzes, then reap); valid-handle/wrong-rights cases.
6. Spawn ABI v2: image cap + grant list via IPC buffer;
   `Boot_File_Object` caps for initrd files handed to init; bootinfo
   page for init bootstrap; retire grant_mask, manifest path slices,
   and boot_read_byte once migrated.
7. RTS core: `Akernel.IPC` typed wrappers; init migrated to namespace
   composition (manifest becomes data for grant lists only).

Commit between each milestone.

## Deferred (do not build yet)

- Plain `send`, register fast path, notification objects, >4 caps/msg.
- Kernel introspection syscalls for init state reconstruction.
- Memory object alloc/map syscalls (needed by RTS heap + DMA later).
- DTB device enumeration, IOMMU, tasking runtime, 9P-ish file protocol.

## Start by reading

- `docs/IPC.md`
- `src/kernel/kernel-ipc.*` (existing scaffold)
- `src/kernel/kernel-capabilities.*` (Duplicate/minting basis)
- `src/kernel/kernel-objects.*` (cleanup dispatcher, object kinds)
- `src/kernel/kernel-tasks.*` (cap table ownership, thread access)
- `src/arch/riscv64/arch-traps.adb` (syscall dispatcher)
