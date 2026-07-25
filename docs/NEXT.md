# Next step

Continue object cleanup + authority model hardening.

Done recently:
- PMM is bump allocator plus freed-frame singly-linked free list.
- `Allocate_Frame` reuses freed frames before bumping.
- `Deallocate_Frame` validates managed/aligned/currently allocated frames, rejects double frees already in free list, shrinks bump pointer for most-recent frame, otherwise pushes frame onto free list.
- `Free_Bytes` includes bump space plus free-list frames; `Free_Frame_Count` exposes diagnostics.
- Boot PMM selftest checks free-list reuse, free-count restore, and double-free rejection; expected boot line: `pmm selftest online`.
- `Arch.MMU.Destroy_User_Address_Space` walks Sv39 tables, skips global supervisor leaves, frees non-global leaf frames and page tables, then frees root.
- Syscall 9 `exit` now runs cap/object cleanup hooks for current process caps, marks current thread dead and owning process dead, then schedules next ready thread or idles.
- Syscall 10 `reap_process` closes parent process cap, runs cap/object cleanup hooks again, destroys child user address space, returns child frames/page tables to PMM, resets child cap table, and frees spawned slot; live child returns 2.
- Endpoint cleanup hook clears matching waiting sender/receiver slots for exiting/reaped thread.
- IRQ cleanup hook clears matching waiter slot for exiting/reaped thread.
- Cap tables have reset/count helpers; reaped process cap table is reset.
- Scheduler rejects dead threads on push, skips dead queued entries on pop, and has `Remove_Thread` for teardown purge.
- Userspace wrappers `Process_Exit` and `Reap_Process` exist.
- `make all` and timeout boot run pass with expected boot output.

Continue with:
1. Decide return caps: process cap now returned; add main thread cap only if needed.
2. Add address-space object type/use where VM operations need explicit authority.
3. Add per-thread kernel stack/trap-frame storage; stop depending on global trap stack/raw frame copies.
4. Add object refcounts/close hooks if new shared kernel objects need ownership semantics beyond endpoint/IRQ waiter cleanup.
5. Add stronger PMM/page-table stress tests once test harness exists.

Start by reading:
- `docs/STATE.md`
- `src/kernel/kernel-processes.ads/.adb`
- `src/kernel/kernel-ipc.ads/.adb`
- `src/kernel/kernel-interrupts.ads/.adb`
- `src/kernel/kernel-tasks.ads/.adb`
- `src/arch/riscv64/arch-traps.adb`
