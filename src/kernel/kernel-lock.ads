--  Big kernel lock: serializes all kernel-mode execution across
--  harts (seL4-style BKL SMP).  Held from trap entry to trap exit
--  and dropped around the idle wfi; user-mode execution is never
--  serialized by it, so user threads run truly in parallel while
--  every kernel data structure (scheduler queue, cap tables,
--  endpoints, PMM, object slabs) stays effectively single-threaded.
--
--  Kernel mode runs with sstatus.SIE clear, so the lock is never
--  taken recursively through an interrupt: a trap handler either
--  holds it or is about to acquire it exactly once; Acquire treats a
--  violation of that invariant as fatal.
--
--  Release discipline: the trap trampoline itself releases the lock
--  after the C handler returns (see startup.s), because the return
--  path is the last reader of the old thread's kernel stack and an
--  earlier release would let another hart resume that thread and
--  clobber the stack mid-return.  Only paths that never return
--  through the trampoline (idle loop, fatal dumps) call Release.

package Kernel.Lock is
   procedure Acquire;
   procedure Release;
   --  Claim the single fatal dump: True for the first caller, False
   --  for everyone else (they should halt quietly).
   function Try_Enter_Fatal return Boolean;
end Kernel.Lock;
