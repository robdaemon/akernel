# Next step

Continue context/object hardening.

Done recently:
- PMM is bump allocator plus freed-frame singly-linked free list.
- Boot PMM selftest checks free-list reuse, free-count restore, and double-free rejection; expected boot line: `pmm selftest online`.
- `Arch.MMU.Destroy_User_Address_Space` walks Sv39 tables, skips global supervisor leaves, frees non-global leaf frames and page tables, then frees root.
- Syscall 9 `exit` runs cap/object cleanup hooks for current process caps, marks current thread dead and owning process dead, then schedules next ready thread or idles.
- Syscall 10 `reap_process` closes parent process cap, runs cap/object cleanup hooks again, destroys child user address space, returns child frames/page tables to PMM, resets child cap table, and frees spawned slot; live child returns 2.
- Endpoint cleanup hook clears matching waiting sender/receiver slots for exiting/reaped thread.
- IRQ cleanup hook clears matching waiter slot for exiting/reaped thread.
- Fixed cap handle 255 is reserved as process self `Address_Space_Object` cap; `map_mmio` requires it.
- Init and spawned user threads have per-thread kernel stack frames; scheduler restore writes `sscratch` from current thread stack top before returning to user.
- Spawn/reap cleanup frees spawned thread kernel stack frames.
- Full RISC-V trap-frame words plus saved `sepc` are stored per thread in `Thread_Control_Block`; context save/restore copies live stack trap frame to/from that per-thread storage.
- `Arch.User_Mode.Enter_User_Mode` no longer resets `sscratch`; caller/trap restore controls kernel trap stack.
- `make all` and timeout boot run pass with expected boot output.

Continue with:
1. Hide remaining arch-specific trap-frame layout from `Kernel.Tasks` behind arch-owned context type/API.
2. Decide return caps: process cap now returned; add main thread cap only if needed.
3. Add object refcounts/close hooks if new shared kernel objects need ownership semantics beyond endpoint/IRQ waiter cleanup.
4. Add stronger PMM/page-table stress tests once test harness exists.
5. Move remaining VM syscalls toward explicit address-space cap arguments instead of implicit fixed self cap.

Start by reading:
- `docs/STATE.md`
- `src/kernel/kernel-tasks.ads/.adb`
- `src/arch/riscv64/arch-traps.adb`
- `src/arch/riscv64/startup.s`
- `src/arch/riscv64/sbi_asm.s`
- `src/kernel/kernel-processes.ads/.adb`
