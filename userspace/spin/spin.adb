with Akernel_User.Syscalls;

--  Preemption canary: never yields, never makes syscalls after the
--  banner. Under a cooperative-only scheduler this thread would hang
--  the whole system once scheduled; with timer preemption the rest of
--  the system keeps running (init prints "init resumed", the kernel
--  keeps ticking).
procedure Spin is
begin
   Akernel_User.Syscalls.Debug_Put_Line ("spin online");
   loop
      null;
   end loop;
end Spin;
