with Arch.MMU;

package body Kernel.Boot_Resources is
   use type Kernel.Devices.Status;

   MMIO_Object : System.Address := System.Null_Address;
   IRQ_Object  : System.Address := System.Null_Address;

   procedure Initialize (UART_Base : U64; UART_IRQ : U64) is
      Result : Kernel.Devices.Status;
   begin
      Kernel.Devices.Create_MMIO
        (Base    => UART_Base,
         Length  => Arch.MMU.Page_Size,
         Result  => Result,
         Object  => MMIO_Object);

      if Result = Kernel.Devices.Ok then
         Kernel.Devices.Create_IRQ
           (Source => UART_IRQ,
            Result => Result,
            Object => IRQ_Object);
      end if;

      if Result /= Kernel.Devices.Ok then
         MMIO_Object := System.Null_Address;
         IRQ_Object := System.Null_Address;
      end if;
   end Initialize;

   function UART_MMIO_Object return System.Address is (MMIO_Object);
   function UART_IRQ_Object return System.Address is (IRQ_Object);

   function UART_IRQ_Line return Kernel.Objects.IRQ_Line_Access is
   begin
      return Kernel.Devices.Line_Of (IRQ_Object);
   end UART_IRQ_Line;
end Kernel.Boot_Resources;
