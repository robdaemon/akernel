with Akernel_User.Console;
with Akernel_User.Syscalls;

--  Preemption canary: never yields, never makes syscalls after the
--  banner. Under a cooperative-only scheduler this thread would hang
--  the whole system once scheduled; with timer preemption the rest of
--  the system keeps running (init prints "init resumed", the kernel
--  keeps ticking). Granted the console Send cap at handle 1.
--
--  Also the wakeup-boost regression test: on UP the hog must only
--  fill idle time — the fuzz suite's rendezvous handoffs are boosted
--  ahead of it, so the suite completes promptly even with this
--  thread spinning forever. If boost regresses, QEMU_SMP=1 runs go
--  back to ~600 ms per IPC-heavy test line.
--
--  UP demotion (m72c follow-up): "fill idle time" is only half the
--  story — fair 50/50 sharing with the hog doubled the CPU-bound
--  phases as the suite grew (~9.5 min SMP1 vs ~4 min SMP4).  On one
--  hart the canary now runs at priority -1: every woken thread
--  strictly outranks it, so priority preemption (syscall tail /
--  IRQ exit) keeps rendezvous and device latency at zero and Spin
--  genuinely fills idle only.  The canary itself is intact — it
--  still spins forever and would still hang the boot if timer
--  preemption broke.  SMP keeps priority 0: siblings hide the hog.
procedure Spin is
   use type Akernel_User.Syscalls.U64;
   Old : Integer;
   St  : Akernel_User.Syscalls.U64;
begin
   Akernel_User.Console.Set_Endpoint (1);
   if Akernel_User.Syscalls.CPU_Count = 1 then
      St := Akernel_User.Syscalls.Set_Priority
        (Akernel_User.Syscalls.Priority_Self, -1, Old);
      if St /= 0 then
         Akernel_User.Console.Put_Line ("spin: priority demote failed");
      end if;
   end if;
   Akernel_User.Console.Put_Line ("spin online");
   loop
      null;
   end loop;
end Spin;
