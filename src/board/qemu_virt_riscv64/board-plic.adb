with Arch;
with Board.Memory_Map;

package body Board.PLIC is
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   Base               : U64 := Arch.Phys_To_Virt (Board.Memory_Map.PLIC_Base);
   Enable_Base        : constant U64 := 16#2000#;
   Context_Base       : constant U64 := 16#20_0000#;
   Context_Stride     : constant U64 := 16#1000#;
   Enable_Stride      : constant U64 := 16#80#;
   Threshold_Offset   : constant U64 := 0;
   Claim_Offset       : constant U64 := 4;

   Boot_Hart_Id : U64
     with Import, Convention => C, External_Name => "boot_hart_id";

   function Mmio_Read32 (Address : U64) return U32
     with Import, Convention => C, External_Name => "mmio_read32";

   procedure Mmio_Write32 (Address : U64; Value : U32)
     with Import, Convention => C, External_Name => "mmio_write32";

   function Context_Id return U64 is
   begin
      return Boot_Hart_Id * 2 + 1;
   end Context_Id;

   procedure Set_Base (Physical_Base : Interfaces.Unsigned_64) is
   begin
      Base := Arch.Phys_To_Virt (Physical_Base);
   end Set_Base;

   function Enable_Address (Source : Source_Id) return U64 is
      Context : constant U64 := Context_Id;
      Word    : constant U64 := U64 (Source) / 32;
   begin
      return Base + Enable_Base + Context * Enable_Stride + Word * 4;
   end Enable_Address;

   function Context_Address (Offset : U64) return U64 is
   begin
      return Base + Context_Base + Context_Id * Context_Stride + Offset;
   end Context_Address;

   procedure Initialize is
   begin
      Mmio_Write32 (Context_Address (Threshold_Offset), 0);
   end Initialize;

   procedure Enable (Source : Source_Id) is
      Bit     : constant Natural := Natural (Source) mod 32;
      Address : constant U64 := Enable_Address (Source);
      Current : constant U32 := Mmio_Read32 (Address);
   begin
      if Source = No_Source then
         return;
      end if;

      Mmio_Write32 (Base + U64 (Source) * 4, 1);
      Mmio_Write32 (Address, Current or Interfaces.Shift_Left (U32'(1), Bit));
   end Enable;

   function Claim return Source_Id is
   begin
      return Source_Id (Mmio_Read32 (Context_Address (Claim_Offset)));
   end Claim;

   procedure Complete (Source : Source_Id) is
   begin
      Mmio_Write32 (Context_Address (Claim_Offset), U32 (Source));
   end Complete;
end Board.PLIC;
