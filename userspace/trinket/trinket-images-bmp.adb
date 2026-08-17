with Interfaces; use type Interfaces.Unsigned_8;

package body Trinket.Images.Bmp is
   use type Trinket.U64;

   subtype U8 is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of U8;

   function Claims (Buf : System.Address; Len : U64) return Boolean is
      B : Byte_Array (0 .. 1) with Address => Buf;
   begin
      return Len >= 2 and then B (0) = 66 and then B (1) = 77; -- "BM"
   end Claims;

   procedure Decode
     (Buf : System.Address; Len : U64;
      Img : out Image; St : out Status)
   is
      B : Byte_Array (0 .. Len - 1) with Address => Buf;

      --  Bounds-checked little-endian scalar reads. Any read past
      --  Len answers 0 and flags Bad — checked once at the end of
      --  the header walk and again after the pixel walk.
      Bad : Boolean := False;

      function U16 (Off : U64) return U64 is
      begin
         if Off + 1 >= Len then
            Bad := True;
            return 0;
         end if;
         return U64 (B (Off)) + U64 (B (Off + 1)) * 256;
      end U16;

      function U32 (Off : U64) return U64 is
      begin
         if Off + 3 >= Len then
            Bad := True;
            return 0;
         end if;
         return U64 (B (Off)) + U64 (B (Off + 1)) * 256
           + U64 (B (Off + 2)) * 65536 + U64 (B (Off + 3)) * 16#100_0000#;
      end U32;

      Data_Off   : U64;
      Hdr_Size   : U64;
      W_Raw      : U64;
      H_Raw      : U64;   --  raw signed height, two's complement
      Top_Down   : Boolean;
      Bpp        : U64;
      Comp       : U64;
      Row_Bytes  : U64;
      Need       : U64;
      Pix        : Pixel_Access;
   begin
      Img := (others => <>);
      St  := Malformed;

      if not Claims (Buf, Len) then
         St := Unsupported;
         return;
      end if;

      Data_Off := U32 (10);
      Hdr_Size := U32 (14);
      if Bad or else Hdr_Size < 40 then
         return;
      end if;

      W_Raw    := U32 (18);
      H_Raw    := U32 (22);
      Top_Down := H_Raw >= 16#8000_0000#;   --  negative i32
      if Top_Down then
         H_Raw := 16#1_0000_0000# - H_Raw;
      end if;
      Bpp      := U16 (28);
      Comp     := U32 (30);
      if Bad
        or else W_Raw = 0 or else W_Raw > Max_Dimension
        or else H_Raw = 0 or else H_Raw > Max_Dimension
        or else (Bpp /= 24 and then Bpp /= 32)
        or else Comp /= 0
      then
         return;
      end if;

      Row_Bytes := (W_Raw * Bpp + 31) / 32 * 4;
      Need      := Data_Off + Row_Bytes * H_Raw;
      if Data_Off < 54 or else Need > Len then
         return;   --  truncated or overlapping header (TRUNC.BMP)
      end if;

      Pix := new Pixel_Data (0 .. W_Raw * H_Raw - 1);
      Img := (W => W_Raw, H => H_Raw, Data => Pix,
              Has_Key => False, Key => 0);

      for Y in 0 .. H_Raw - 1 loop
         declare
            Src_Row : constant U64 :=
              (if Top_Down then Y else H_Raw - 1 - Y);
            Base    : constant U64 := Data_Off + Src_Row * Row_Bytes;
         begin
            for X in 0 .. W_Raw - 1 loop
               declare
                  O : constant U64 := Base + X * (Bpp / 8);
                  R : constant U64 := U64 (B (O + 2));
                  G : constant U64 := U64 (B (O + 1));
                  Bl : constant U64 := U64 (B (O));
                  A : constant U64 :=
                    (if Bpp = 32 then U64 (B (O + 3)) else 16#FF#);
               begin
                  Pix (Y * W_Raw + X) :=
                    Pixel (A * 16#100_0000# + R * 65536 + G * 256 + Bl);
               end;
            end loop;
         end;
      end loop;
      St := Ok;
   end Decode;

end Trinket.Images.Bmp;
