with Arch.MMU;
with Kernel.Objects;
with System;

package Kernel.Boot_Resources is
   UART_MMIO_Object : aliased Kernel.Objects.MMIO_Region :=
     (Physical_Base => 16#1000_0000#,
      Length        => Arch.MMU.Page_Size);

   UART_IRQ_Object : aliased Kernel.Objects.IRQ_Line :=
     (Source     => 10,
      Pending    => False,
      In_Flight  => False,
      Waiter     => null,
      Ntfn       => System.Null_Address,
      Ntfn_Badge => 0);
end Kernel.Boot_Resources;
