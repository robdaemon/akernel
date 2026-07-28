# Next step

Continue object/authority hardening.

Done recently:
- PMM is bump allocator plus freed-frame singly-linked free list.
- Boot PMM selftest checks free-list reuse, free-count restore, and double-free rejection; expected boot line: `pmm selftest online`.
- `Arch.MMU.Destroy_User_Address_Space` walks Sv39 tables, skips global supervisor leaves, frees non-global leaf frames and page tables, then frees root.
- Syscall 9 `exit` runs cap/object cleanup hooks for current process caps, marks current thread dead and owning process dead, then schedules next ready thread or idles.
- Syscall 10 `reap_process` closes parent process cap, runs cap/object cleanup hooks again, destroys child user address space, returns child frames/page tables to PMM, resets child cap table, and frees spawned slot; live child returns 2.
- `Kernel.Objects.Cleanup_Thread_Cap_Object` is generic object cleanup dispatcher for thread-owned cap references.
- Endpoint cleanup hook clears matching waiting sender/receiver slots for exiting/reaped/closing thread cap.
- IRQ cleanup hook clears matching waiter slot for exiting/reaped/closing thread cap.
- `Kernel.Tasks.Close_Cap` takes `Thread_Access`, runs object cleanup for target cap, then closes cap table slot.
- Public `Close_Process_Cap` removed so callers cannot close thread-affine caps without cleanup owner context.
- Fixed cap handle 255 is reserved as process self `Address_Space_Object` cap.
- `map_mmio` takes explicit address-space cap in `a0`, MMIO cap in `a1`, VA/offset/length/flags in `a2..a5`; old implicit address-space authority ABI removed.
- Trap syscall handlers validate user cap-handle integers before converting to `Kernel.Capabilities.Handle`; out-of-range handles now fail cleanly.
- Init and spawned user threads have per-thread kernel stack frames; scheduler restore writes `sscratch` from current thread stack top before returning to user.
- Spawn/reap cleanup frees spawned thread kernel stack frames.
- `Arch.Context` owns RISC-V trap-frame layout and saved `sepc`; `Kernel.Tasks` stores opaque `Arch.Context.Thread_Context` and calls arch context save/restore APIs.
- Legacy id-based spawn syscall 5 removed; userspace only exposes `spawn_boot_path` syscall 8.
- Legacy `Kernel.Program_Loader.Find(program_id)` and manifest grant parser backend removed; loader now only resolves manifest path slices to initrd images.
- `spawn_boot_path` returns explicit status in `a0` and process cap in `a1`; userspace wrapper stores cap through out parameter.
- `make all` and timeout boot run pass with expected boot output.
- Boot PMM selftest now also runs an interleaved 32-frame stress: allocate batch, free every other frame, reallocate holes from free list, free all; free count must track exactly at each phase.
- User address spaces no longer copy the broad root[0] low-MMIO gigapage; `Arch.MMU.New_User_Address_Space` maps narrow supervisor-only windows instead (UART page, PLIC priority/enable pages, PLIC context pages 0..3). Trap path still runs on user `satp`, so kernel RAM identity map and device windows must stay mapped until a kernel virtual map/trampoline exists.

Decisions made:
- No main thread cap returned from spawn for now: no syscall targets a specific thread (`exit` acts on current thread, `reap_process` uses process cap). Add thread caps only when a thread-targeting syscall appears.
- No object refcounts yet: shared resource objects (`MMIO_Region`, `IRQ_Line`, endpoints) are kernel-owned statics that are never freed, so cleanup hooks suffice. Add refcounts only when dynamically-owned shared objects appear.

Continue with:
1. Improve VM isolation further: proper kernel virtual map + satp switch on trap entry (trampoline page), then drop RAM identity map and device windows from user roots.
2. Add fuzz-like syscall argument tests once userspace test harness exists.

Start by reading:
- `docs/STATE.md`
- `src/arch/riscv64/arch-traps.adb`
- `src/kernel/kernel-objects.ads/.adb`
- `src/kernel/kernel-tasks.ads/.adb`
- `src/kernel/kernel-processes.ads/.adb`
