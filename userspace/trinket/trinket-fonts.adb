with Interfaces;
with Akernel_User.Files;
with Akernel_User.Syscalls;
with Font8x8;

package body Trinket.Fonts is
   use Interfaces;
   use type Trinket.U64;

   subtype U8 is Interfaces.Unsigned_8;

   Max_Rows : constant := 32;

   type Row_Array is array (0 .. Max_Rows - 1) of U8;
   type Glyph_Rec is record
      Valid       : Boolean := False;
      GW, GH      : U64 := 0;      --  BBX width/height
      XOff, YOff  : Integer := 0;  --  BBX offsets (yoff = baseline
                                   --  to glyph bottom)
      DW          : U64 := 8;      --  DWIDTH advance
      Rows        : Row_Array := (others => 0);
   end record;

   Glyphs        : array (0 .. 127) of Glyph_Rec;
   F_Ascent      : U64 := 6;
   F_Descent     : U64 := 2;
   F_From_Disk   : Boolean := False;
   Initialized   : Boolean := False;

   function Hex_Nibble (Ch : Character) return U8 is
   begin
      case Ch is
         when '0' .. '9' =>
            return U8 (Character'Pos (Ch) - Character'Pos ('0'));
         when 'A' .. 'F' =>
            return U8 (Character'Pos (Ch) - Character'Pos ('A') + 10);
         when 'a' .. 'f' =>
            return U8 (Character'Pos (Ch) - Character'Pos ('a') + 10);
         when others =>
            return 0;
      end case;
   end Hex_Nibble;

   function Hex_Byte (S : String; I : Natural) return U8 is
     (Hex_Nibble (S (I)) * 16 + Hex_Nibble (S (I + 1)));

   --  BDF bitmaps are MSB-first; font8x8 is LSB-first (the
   --  m28 burn comment). Internal rows are MSB-first.
   function Reverse_Bits (B : U8) return U8 is
      R : U8 := 0;
   begin
      for I in 0 .. 7 loop
         if (B and Shift_Left (U8'(1), I)) /= 0 then
            R := R or Shift_Left (U8'(1), 7 - I);
         end if;
      end loop;
      return R;
   end Reverse_Bits;

   procedure Install_Fallback is
   begin
      Glyphs := (others => (Valid => False, GW => 0, GH => 0,
                            XOff => 0, YOff => 0, DW => 8,
                            Rows => (others => 0)));
      for Ch in Character range ' ' .. '~' loop
         declare
            G : Glyph_Rec renames Glyphs (Character'Pos (Ch));
         begin
            G.Valid := True;
            G.GW := 8;
            G.GH := 8;
            G.XOff := 0;
            G.YOff := -2;
            G.DW := 8;
            for R in 0 .. 7 loop
               G.Rows (R) := Reverse_Bits (Font8x8.Font (Ch) (R));
            end loop;
         end;
      end loop;
      F_Ascent := 6;
      F_Descent := 2;
      F_From_Disk := False;
   end Install_Fallback;

   procedure Parse_BDF (Buf : String) is
      I        : Natural := Buf'First;
      Line_End : Natural;
      Cur      : Integer := 0;      --  current glyph encoding
      In_Glyph : Boolean := False;
      In_Bits  : Boolean := False;
      Row      : Natural := 0;
   begin
      Glyphs := (others => (Valid => False, GW => 0, GH => 0,
                            XOff => 0, YOff => 0, DW => 8,
                            Rows => (others => 0)));
      while I <= Buf'Last loop
         Line_End := I;
         while Line_End <= Buf'Last
           and then Buf (Line_End) /= ASCII.LF
         loop
            Line_End := Line_End + 1;
         end loop;
         declare
            Last : constant Natural :=
              (if Line_End > I
                 and then Buf (Line_End - 1) = ASCII.CR
               then Line_End - 2 else Line_End - 1);
            L : String renames Buf (I .. Last);
         begin
            if Last < I then
               null;
            elsif In_Bits then
               if L'Length >= 7
                 and then L (L'First .. L'First + 6) = "ENDCHAR"
               then
                  In_Bits := False;
                  In_Glyph := False;
               elsif Row < Max_Rows and then L'Length >= 2 then
                  if Cur >= 32 and then Cur <= 126 then
                     Glyphs (Cur).Rows (Row) :=
                       Hex_Byte (L, L'First);
                  end if;
                  Row := Row + 1;
               end if;
            elsif L'Length >= 9
              and then L (L'First .. L'First + 8) = "STARTCHAR"
            then
               In_Glyph := True;
               Cur := 0;
            elsif In_Glyph and then L'Length >= 9
              and then L (L'First .. L'First + 8) = "ENCODING "
            then
               Cur := Integer'Value (L (L'First + 9 .. L'Last));
               if Cur >= 32 and then Cur <= 126 then
                  Glyphs (Cur).Valid := True;
               end if;
            elsif In_Glyph and then L'Length >= 7
              and then L (L'First .. L'First + 6) = "DWIDTH "
            then
               declare
                  Sp : Natural := L'First + 7;
               begin
                  while Sp <= L'Last and then L (Sp) /= ' ' loop
                     Sp := Sp + 1;
                  end loop;
                  if Cur >= 32 and then Cur <= 126 then
                     Glyphs (Cur).DW :=
                       U64'Value (L (L'First + 7 .. Sp - 1));
                  end if;
               end;
            elsif In_Glyph and then L'Length >= 4
              and then L (L'First .. L'First + 3) = "BBX "
            then
               declare
                  P     : Natural := L'First + 4;
                  V     : array (0 .. 3) of Integer := (others => 0);
                  Idx   : Natural := 0;
                  Start : Natural;
               begin
                  while P <= L'Last and then Idx < 4 loop
                     while P <= L'Last and then L (P) = ' ' loop
                        P := P + 1;
                     end loop;
                     Start := P;
                     while P <= L'Last and then L (P) /= ' ' loop
                        P := P + 1;
                     end loop;
                     if Start <= P - 1 then
                        V (Idx) := Integer'Value (L (Start .. P - 1));
                        Idx := Idx + 1;
                     end if;
                  end loop;
                  if Cur >= 32 and then Cur <= 126 then
                     Glyphs (Cur).GW := U64 (V (0));
                     Glyphs (Cur).GH := U64 (V (1));
                     Glyphs (Cur).XOff := V (2);
                     Glyphs (Cur).YOff := V (3);
                  end if;
               end;
            elsif In_Glyph and then L'Length >= 6
              and then L (L'First .. L'First + 5) = "BITMAP"
            then
               In_Bits := True;
               Row := 0;
            elsif L'Length >= 12
              and then L (L'First .. L'First + 11) = "FONT_ASCENT "
            then
               F_Ascent := U64'Value (L (L'First + 12 .. L'Last));
            elsif L'Length >= 13
              and then L (L'First .. L'First + 12) = "FONT_DESCENT "
            then
               F_Descent := U64'Value (L (L'First + 13 .. L'Last));
            end if;
         end;
         I := Line_End + 1;
      end loop;
   end Parse_BDF;

   procedure Init (Path : String := "Sys:Fonts/font8x8.bdf") is
      use Akernel_User;
      Size  : U64;
      Count : U64;
      St    : U64;
   begin
      --  Idempotent (milestone 68): the glyph cache is library-global;
      --  loading once keeps later Init calls (and any concurrent
      --  callers) from racing a re-parse.
      if Initialized then
         return;
      end if;
      Initialized := True;
      St := Files.Open (Path, Size);
      if St = Files.Status_Ok and then Size > 0
        and then Size <= 64 * 1024
      then
         declare
            Buf : constant access String := new String (1 .. Natural (Size));
         begin
            St := Files.Read
              (Path, 0, Buf.all'Address, Size, Count);
            if St = Files.Status_Ok and then Count = Size then
               Parse_BDF (Buf.all);
               F_From_Disk := True;
               St := Files.Close (Path);
               return;
            end if;
            St := Files.Close (Path);
         end;
      end if;
      Install_Fallback;
   end Init;

   function Loaded_From_Disk return Boolean is (F_From_Disk);

   function Line_Height return U64 is (F_Ascent + F_Descent);

   function Text_Width (S : String) return U64 is
      W : U64 := 0;
   begin
      for Ch of S loop
         if Character'Pos (Ch) <= 127
           and then Glyphs (Character'Pos (Ch)).Valid
         then
            W := W + Glyphs (Character'Pos (Ch)).DW;
         else
            W := W + 8;
         end if;
      end loop;
      return W;
   end Text_Width;

   procedure Draw_Text
     (C : Canvas; X, Y : U64; S : String; FG : Pixel)
   is
      Pix      : Pixel_Array (0 .. C.W * C.H - 1)
        with Address => C.Base;
      Baseline : constant Integer := Integer (Y) + Integer (F_Ascent);
      Pen      : Integer := Integer (X);
   begin
      for Ch of S loop
         declare
            Code : constant Natural := Character'Pos (Ch);
         begin
            if Code <= 127 and then Glyphs (Code).Valid then
               declare
                  G : Glyph_Rec renames Glyphs (Code);
                  GY : constant Integer :=
                    Baseline - G.YOff - Integer (G.GH);
               begin
                  for R in 0 .. Integer (G.GH) - 1 loop
                     if R < Max_Rows then
                        for Col in 0 .. Integer (G.GW) - 1 loop
                           if Col < 8
                             and then (G.Rows (R) and
                               Shift_Left (U8'(1), 7 - Col)) /= 0
                           then
                              declare
                                 PX : constant U64 :=
                                   U64 (Pen + G.XOff + Col);
                                 PY : constant U64 :=
                                   U64 (GY + R);
                              begin
                                 if PX >= C.CX0 and then PX < C.CX1
                                   and then PY >= C.CY0
                                   and then PY < C.CY1
                                   and then PX < C.W
                                   and then PY < C.H
                                 then
                                    Pix (PY * C.W + PX) := FG;
                                 end if;
                              end;
                           end if;
                        end loop;
                     end if;
                  end loop;
                  Pen := Pen + Integer (G.DW);
               end;
            else
               Pen := Pen + 8;
            end if;
         end;
      end loop;
   end Draw_Text;

end Trinket.Fonts;
