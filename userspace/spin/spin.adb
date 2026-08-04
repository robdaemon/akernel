with Akernel_User.Console;
with Akernel_User.Syscalls;

--  Preemption canary: never yields, never makes syscalls after the
--  banner. Under a cooperative-only scheduler this thread would hang
--  the whole system once scheduled; with timer preemption the rest of
--  the system keeps running (init prints "init resumed", the kernel
--  keeps ticking). Granted the console Send cap at handle 1.
--
--  Skips itself on UP: with one hart the canary's quanta only steal
--  CPU from rendezvous handoffs (the kernel still preempts it, so
--  nothing hangs — it is purely a slowdown), while the canary's real
--  value is proving preemption against concurrent load on SMP.
procedure Spin is
   use type Akernel_User.Syscalls.U64;
begin
   Akernel_User.Console.Set_Endpoint (1);
   if Akernel_User.Syscalls.CPU_Count = 1 then
      Akernel_User.Console.Put_Line ("spin skipped (UP)");
      Akernel_User.Syscalls.Process_Exit;
   end if;
   Akernel_User.Console.Put_Line ("spin online");
   loop
      null;
   end loop;
end Spin;
