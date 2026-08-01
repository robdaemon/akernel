with Board.UART;
with Kernel.Interrupts;

package body Board.Interrupts is
   procedure Initialize (UART_Source : Board.PLIC.Source_Id) is
   begin
      Board.PLIC.Initialize;
      Board.UART.Initialize_Interrupts;
      Board.PLIC.Enable (UART_Source);
   end Initialize;

   procedure Handle_External_Interrupt is
      Source  : constant Board.PLIC.Source_Id := Board.PLIC.Claim;
      Claimed : Boolean;
   begin
      case Source is
         when Board.PLIC.No_Source =>
            null;
         when others =>
            Kernel.Interrupts.Deliver
              (Source  => Kernel.Interrupts.U64 (Source),
               Claimed => Claimed);

            if not Claimed then
               Board.UART.Put ("external interrupt source ");
               Board.UART.Put_Decimal (Natural (Source));
               Board.UART.Put_Line ("");
               Board.PLIC.Complete (Source);
            end if;
      end case;
   end Handle_External_Interrupt;
end Board.Interrupts;
