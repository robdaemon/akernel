# Next step

Continue object cleanup + authority model hardening.

Done recently:
- PMM is bump allocator plus freed-frame singly-linked free list.
- Boot PMM selftest checks free-list reuse, free-count restore, and double-free rejection; expected boot line: `pmm selftest online`.
- `Arch.MMU.Destroy_User_Address_Space` walks Sv39 tables, skips global supervisor leaves, frees non-global leaf frames and page tables, then frees root.
- Syscall 9 `exit` runs cap/object cleanup hooks for current process caps, marks current thread dead and owning process dead, then schedules next ready thread or idles.
- Syscall 10 `reap_process` closes parent process cap, runs cap/object cleanup hooks again, destroys child user address space, returns child frames/page tables to PMM, resets child cap table, and frees spawned slot; live child returns 2.
- Endpoint cleanup hook clears matching waiting sender/receiver slots for exiting/reaped thread.
- IRQ cleanup hook clears matching waiter slot for exiting/reaped thread.
- Fixed cap handle 255 is reserved as process self `Address_Space_Object` cap.
- Init and spawned processes install self address-space cap after root creation.
- `map_mmio` now requires current process has self address-space cap with `Map` and matching root before modifying VM mappings.
- Cap tables have reset/count helpers; reaped process cap table is reset.
- `make all` and timeout boot run pass with expected boot output.

Continue with:
1. Decide return caps: process cap now returned; add main thread cap only if needed.
2. Add per-thread kernel stack/trap-frame storage; stop depending on global trap stack/raw frame copies.
3. Add object refcounts/close hooks if new shared kernel objects need ownership semantics beyond endpoint/IRQ waiter cleanup.
4. Add stronger PMM/page-table stress tests once test harness exists.
5. Move remaining VM syscalls toward explicit address-space cap arguments instead of implicit fixed self cap.

Start by reading:
- `docs/STATE.md`
- `src/kernel/kernel-tasks.ads/.adb`
- `src/arch/riscv64/arch-traps.adb`
- `src/kernel/kernel-processes.ads/.adb`
- `src/kernel/kernel-ipc.ads/.adb`
- `src/kernel/kernel-interrupts.ads/.adb`
