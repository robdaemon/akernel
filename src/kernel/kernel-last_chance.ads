with System;

--  Kernel unhandled-exception handler.  GNAT's runtime calls
--  __gnat_last_chance_handler (weak default in the RTS) whenever an
--  exception escapes a task; the strong definition here overrides it.
--  Previously the handler was a bare assembly WFI loop, so a kernel
--  exception (e.g. the cap-table underflow that wedged SMP boot) died
--  silently.  This one reports the exception location and the hart
--  to the UART before halting.
package Kernel.Last_Chance is

   procedure Handler (Msg : System.Address; Line : Integer);
   pragma Export (C, Handler, "__gnat_last_chance_handler");

end Kernel.Last_Chance;
