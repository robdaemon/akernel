with Akernel_User.Console;

--  Preemption canary: never yields, never makes syscalls after the
--  banner. Under a cooperative-only scheduler this thread would hang
--  the whole system once scheduled; with timer preemption the rest of
--  the system keeps running (init prints "init resumed", the kernel
--  keeps ticking). Granted the console Send cap at handle 1.
procedure Spin is
begin
   Akernel_User.Console.Set_Endpoint (1);
   Akernel_User.Console.Put_Line ("spin online");
   loop
      null;
   end loop;
end Spin;
