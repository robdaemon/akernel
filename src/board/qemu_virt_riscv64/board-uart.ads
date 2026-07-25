package Board.UART is
   procedure Put (S : String);
   procedure Put_Line (S : String);
   procedure Put_Decimal (Value : Natural);

   procedure Initialize_Interrupts;
   procedure Handle_Interrupt;
end Board.UART;
