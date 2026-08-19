with Ada.Unchecked_Deallocation;
with Interfaces; use type Interfaces.Unsigned_8;

package body Trinket.Images.Xpm is
   use type Trinket.U64;

   subtype U8 is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of U8;

   Max_Colors : constant := 256;

   --  A quoted line can be up to Max_Dimension * cpp characters;
   --  2048 covers 1024-wide cpp-2 rows.
   Max_Line : constant := 2048;

   function Claims (Buf : System.Address; Len : U64) return Boolean is
      B : Byte_Array (0 .. 8) with Address => Buf;
      M : constant String := "/* XPM */";
   begin
      if Len < 9 then
         return False;
      end if;
      for I in M'Range loop
         if B (U64 (I - M'First)) /=
           U8 (Character'Pos (M (I)))
         then
            return False;
         end if;
      end loop;
      return True;
   end Claims;

   procedure Decode
     (Buf : System.Address; Len : U64;
      Img : out Image; St : out Status)
   is
      B : Byte_Array (0 .. Len - 1) with Address => Buf;

      procedure Free_Span is
        new Ada.Unchecked_Deallocation (Pixel_Data, Pixel_Access);

      --  Quoted-string cursor: XPM bodies are '"' delimited
      --  strings with arbitrary C punctuation/comments between
      --  them. Next_Quoted copies the next string's content
      --  into Line; Eof when no further string (also for an
      --  unterminated or oversized line — both are Malformed).
      Pos  : U64 := 8;
      Line : String (1 .. Max_Line);
      LL   : Natural := 0;
      Eof  : Boolean := False;

      procedure Next_Quoted is
         P : U64;
      begin
         LL  := 0;
         Eof := False;
         while Pos < Len and then B (Pos) /= 34 loop  --  '"'
            Pos := Pos + 1;
         end loop;
         if Pos >= Len then
            Eof := True;
            return;
         end if;
         Pos := Pos + 1;
         P   := Pos;
         while P < Len and then B (P) /= 34 loop
            P := P + 1;
         end loop;
         if P >= Len or else P - Pos > Max_Line then
            Eof := True;
            return;
         end if;
         LL := Natural (P - Pos);
         for I in 1 .. LL loop
            Line (I) := Character'Val (Natural (B (Pos + U64 (I - 1))));
         end loop;
         Pos := P + 1;
      end Next_Quoted;

      --  Tiny token helpers over Line (1 .. LL).
      procedure Skip_Spaces (I : in out Natural) is
      begin
         while I <= LL and then Line (I) = ' ' loop
            I := I + 1;
         end loop;
      end Skip_Spaces;

      function Natural_At (I : in out Natural; Parsed : out Boolean)
                           return Natural
      is
         V : Natural := 0;
      begin
         Parsed := False;
         Skip_Spaces (I);
         if I > LL or else Line (I) not in '0' .. '9' then
            return 0;
         end if;
         while I <= LL and then Line (I) in '0' .. '9' loop
            V := V * 10 + Character'Pos (Line (I)) - 48;
            if V > 100_000 then
               return 0;   --  absurd; caller range-checks anyway
            end if;
            I := I + 1;
         end loop;
         Parsed := True;
         return V;
      end Natural_At;

      function Hex_Digit (Ch : Character; V : out U64) return Boolean is
      begin
         case Ch is
            when '0' .. '9' => V := U64 (Character'Pos (Ch) - 48);
            when 'a' .. 'f' => V := U64 (Character'Pos (Ch) - 87);
            when 'A' .. 'F' => V := U64 (Character'Pos (Ch) - 55);
            when others     => V := 0; return False;
         end case;
         return True;
      end Hex_Digit;

      function Is_None (S : String) return Boolean is
         function Up (Ch : Character) return Character is
           (if Ch in 'a' .. 'z'
            then Character'Val (Character'Pos (Ch) - 32) else Ch);
      begin
         return S'Length = 4
           and then Up (S (S'First)) = 'N'
           and then Up (S (S'First + 1)) = 'O'
           and then Up (S (S'First + 2)) = 'N'
           and then Up (S (S'First + 3)) = 'E';
      end Is_None;

      --  Palette: cpp-char keys to pixel values; None entries
      --  carry value 0 and flip Saw_None.
      Key1 : array (1 .. Max_Colors) of U8 := (others => 0);
      Key2 : array (1 .. Max_Colors) of U8 := (others => 0);
      Val  : array (1 .. Max_Colors) of Pixel := (others => 0);
      NPal : Natural := 0;
      Saw_None : Boolean := False;

      function Lookup (I : Positive; Cpp : U64; Found : out Boolean)
                       return Pixel
      is
      begin
         Found := False;
         for K in 1 .. NPal loop
            if Key1 (K) = U8 (Character'Pos (Line (I)))
              and then (Cpp = 1
                        or else Key2 (K) =
                          U8 (Character'Pos (Line (I + 1))))
            then
               Found := True;
               return Val (K);
            end if;
         end loop;
         return 0;
      end Lookup;

      W, H, NC, Cpp : Natural;
      I   : Natural;
      Parsed : Boolean;
      Pix : Pixel_Access;
   begin
      Img := (others => <>);
      St  := Malformed;

      --  Header line.
      Next_Quoted;
      if Eof then
         return;
      end if;
      I := 1;
      W   := Natural_At (I, Parsed);
      if not Parsed then return; end if;
      H   := Natural_At (I, Parsed);
      if not Parsed then return; end if;
      NC  := Natural_At (I, Parsed);
      if not Parsed then return; end if;
      Cpp := Natural_At (I, Parsed);
      if not Parsed
        or else W = 0 or else U64 (W) > Max_Dimension
        or else H = 0 or else U64 (H) > Max_Dimension
        or else NC = 0 or else NC > Max_Colors
        or else (Cpp /= 1 and then Cpp /= 2)
      then
         return;
      end if;

      --  Color lines: "<key> [s <name>] c <value>"; only the
      --  c-token is honored.
      for E in 1 .. NC loop
         Next_Quoted;
         if Eof or else LL < Cpp then
            return;
         end if;
         declare
            K1 : constant U8 := U8 (Character'Pos (Line (1)));
            K2 : constant U8 :=
              (if Cpp = 2 then U8 (Character'Pos (Line (2))) else 0);
            J      : Natural := Cpp + 1;
            Got_C  : Boolean := False;
            Pixval : Pixel := 0;
            Is_Tr  : Boolean := False;
         begin
            --  Duplicate keys are a malformed palette.
            for K in 1 .. NPal loop
               if Key1 (K) = K1
                 and then (Cpp = 1 or else Key2 (K) = K2)
               then
                  return;
               end if;
            end loop;

            while J <= LL loop
               Skip_Spaces (J);
               exit when J > LL;
               declare
                  Tag : constant Character := Line (J);
               begin
                  J := J + 1;
                  Skip_Spaces (J);
                  if J > LL then
                     return;   --  tag with no value
                  end if;
                  declare
                     V0 : constant Natural := J;
                  begin
                     while J <= LL and then Line (J) /= ' ' loop
                        J := J + 1;
                     end loop;
                     if Tag = 'c' then
                        declare
                           V : constant String := Line (V0 .. J - 1);
                        begin
                           if Is_None (V) then
                              Got_C  := True;
                              Is_Tr  := True;
                              Pixval := 0;
                           elsif V'Length = 7
                             and then V (V'First) = '#'
                           then
                              declare
                                 R, G, Bl, T : U64;
                              begin
                                 if not Hex_Digit (V (V'First + 1), R)
                                   or else not Hex_Digit
                                     (V (V'First + 2), T)
                                 then
                                    return;
                                 end if;
                                 R := R * 16 + T;
                                 if not Hex_Digit (V (V'First + 3), G)
                                   or else not Hex_Digit
                                     (V (V'First + 4), T)
                                 then
                                    return;
                                 end if;
                                 G := G * 16 + T;
                                 if not Hex_Digit (V (V'First + 5), Bl)
                                   or else not Hex_Digit
                                     (V (V'First + 6), T)
                                 then
                                    return;
                                 end if;
                                 Bl := Bl * 16 + T;
                                 Pixval := Pixel
                                   (16#FF00_0000# + R * 65536
                                    + G * 256 + Bl);
                                 Got_C := True;
                              end;
                           elsif V'Length = 4
                             and then V (V'First) = '#'
                           then
                              declare
                                 R, G, Bl : U64;
                              begin
                                 if not Hex_Digit (V (V'First + 1), R)
                                   or else not Hex_Digit
                                     (V (V'First + 2), G)
                                   or else not Hex_Digit
                                     (V (V'First + 3), Bl)
                                 then
                                    return;
                                 end if;
                                 Pixval := Pixel
                                   (16#FF00_0000#
                                    + (R * 16 + R) * 65536
                                    + (G * 16 + G) * 256
                                    + (Bl * 16 + Bl));
                                 Got_C := True;
                              end;
                           else
                              return;   --  named colors unsupported
                           end if;
                        end;
                     end if;
                  end;
               end;
            end loop;

            if not Got_C then
               return;
            end if;
            NPal := NPal + 1;
            Key1 (NPal) := K1;
            Key2 (NPal) := K2;
            Val  (NPal) := Pixval;
            if Is_Tr then
               Saw_None := True;
            end if;
         end;
      end loop;

      --  Pixel rows.
      Pix := new Pixel_Data (0 .. U64 (W) * U64 (H) - 1);
      for Y in 0 .. U64 (H) - 1 loop
         Next_Quoted;
         if Eof or else LL < W * Cpp then
            Free_Span (Pix);
            return;   --  truncated pixel block (BAD.XPM)
         end if;
         for X in 0 .. W - 1 loop
            declare
               Found : Boolean;
               Pv    : constant Pixel :=
                 Lookup (X * Cpp + 1, U64 (Cpp), Found);
            begin
               if not Found then
                  Free_Span (Pix);
                  return;   --  pixel key absent from palette
               end if;
               Pix (Y * U64 (W) + U64 (X)) := Pv;
            end;
         end loop;
      end loop;

      Img := (W       => U64 (W), H => U64 (H), Data => Pix,
              Has_Key => Saw_None, Key => 0);
      St := Ok;
   end Decode;

end Trinket.Images.Xpm;
