with Interfaces;
with System;
with Kernel.Devices;
with Kernel.Objects;

package Kernel.Boot_Resources is
   subtype U64 is Interfaces.Unsigned_64;

   --  Boot device objects backing the uart/mmio and uart/irq caps
   --  handed to init. Created by Initialize (from DTB discovery,
   --  board defaults when the DTB lacks the nodes) as ordinary
   --  Kernel.Devices objects; init's caps pin them for life.
   procedure Initialize (UART_Base : U64; UART_IRQ : U64);

   function UART_MMIO_Object return System.Address;
   function UART_IRQ_Object return System.Address;
   function UART_IRQ_Line return Kernel.Objects.IRQ_Line_Access;
end Kernel.Boot_Resources;
