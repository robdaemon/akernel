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
procedure Spin is
begin
   Akernel_User.Console.Set_Endpoint (1);
   Akernel_User.Console.Put_Line ("spin online");
   loop
      null;
   end loop;
end Spin;
