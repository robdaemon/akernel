package body Akernel_User.MMIO is
   function Raw_Read8 (Address : U64) return U8
     with Import, Convention => C, External_Name => "akernel_mmio_read8";

   procedure Raw_Write8 (Address : U64; Value : U8)
     with Import, Convention => C, External_Name => "akernel_mmio_write8";

   function Read8 (Address : U64) return U8 is
   begin
      return Raw_Read8 (Address);
   end Read8;

   procedure Write8 (Address : U64; Value : U8) is
   begin
      Raw_Write8 (Address, Value);
   end Write8;
end Akernel_User.MMIO;
