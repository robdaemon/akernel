with Arch;
with Board.Memory_Map;

package body Board.RTC is
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   Base : U64 := Arch.Phys_To_Virt (Board.Memory_Map.RTC_Base);

   --  Goldfish RTC registers (32-bit): nanoseconds since epoch.
   function Time_Low  return U64 is (Base + 0);
   function Time_High return U64 is (Base + 4);

   function Mmio_Read32 (Address : U64) return U32
     with Import, Convention => C, External_Name => "mmio_read32";

   procedure Set_Base (Physical_Base : Interfaces.Unsigned_64) is
   begin
      Base := Arch.Phys_To_Virt (Physical_Base);
   end Set_Base;

   function Present return Boolean is (Base /= 0);

   function Read_Nanoseconds return U64 is
      Hi0, Hi1, Lo : U32;
   begin
      if Base = 0 then
         return 0;
      end if;
      Hi0 := Mmio_Read32 (Time_High);
      Lo  := Mmio_Read32 (Time_Low);
      Hi1 := Mmio_Read32 (Time_High);
      if Hi0 /= Hi1 then
         Lo := Mmio_Read32 (Time_Low);  --  ticked mid-read
      end if;
      return Interfaces.Shift_Left (U64 (Hi1), 32) or U64 (Lo);
   end Read_Nanoseconds;

end Board.RTC;
