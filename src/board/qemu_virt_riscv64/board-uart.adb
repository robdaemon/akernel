with Arch;
with Board.Memory_Map;

package body Board.UART is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_64;

   subtype U8 is Interfaces.Unsigned_8;
   subtype U64 is Interfaces.Unsigned_64;

   Base : U64 := Arch.Phys_To_Virt (Board.Memory_Map.UART0_Base);

   function RBR return U64 is (Base + 0); -- receive buffer, read
   function THR return U64 is (Base + 0); -- transmit holding, write
   function IER return U64 is (Base + 1); -- interrupt enable
   function IIR return U64 is (Base + 2); -- interrupt identification
   function LSR return U64 is (Base + 5); -- line status

   IER_RDA : constant U8 := 16#01#; -- received data available
   LSR_DR  : constant U8 := 16#01#; -- data ready

   function Mmio_Read8 (Address : U64) return U8
     with Import, Convention => C, External_Name => "mmio_read8";

   procedure Mmio_Write8 (Address : U64; Value : U8)
     with Import, Convention => C, External_Name => "mmio_write8";

   procedure Set_Base (Physical_Base : Interfaces.Unsigned_64) is
   begin
      Base := Arch.Phys_To_Virt (Physical_Base);
   end Set_Base;

   procedure Put (S : String) is
   begin
      for C of S loop
         Mmio_Write8 (THR, Character'Pos (C));
      end loop;
   end Put;

   procedure Put_Line (S : String) is
   begin
      Put (S);
      Mmio_Write8 (THR, Character'Pos (Character'Val (10)));
   end Put_Line;

   procedure Put_Decimal (Value : Natural) is
   begin
      if Value >= 10 then
         Put_Decimal (Value / 10);
      end if;

      Mmio_Write8
        (THR,
         Character'Pos
           (Character'Val (Character'Pos ('0') + Value mod 10)));
   end Put_Decimal;

   procedure Put_Hex (Value : U64) is
      Hex : constant String := "0123456789abcdef";
      Shift : Natural := 60;
   begin
      Put ("0x");
      loop
         Mmio_Write8
           (THR,
            Character'Pos
              (Hex (Natural (Interfaces.Shift_Right (Value, Shift)
                 and 16#f#) + 1)));
         exit when Shift = 0;
         Shift := Shift - 4;
      end loop;
   end Put_Hex;

   procedure Initialize_Interrupts is
   begin
      --  Enable UART receive-data-available interrupt. PLIC handles routing.
      Mmio_Write8 (IER, IER_RDA);
   end Initialize_Interrupts;

   procedure Handle_Interrupt is
      Identification : U8;
      Status         : U8;
      Received       : U8;
   begin
      --  Reading IIR observes/acks interrupt identification in 16550 flow.
      Identification := Mmio_Read8 (IIR);
      pragma Unreferenced (Identification);

      loop
         Status := Mmio_Read8 (LSR);
         exit when (Status and LSR_DR) = 0;

         Received := Mmio_Read8 (RBR);
         Mmio_Write8 (THR, Received); -- echo for now
      end loop;
   end Handle_Interrupt;
end Board.UART;
