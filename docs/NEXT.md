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
- `Kernel.Tasks.Close_Cap` now takes `Thread_Access`, runs object cleanup for target cap, then closes cap table slot.
- Fixed cap handle 255 is reserved as process self `Address_Space_Object` cap.
- `map_mmio` takes explicit address-space cap in `a0`, MMIO cap in `a1`, VA/offset/length/flags in `a2..a5`; old implicit address-space authority ABI removed.
- Init and spawned user threads have per-thread kernel stack frames; scheduler restore writes `sscratch` from current thread stack top before returning to user.
- Spawn/reap cleanup frees spawned thread kernel stack frames.
- `Arch.Context` owns RISC-V trap-frame layout and saved `sepc`; `Kernel.Tasks` stores opaque `Arch.Context.Thread_Context` and calls arch context save/restore APIs.
- Legacy id-based spawn syscall 5 removed; userspace only exposes `spawn_boot_path` syscall 8.
- Legacy `Kernel.Program_Loader.Find(program_id)` and manifest grant parser backend removed; loader now only resolves manifest path slices to initrd images.
- `spawn_boot_path` returns explicit status in `a0` and process cap in `a1`; userspace wrapper stores cap through out parameter.
- `make all` and timeout boot run pass with expected boot output.

Continue with:
1. Decide return caps: process cap now returned; add main thread cap only if needed.
2. Add object refcounts if new shared kernel objects need ownership semantics beyond cleanup hooks.
3. Add stronger PMM/page-table stress tests once test harness exists.
4. Improve VM isolation beyond explicit address-space caps: proper kernel virtual map instead of broad identity.

Start by reading:
- `docs/STATE.md`
- `src/kernel/kernel-objects.ads/.adb`
- `src/kernel/kernel-tasks.ads/.adb`
- `src/kernel/kernel-processes.ads/.adb`
- `src/kernel/kernel-capabilities.ads/.adb`
