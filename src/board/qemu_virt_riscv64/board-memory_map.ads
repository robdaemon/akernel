with Interfaces;

package Board.Memory_Map is
   use type Interfaces.Unsigned_64;

   subtype U64 is Interfaces.Unsigned_64;

   RAM_Base        : constant U64 := 16#8000_0000#;
   Kernel_Base     : constant U64 := 16#8020_0000#;
   RAM_Size        : constant U64 := 128 * 1024 * 1024;
   RAM_End         : constant U64 := RAM_Base + RAM_Size;
   UART0_Base      : constant U64 := 16#1000_0000#;
   RTC_Base        : constant U64 := 16#1010_0000#;  --  goldfish
   PLIC_Base       : constant U64 := 16#0c00_0000#;
end Board.Memory_Map;
