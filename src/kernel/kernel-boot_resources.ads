with Interfaces;
with Kernel.Objects;

package Kernel.Boot_Resources is
   subtype U64 is Interfaces.Unsigned_64;

   --  Boot device objects backing the uart/mmio and uart/irq caps
   --  handed to init. Fields are filled by Initialize from DTB
   --  discovery (board defaults when the DTB lacks the nodes).
   UART_MMIO_Object : aliased Kernel.Objects.MMIO_Region;
   UART_IRQ_Object  : aliased Kernel.Objects.IRQ_Line;

   procedure Initialize (UART_Base : U64; UART_IRQ : U64);
end Kernel.Boot_Resources;
