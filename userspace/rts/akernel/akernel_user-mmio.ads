with Interfaces;

package Akernel_User.MMIO is
   subtype U8 is Interfaces.Unsigned_8;
   subtype U64 is Interfaces.Unsigned_64;

   function Read8 (Address : U64) return U8;
   procedure Write8 (Address : U64; Value : U8);
end Akernel_User.MMIO;
