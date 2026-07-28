with Interfaces;

package Board.UART is
   procedure Put (S : String);
   procedure Put_Line (S : String);
   procedure Put_Decimal (Value : Natural);
   procedure Put_Hex (Value : Interfaces.Unsigned_64);

   procedure Initialize_Interrupts;
   procedure Handle_Interrupt;
end Board.UART;
