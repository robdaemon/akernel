with Interfaces;

package Board.UART is
   --  MMIO base defaults to the board's UART0 address; the kernel
   --  overrides it from DTB discovery before userspace drivers start.
   procedure Set_Base (Physical_Base : Interfaces.Unsigned_64);

   procedure Put (S : String);
   procedure Put_Line (S : String);
   procedure Put_Decimal (Value : Natural);
   procedure Put_Hex (Value : Interfaces.Unsigned_64);

   procedure Initialize_Interrupts;
   procedure Handle_Interrupt;
end Board.UART;
