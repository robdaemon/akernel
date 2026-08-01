with Board.PLIC;

package Board.Interrupts is
   procedure Initialize (UART_Source : Board.PLIC.Source_Id);
   procedure Handle_External_Interrupt;
end Board.Interrupts;
