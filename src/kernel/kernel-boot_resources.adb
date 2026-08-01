with Arch.MMU;
with System;

package body Kernel.Boot_Resources is
   procedure Initialize (UART_Base : U64; UART_IRQ : U64) is
   begin
      UART_MMIO_Object :=
        (Physical_Base => UART_Base,
         Length        => Arch.MMU.Page_Size);

      UART_IRQ_Object :=
        (Source     => UART_IRQ,
         Pending    => False,
         In_Flight  => False,
         Waiter     => null,
         Ntfn       => System.Null_Address,
         Ntfn_Badge => 0);
   end Initialize;
end Kernel.Boot_Resources;
