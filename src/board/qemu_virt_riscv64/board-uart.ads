with Interfaces;

package Board.UART is
   --  MMIO base defaults to the board's UART0 address; the kernel
   --  overrides it from DTB discovery before userspace drivers start.
   procedure Set_Base (Physical_Base : Interfaces.Unsigned_64);

   procedure Put (S : String);
   procedure Put_Line (S : String);
   procedure Put_Decimal (Value : Natural);
   procedure Put_Hex (Value : Interfaces.Unsigned_64);

   --  Panic paths (fatal trap dump, lock diagnostics): no print
   --  lock.  A fault may strike while this hart itself holds the
   --  print lock mid-message, so panic output must not try to take
   --  it; messages may interleave, but they appear.
   procedure Put_Unsafe (S : String);
   procedure Put_Line_Unsafe (S : String);
   procedure Put_Hex_Unsafe (Value : Interfaces.Unsigned_64);

   procedure Initialize_Interrupts;
   procedure Handle_Interrupt;
end Board.UART;
