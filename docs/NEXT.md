# Next step

Continue process/thread lifecycle + memory cleanup hardening.

Done recently:
- PMM is bump allocator plus freed-frame singly-linked free list.
- `Allocate_Frame` reuses freed frames before bumping.
- `Deallocate_Frame` validates managed/aligned/currently allocated frames, rejects double frees already in free list, shrinks bump pointer for most-recent frame, otherwise pushes frame onto free list.
- `Free_Bytes` includes bump space plus free-list frames; `Free_Frame_Count` exposes diagnostics.
- Boot PMM selftest checks free-list reuse, free-count restore, and double-free rejection; expected boot line: `pmm selftest online`.
- `Arch.MMU.Destroy_User_Address_Space` walks Sv39 tables, skips global supervisor leaves, frees non-global leaf frames and page tables, then frees root.
- ELF loader frees just-allocated frame when final `Map_Page` fails.
- Spawn failure paths use explicit address-space/frame cleanup instead of PMM rewind.
- Syscall 9 `exit` marks current thread dead and owning process dead, then schedules next ready thread or idles.
- Syscall 10 `reap_process` closes parent process cap, destroys child user address space, returns child frames/page tables to PMM, clears child cap table, and frees spawned slot; live child returns 2.
- Cap tables have reset/count helpers; reaped process cap table is reset.
- Scheduler rejects dead threads on push, skips dead queued entries on pop, and has `Remove_Thread` for teardown purge.
- IPC send/receive drop dead waiting sender/receiver slots before matching.
- IRQ wait clears dead stale waiter before installing/checking waiter.
- Userspace wrappers `Process_Exit` and `Reap_Process` exist.
- `make all` and timeout boot run pass with expected boot output.

Continue with:
1. Add richer cap/object cleanup on exit/reap: object-specific close hooks/refcounts where needed.
2. Decide return caps: process cap now returned; add main thread cap only if needed.
3. Add address-space object type/use where VM operations need explicit authority.
4. Add per-thread kernel stack/trap-frame storage; stop depending on global trap stack/raw frame copies.
5. Add stronger PMM/page-table stress tests once test harness exists.

Start by reading:
- `docs/STATE.md`
- `src/kernel/kernel-physical_memory.ads/.adb`
- `src/arch/riscv64/arch-mmu.ads/.adb`
- `src/kernel/kernel-processes.ads/.adb`
- `src/kernel/kernel-tasks.ads/.adb`
- `src/arch/riscv64/arch-traps.adb`
