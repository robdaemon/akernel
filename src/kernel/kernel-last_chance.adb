with Ada.Unchecked_Conversion;
with Board.UART;
with Interfaces;
with Kernel.CPUs;
with System.Address_To_Access_Conversions;
with System.Storage_Elements;

package body Kernel.Last_Chance is
   use System.Storage_Elements;

   --  The asm WFI loop in runtime_stubs.s: halts this hart for good.
   procedure Halt
     with Import, Convention => C, External_Name => "__gnat_exit";

   package Byte_Conv is new System.Address_To_Access_Conversions
     (Character);

   function To_U64 is new Ada.Unchecked_Conversion
     (Source => Integer_Address,
      Target => Interfaces.Unsigned_64);

   --  Re-entry guard, one slot per hart: if printing itself faults
   --  (corrupt Msg pointer, nested exception) the handler is entered
   --  again — halt instead of recursing.  The kernel is compiled with
   --  No_Exception_Propagation, so no local handler can catch faults
   --  raised across calls; the guard is the safety net.
   In_Handler : array (Kernel.CPUs.CPU_Index) of Boolean :=
     (others => False);

   procedure Handler (Msg : System.Address; Line : Integer) is
      Base : constant Integer_Address := To_Integer (Msg);
      Hart : constant Kernel.CPUs.CPU_Index := Kernel.CPUs.Current;
      Buf  : Character;
      Len  : Natural := 0;
   begin
      if In_Handler (Hart) then
         Halt;
      end if;
      In_Handler (Hart) := True;

      Board.UART.Put_Unsafe ("kernel panic on cpu");
      Board.UART.Put_Unsafe (Kernel.CPUs.CPU_Index'Image (Hart));
      Board.UART.Put_Line_Unsafe ("");

      Board.UART.Put_Unsafe ("  msg @");
      Board.UART.Put_Hex_Unsafe (To_U64 (Base));
      Board.UART.Put_Line_Unsafe ("");

      Board.UART.Put_Unsafe ("  line ");
      Board.UART.Put_Hex_Unsafe (Interfaces.Unsigned_64 (Line));
      Board.UART.Put_Line_Unsafe ("");

      Board.UART.Put_Unsafe ("  ");
      loop
         exit when Len > 256;
         Buf :=
           Byte_Conv.To_Pointer
             (To_Address (Base + Integer_Address (Len))).all;
         exit when Buf = ASCII.NUL;
         Board.UART.Put_Unsafe (String'(1 => Buf));
         Len := Len + 1;
      end loop;
      Board.UART.Put_Line_Unsafe ("");

      Halt;
   end Handler;

end Kernel.Last_Chance;
