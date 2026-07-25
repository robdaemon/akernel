# Next step

Continue with process/thread split hardening.

Goal:
- Split current TCB, which combines process and thread concepts.
- Process owns address space, cap table, resource/lifecycle state.
- Thread owns saved context, scheduler state, future kernel stack/trap frame.
- Kernel scheduler schedules kernel-visible threads.
- Spawn creates process plus main thread.

Start by reading:
- `docs/STATE.md`
- `src/kernel/kernel-tasks.ads/.adb`
- `src/kernel/kernel-processes.ads/.adb`
- `src/kernel/kernel-scheduler.ads/.adb`
- `src/arch/riscv64/arch-traps.adb`
