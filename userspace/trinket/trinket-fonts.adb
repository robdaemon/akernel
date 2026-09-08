with Ada.Unchecked_Deallocation;
with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;
with System.Storage_Elements;
with Aegir_User.CLI;
with Aegir_User.Files;
with Aegir_User.Syscalls;
with Font8x8;

package body Trinket.Fonts is
   use Interfaces;
   use type Trinket.U64;
   use type System.Address;

   subtype U8 is Interfaces.Unsigned_8;
   subtype U16 is Interfaces.Unsigned_16;

   Max_Rows : constant := 32;

   --  M89: full Terminus BDFs run ~180 KiB at 4.49.1; 5x
   --  headroom. Transient heap read, freed right after parse.
   --  Files.Read answers at most Buf_Bytes per call, so the
   --  read loops (the pre-m89 64 KiB cap was that one-shot
   --  semantics, not a font limit).
   Max_BDF  : constant := 1024 * 1024;

   --  Extended (non-ASCII) coverage reaches box drawing, block
   --  elements and geometric shapes; Terminus ships ~450 glyphs
   --  in that span, so 768 slots leave ~1.7x headroom.
   Max_CP   : constant := 16#25FF#;
   Max_Ext  : constant := 768;

   type Row_Array is array (0 .. Max_Rows - 1) of U8;
   type Glyph_Rec is record
      Valid       : Boolean := False;
      GW, GH      : U64 := 0;      --  BBX width/height
      XOff, YOff  : Integer := 0;  --  BBX offsets (yoff = baseline
                                   --  to glyph bottom)
      DW          : U64 := 8;      --  DWIDTH advance
      Rows        : Row_Array := (others => 0);
   end record;

   type Glyph_Table is array (0 .. 127) of Glyph_Rec;

   type Ext_Rec is record
      CP : U16 := 0;   --  codepoint, 0 = empty slot
      G  : Glyph_Rec;
   end record;
   type Ext_Array is array (1 .. Max_Ext) of Ext_Rec;

   --  M9A TrueType/OpenType: a Ttf_Access hooks a Font_Rec to a
   --  FreeType face. Data (the font file bytes) must outlive the
   --  face, which references it.
   type Str_Access is access String;

   type Bmp_Arr is array (Natural range <>) of Unsigned_8;
   type Bmp_Ptr is access Bmp_Arr;
   procedure Free_Bmp is new Ada.Unchecked_Deallocation
     (Bmp_Arr, Bmp_Ptr);

   --  Per-face glyph raster cache. FreeType's slot bitmap is only
   --  valid until the next FT call, so a cached glyph is a heap
   --  copy; without the cache every repaint of a .TTF string
   --  re-rasterizes each glyph (the font-picker preview lag). A
   --  preview/repaint reuses the same handful of codepoints, so a
   --  round-robin buffer is plenty.
   TTF_Cache_N : constant := 96;
   type TTF_Glyph_Cache is record
      CP           : Integer := -1;
      W, H         : Natural := 0;
      Left, Top    : Integer := 0;
      Pitch        : Natural := 0;
      B            : Bmp_Ptr := null;
   end record;
   type TTF_Cache_Arr is array (0 .. TTF_Cache_N - 1)
     of TTF_Glyph_Cache;

   type TTF_Rec is record
      Face : System.Address := System.Null_Address;
      Data : Str_Access := null;
      Cache : TTF_Cache_Arr := (others => (CP => -1, W => 0, H => 0,
                                           Left => 0, Top => 0,
                                           Pitch => 0, B => null));
      Next  : Natural := 0;   --  round-robin eviction slot
   end record;
   type Ttf_Access is access TTF_Rec;

   type Font_Rec is record
      T         : Glyph_Table;
      Ext       : Ext_Array;
      N_Ext     : Natural := 0;
      Ascent    : U64 := 6;
      Descent   : U64 := 2;
      From_Disk : Boolean := False;
      --  M9A: a non-null Ttf makes this a TrueType/OpenType face
      --  (rasterized by FreeType); the BDF tables above are then
      --  unused. Data holds the font bytes the face references.
      Ttf       : Ttf_Access := null;
   end record;

   procedure Free is new Ada.Unchecked_Deallocation
     (String, Str_Access);
   procedure Free_Font is new Ada.Unchecked_Deallocation
     (Font_Rec, Handle);
   procedure Free_Ttf is new Ada.Unchecked_Deallocation
     (TTF_Rec, Ttf_Access);

   --  M9A FreeType shim bindings (userspace/freetype/port/
   --  ftaegir.c); NULL face = failure, 0 returns = ok.
   subtype CInt is Interfaces.Integer_32;
   type CInt_Ptr is access all CInt;
   type Byte_Array is array (Natural range <>) of Unsigned_8
     with Volatile_Components;
   function FT_Open
     (Data : System.Address; Len : Unsigned_64;
      Px   : Unsigned_32) return System.Address
   with Import, Convention => C, External_Name => "aegir_ft_open";
   procedure FT_Close (V : System.Address)
   with Import, Convention => C, External_Name => "aegir_ft_close";
   function FT_Family (V : System.Address)
     return Interfaces.C.Strings.chars_ptr
   with Import, Convention => C, External_Name => "aegir_ft_family";
   function FT_Ascent (V : System.Address) return CInt
   with Import, Convention => C, External_Name => "aegir_ft_ascent";
   function FT_Descent (V : System.Address) return CInt
   with Import, Convention => C, External_Name => "aegir_ft_descent";
   function FT_Advance (V : System.Address; CP : Unsigned_64)
     return CInt
   with Import, Convention => C, External_Name => "aegir_ft_advance_x";
   function FT_Kern (V : System.Address; L, R : Unsigned_64)
     return CInt
   with Import, Convention => C, External_Name => "aegir_ft_kerning";
   function FT_Has (V : System.Address; CP : Unsigned_64) return CInt
   with Import, Convention => C, External_Name => "aegir_ft_has";
   function FT_Glyph
     (V : System.Address; CP : Unsigned_64;
      Left, Top, W, H, Pitch : CInt_Ptr;
      Bits : access System.Address) return CInt
   with Import, Convention => C, External_Name => "aegir_ft_glyph";
   --  Fixed pixel size for TTF faces this milestone.
   TTF_Px : constant Natural := 16;  --  default face pixel size

   Global      : Font_Rec;         --  the UI font (latched)
   Mono        : Font_Rec;         --  compiled-in 8x8, advance 8
   Mono_Ascent : constant U64 := 6;
   Initialized : Boolean := False;

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

   function Ext_Find (F : Font_Rec; CP : Natural) return Natural is
   begin
      for I in 1 .. F.N_Ext loop
         if F.Ext (I).CP = U16 (CP) then
            return I;
         end if;
      end loop;
      return 0;
   end Ext_Find;

   procedure Install_Mono (T : out Glyph_Table) is
   begin
      T := (others => (Valid => False, GW => 0, GH => 0,
                       XOff => 0, YOff => 0, DW => 8,
                       Rows => (others => 0)));
      for Ch in Character range ' ' .. '~' loop
         declare
            G : Glyph_Rec renames T (Character'Pos (Ch));
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
   end Install_Mono;

   procedure Parse_BDF (Buf : String; F : in out Font_Rec) is
      I        : Natural := Buf'First;
      Line_End : Natural;
      Cur      : Integer := -1;     --  current glyph encoding
      Cur_Ext  : Natural := 0;      --  sparse slot for Cur, 0 none
      In_Glyph : Boolean := False;
      In_Bits  : Boolean := False;
      Skip     : Boolean := False;  --  glyph too wide/tall: drop
      Row      : Natural := 0;
   begin
      F := (T         => (others => (Valid => False, GW => 0,
                                     GH => 0, XOff => 0, YOff => 0,
                                     DW => 8, Rows => (others => 0))),
            Ext       => (others => (CP => 0,
                                     G => (Valid => False, GW => 0,
                                           GH => 0, XOff => 0,
                                           YOff => 0, DW => 8,
                                           Rows => (others => 0)))),
            N_Ext     => 0,
            Ascent    => 6,
            Descent   => 2,
            From_Disk => False,
            Ttf       => null);
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
               elsif Row < Max_Rows and then L'Length >= 2
                 and then not Skip
               then
                  if Cur >= 32 and then Cur <= 126 then
                     F.T (Cur).Rows (Row) := Hex_Byte (L, L'First);
                  elsif Cur_Ext /= 0 then
                     F.Ext (Cur_Ext).G.Rows (Row) :=
                       Hex_Byte (L, L'First);
                  end if;
                  Row := Row + 1;
               end if;
            elsif L'Length >= 9
              and then L (L'First .. L'First + 8) = "STARTCHAR"
            then
               In_Glyph := True;
               Cur := -1;
               Cur_Ext := 0;
               Skip := False;
            elsif In_Glyph and then L'Length >= 9
              and then L (L'First .. L'First + 8) = "ENCODING "
            then
               Cur := Integer'Value (L (L'First + 9 .. L'Last));
               if Cur >= 32 and then Cur <= 126 then
                  F.T (Cur).Valid := True;
               elsif Cur > 126 and then Cur <= Max_CP
                 and then F.N_Ext < Max_Ext
               then
                  F.N_Ext := F.N_Ext + 1;
                  F.Ext (F.N_Ext).CP := U16 (Cur);
                  F.Ext (F.N_Ext).G.Valid := True;
                  Cur_Ext := F.N_Ext;
               end if;
            elsif In_Glyph and then L'Length >= 7
              and then L (L'First .. L'First + 6) = "DWIDTH "
              and then not Skip
            then
               declare
                  Sp : Natural := L'First + 7;
               begin
                  while Sp <= L'Last and then L (Sp) /= ' ' loop
                     Sp := Sp + 1;
                  end loop;
                  if Cur >= 32 and then Cur <= 126 then
                     F.T (Cur).DW :=
                       U64'Value (L (L'First + 7 .. Sp - 1));
                  elsif Cur_Ext /= 0 then
                     F.Ext (Cur_Ext).G.DW :=
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
                  --  Rows are one hex byte: wider-than-8 glyphs
                  --  can't be stored; taller-than-Max_Rows would
                  --  lose their tail. Drop either.
                  if V (0) > 8 or else V (1) > Max_Rows then
                     Skip := True;
                     if Cur >= 32 and then Cur <= 126 then
                        F.T (Cur).Valid := False;
                     elsif Cur_Ext /= 0 then
                        F.Ext (Cur_Ext).CP := 0;
                        F.Ext (Cur_Ext).G.Valid := False;
                        F.N_Ext := F.N_Ext - 1;
                        Cur_Ext := 0;
                     end if;
                  elsif Cur >= 32 and then Cur <= 126 then
                     F.T (Cur).GW := U64 (V (0));
                     F.T (Cur).GH := U64 (V (1));
                     F.T (Cur).XOff := V (2);
                     F.T (Cur).YOff := V (3);
                  elsif Cur_Ext /= 0 then
                     F.Ext (Cur_Ext).G.GW := U64 (V (0));
                     F.Ext (Cur_Ext).G.GH := U64 (V (1));
                     F.Ext (Cur_Ext).G.XOff := V (2);
                     F.Ext (Cur_Ext).G.YOff := V (3);
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
               F.Ascent := U64'Value (L (L'First + 12 .. L'Last));
            elsif L'Length >= 13
              and then L (L'First .. L'First + 12) = "FONT_DESCENT "
            then
               F.Descent := U64'Value (L (L'First + 13 .. L'Last));
            end if;
         end;
         I := Line_End + 1;
      end loop;
   end Parse_BDF;

   --  Raw Files ops need the fs endpoint bound; the binding is
   --  lazy (gloss Ensure_Bound) so a program whose FIRST fs
   --  touch is a raw Files.Open (this package, pre-m89 silent
   --  fallback) must bind first. Never clobber a program's own
   --  binding (fuzz keeps fs on handle 4).
   procedure Ensure_FS is
   begin
      if Aegir_User.Files.Endpoint = 0 then
         Aegir_User.Files.Bind (2);   --  handle 2 = fs Send
      end if;
   end Ensure_FS;

   --  M9A: TrueType/OpenType detection (".ttf"/".otf", case-
   --  insensitive) — Init/Load/Probe branch on it.
   function Has_TTF_Suffix (Path : String) return Boolean is
      L : constant Natural := Path'Length;
   begin
      if L >= 4 then
         declare
            P : constant Natural := Path'Last - 3;
         begin
            return Path (P) = '.'
              and then (Path (P + 1) in 'T' | 't')
              and then (Path (P + 2) in 'T' | 't')
              and then (Path (P + 3) in 'F' | 'f'
                        or else Path (P + 3) in 'O' | 'o');
         end;
      end if;
      return False;
   end Has_TTF_Suffix;

   --  Read a whole file into a heap string (null on any failure).
   function Read_All (Path : String) return Str_Access is
      use Aegir_User;
      use System.Storage_Elements;
      Max   : constant U64 := 16 * 1024 * 1024;
      Size  : U64;
      Count : U64;
      Pos   : U64 := 0;
      St    : U64;
      Buf   : Str_Access := null;
   begin
      Ensure_FS;
      St := Files.Open (Path, Size);
      if St = Files.Status_Ok and then Size > 0
        and then Size <= Max
      then
         Buf := new String (1 .. Natural (Size));
         while Pos < Size loop
            St := Files.Read
              (Path, Pos,
               Buf.all'Address + Storage_Offset (Pos),
               Size - Pos, Count);
            exit when St /= Files.Status_Ok or else Count = 0;
            Pos := Pos + Count;
         end loop;
         if Pos /= Size then
            Free (Buf);
            Buf := null;
         end if;
         St := Files.Close (Path);
      end if;
      return Buf;
   end Read_All;

   --  Open the font bytes as a FreeType face at the fixed pixel
   --  size; F.Ascent/Descent take the face metrics.
   procedure Try_Load_TTF (Path : String; F : out Font_Rec;
                           OK : out Boolean; Px : Natural) is
      Buf : Str_Access;
      Sz  : constant Natural :=
        (if Px < 8 then 8 elsif Px > 72 then 72 else Px);
   begin
      OK := False;
      F.Ttf := null;
      Buf := Read_All (Path);
      if Buf = null then
         return;
      end if;
      declare
         Face : constant System.Address :=
           FT_Open (Buf.all'Address,
                    Unsigned_64 (Buf.all'Length),
                    Unsigned_32 (Sz));
      begin
         if Face = System.Null_Address then
            Free (Buf);
            return;
         end if;
         F.Ttf := new TTF_Rec'
           (Face  => Face,
            Data  => Buf,
            Cache => (others => (CP => -1, W => 0, H => 0,
                                 Left => 0, Top => 0,
                                 Pitch => 0, B => null)),
            Next  => 0);
         F.Ascent := U64 (FT_Ascent (Face));
         F.Descent := U64 (FT_Descent (Face));
         F.From_Disk := True;
         OK := True;
      end;
   end Try_Load_TTF;

   --  Shared open/read/parse for Init (global font) and Load
   --  (private instances); a transient heap read. .TTF/.OTF
   --  routes to the FreeType path at Px pixels, everything else
   --  is BDF.
   procedure Try_Load (Path : String; F : out Font_Rec;
                       OK : out Boolean; Px : Natural := TTF_Px) is
      Buf : Str_Access;
   begin
      OK := False;
      if Has_TTF_Suffix (Path) then
         Try_Load_TTF (Path, F, OK, Px);
         return;
      end if;
      Buf := Read_All (Path);
      if Buf = null then
         return;
      end if;
      if Buf.all'Length <= Max_BDF then
         Parse_BDF (Buf.all, F);
         F.From_Disk := True;
         OK := True;
      end if;
      Free (Buf);
   end Try_Load;

   --  ENV:Font.Size (pixels) for a .TTF/.OTF global font; any
   --  malformed value falls back to Default.
   function Env_Size (Default : Natural) return Natural is
      V : constant String := Aegir_User.CLI.Get_Env ("Font.Size");
      N : Natural := 0;
   begin
      if V'Length = 0 then
         return Default;
      end if;
      for C of V loop
         if C not in '0' .. '9' or else N > 1000 then
            return Default;
         end if;
         N := N * 10 + (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      if N = 0 then
         return Default;
      end if;
      return N;
   end Env_Size;

   procedure Init (Path : String := "Sys:Fonts/font8x8p.bdf";
                   Pixel_Size : Natural := 16) is
      OK : Boolean;
   begin
      --  Idempotent (milestone 68): the glyph cache is
      --  library-global; loading once keeps later Init calls
      --  (and any concurrent callers) from racing a re-parse.
      if Initialized then
         return;
      end if;
      Initialized := True;
      Install_Mono (Mono.T);
      Mono.Ascent := Mono_Ascent;
      Mono.Descent := 2;
      --  M89: the prefs pick overrides the compiled-in default.
      declare
         Env  : constant String := Aegir_User.CLI.Get_Env ("Font");
         Size : constant Natural := Env_Size (Pixel_Size);
      begin
         if Env'Length > 0 then
            Try_Load (Env, Global, OK, Size);
         else
            Try_Load (Path, Global, OK, Pixel_Size);
         end if;
      end;
      if not OK then
         Global := Mono;
      end if;
   end Init;

   function Loaded_From_Disk return Boolean is (Global.From_Disk);

   function Line_Height return U64 is (Global.Ascent + Global.Descent);

   ------------------------------------------------------------------
   --  M9A TrueType drawing (FreeType grayscale rasters, alpha-
   --  blended over the background; BDF stays 1-bit).

   function Chan (V : Pixel; Shift : Natural) return Natural is
     (Natural (Interfaces.Shift_Right (V, Shift) and 16#FF#));

   --  Blend FG over the pixel at Pix (I) with coverage A (0..255);
   --  the result is opaque.
   procedure Blend_Pixel
     (Pix : in out Pixel_Array; I : U64; FG : Pixel; A : Natural)
   is
      Inv : constant Natural := 255 - A;
      R   : constant Natural :=
        (Chan (FG, 16) * A + Chan (Pix (I), 16) * Inv + 127) / 255;
      G   : constant Natural :=
        (Chan (FG, 8) * A + Chan (Pix (I), 8) * Inv + 127) / 255;
      B   : constant Natural :=
        (Chan (FG, 0) * A + Chan (Pix (I), 0) * Inv + 127) / 255;
   begin
      Pix (I) := 16#FF00_0000#
        or Pixel (R) * 2**16 or Pixel (G) * 2**8 or Pixel (B);
   end Blend_Pixel;

   --  Blend one grayscale bitmap at pen (X, Y); F.Ascent places
   --  the baseline. No-op for a null/short bitmap.
   procedure Blend_Bmp
     (C : Canvas; F : Font_Rec; X, Y : U64; FG : Pixel;
      Left, Top, W, H, Pitch : Integer; Bits : System.Address)
   is
      Pix : Pixel_Array (0 .. C.W * C.H - 1)
        with Address => C.Base;
   begin
      if Bits = System.Null_Address or else Pitch <= 0
        or else W <= 0 or else H <= 0
      then
         return;
      end if;
      declare
         Bytes : Byte_Array (0 .. Pitch * H - 1)
           with Address => Bits;
         GX : constant Integer := Integer (X) + Left;
         GY : constant Integer := Integer (Y) + Integer (F.Ascent)
           - Top;
      begin
         for R in 0 .. H - 1 loop
            for Col in 0 .. W - 1 loop
               if Col < Pitch then
                  declare
                     A  : constant Natural :=
                       Natural (Bytes (R * Pitch + Col));
                     PX : constant Integer := GX + Col;
                     PY : constant Integer := GY + R;
                  begin
                     if A > 0
                       and then PX >= Integer (C.CX0)
                       and then PX < Integer (C.CX1)
                       and then PY >= Integer (C.CY0)
                       and then PY < Integer (C.CY1)
                       and then PX >= 0 and then PX < Integer (C.W)
                       and then PY >= 0 and then PY < Integer (C.H)
                     then
                        Blend_Pixel
                          (Pix, U64 (PY) * C.W + U64 (PX), FG, A);
                     end if;
                  end;
               end if;
            end loop;
         end loop;
      end;
   end Blend_Bmp;

   --  Draw codepoint CP at pen (X, Y), line top Y. The per-face
   --  raster cache serves repeat draws (repaints) without
   --  re-rasterizing; a miss renders, stores a bitmap copy, and
   --  draws it.
   procedure Draw_TTF_CP
     (C : Canvas; F : in out Font_Rec; CP : Natural;
      X, Y : U64; FG : Pixel)
   is
      Left, Top, W, H, Pitch : aliased CInt := 0;
      Bits : aliased System.Address := System.Null_Address;
   begin
      if F.Ttf = null then
         return;
      end if;
      for I in F.Ttf.Cache'Range loop
         if F.Ttf.Cache (I).CP = CP then
            declare
               E : TTF_Glyph_Cache renames F.Ttf.Cache (I);
            begin
               Blend_Bmp
                 (C, F, X, Y, FG, E.Left, E.Top, Integer (E.W),
                  Integer (E.H), Integer (E.Pitch),
                  (if E.B = null then System.Null_Address
                   else E.B.all'Address));
            end;
            return;
         end if;
      end loop;
      if FT_Glyph (F.Ttf.Face, Unsigned_64 (CP),
                   Left'Unrestricted_Access, Top'Unrestricted_Access,
                   W'Unrestricted_Access, H'Unrestricted_Access,
                   Pitch'Unrestricted_Access,
                   Bits'Unrestricted_Access) /= 0
      then
         return;   --  no glyph for this codepoint
      end if;
      if Pitch > 0 and then Bits /= System.Null_Address
        and then Natural (Pitch) * Natural (H) <= 32 * 1024
      then
         declare
            E : TTF_Glyph_Cache renames F.Ttf.Cache (F.Ttf.Next);
            N : constant Natural := Natural (Pitch) * Natural (H);
            Bytes : Byte_Array (0 .. N - 1)
              with Address => Bits;
         begin
            F.Ttf.Next := (F.Ttf.Next + 1) mod TTF_Cache_N;
            Free_Bmp (E.B);
            E.B := new Bmp_Arr (0 .. N - 1);
            E.B.all := Bmp_Arr (Bytes);
            E.CP := CP;
            E.W := Natural (W);
            E.H := Natural (H);
            E.Left := Integer (Left);
            E.Top := Integer (Top);
            E.Pitch := Natural (Pitch);
            Blend_Bmp
              (C, F, X, Y, FG, E.Left, E.Top, Integer (E.W),
               Integer (E.H), Integer (E.Pitch), E.B.all'Address);
         end;
         return;
      end if;
      --  Oversized bitmap: draw straight from the transient slot.
      Blend_Bmp
        (C, F, X, Y, FG, Integer (Left), Integer (Top),
         Integer (W), Integer (H), Integer (Pitch), Bits);
   end Draw_TTF_CP;

   --  Map a codepoint for rendering: the face's own glyph when it
   --  has one, else a visible replacement ('?' or U+FFFD when the
   --  face has either) so a missing character never draws blank;
   --  0 = nothing renderable at all.
   function TTF_Use (F : Font_Rec; CP : Natural) return Natural is
   begin
      if F.Ttf = null then
         return CP;
      end if;
      if FT_Has (F.Ttf.Face, Unsigned_64 (CP)) /= 0 then
         return CP;
      end if;
      if FT_Has (F.Ttf.Face, Unsigned_64 (63)) /= 0 then
         return 63;
      elsif FT_Has (F.Ttf.Face, Unsigned_64 (16#FFFD#)) /= 0 then
         return 16#FFFD#;
      end if;
      return 0;
   end TTF_Use;

   procedure Draw_TTF_From
     (C : Canvas; X, Y : U64; S : String; FG : Pixel;
      F : in out Font_Rec)
   is
      Pen  : Integer := Integer (X);
      Prev : Integer := -1;
   begin
      if F.Ttf /= null then
         for Ch of S loop
            declare
               U : constant Natural :=
                 TTF_Use (F, Character'Pos (Ch));
            begin
               if U /= 0 then
                  --  Pair kerning with the previous glyph tightens
                  --  the gap (e.g. "AV") before this one draws.
                  if Prev >= 0 then
                     Pen := Pen
                       + Integer (FT_Kern (F.Ttf.Face,
                                           Unsigned_64 (Prev),
                                           Unsigned_64 (U)));
                  end if;
                  Draw_TTF_CP (C, F, U, U64 (Pen), Y, FG);
                  Pen := Pen
                    + Integer (FT_Advance (F.Ttf.Face,
                                           Unsigned_64 (U)));
                  Prev := U;
               end if;
            end;
         end loop;
      end if;
   end Draw_TTF_From;

   function Width_TTF (S : String; F : Font_Rec) return U64 is
      Tot  : Integer := 0;
      Prev : Integer := -1;
   begin
      if F.Ttf /= null then
         for Ch of S loop
            declare
               U : constant Natural := TTF_Use (F, Character'Pos (Ch));
            begin
               if U /= 0 then
                  if Prev >= 0 then
                     Tot := Tot
                       + Integer (FT_Kern (F.Ttf.Face,
                                           Unsigned_64 (Prev),
                                           Unsigned_64 (U)));
                  end if;
                  Tot := Tot
                    + Integer (FT_Advance (F.Ttf.Face,
                                           Unsigned_64 (U)));
                  Prev := U;
               end if;
            end;
         end loop;
      end if;
      return (if Tot > 0 then U64 (Tot) else 0);
   end Width_TTF;

   function Present_TTF (F : Font_Rec; CP : Natural) return Boolean is
     (F.Ttf /= null and then TTF_Use (F, CP) /= 0);

   procedure Draw_One
     (C : Canvas; G : Glyph_Rec; Pen : Integer; Baseline : Integer;
      FG : Pixel)
   is
      Pix : Pixel_Array (0 .. C.W * C.H - 1)
        with Address => C.Base;
      GY  : constant Integer := Baseline - G.YOff - Integer (G.GH);
   begin
      for R in 0 .. Integer (G.GH) - 1 loop
         if R < Max_Rows then
            for Col in 0 .. Integer (G.GW) - 1 loop
               if Col < 8
                 and then (G.Rows (R) and
                   Shift_Left (U8'(1), 7 - Col)) /= 0
               then
                  declare
                     PX : constant U64 := U64 (Pen + G.XOff + Col);
                     PY : constant U64 := U64 (GY + R);
                  begin
                     if PX >= C.CX0 and then PX < C.CX1
                       and then PY >= C.CY0 and then PY < C.CY1
                       and then PX < C.W and then PY < C.H
                     then
                        Pix (PY * C.W + PX) := FG;
                     end if;
                  end;
               end if;
            end loop;
         end if;
      end loop;
   end Draw_One;

   procedure Draw_From
     (C : Canvas; X, Y : U64; S : String; FG : Pixel;
      F : in out Font_Rec)
   is
      Baseline : constant Integer := Integer (Y) + Integer (F.Ascent);
      Pen      : Integer := Integer (X);
      E        : Natural;
   begin
      if F.Ttf /= null then
         Draw_TTF_From (C, X, Y, S, FG, F);
         return;
      end if;
      for Ch of S loop
         declare
            Code : constant Natural := Character'Pos (Ch);
         begin
            if Code <= 127 and then F.T (Code).Valid then
               Draw_One (C, F.T (Code), Pen, Baseline, FG);
               Pen := Pen + Integer (F.T (Code).DW);
            else
               E := Ext_Find (F, Code);
               if E /= 0 then
                  Draw_One (C, F.Ext (E).G, Pen, Baseline, FG);
                  Pen := Pen + Integer (F.Ext (E).G.DW);
               else
                  Pen := Pen + 8;
               end if;
            end if;
         end;
      end loop;
   end Draw_From;

   function Width_From (S : String; F : Font_Rec) return U64 is
      W : U64 := 0;
      E : Natural;
   begin
      if F.Ttf /= null then
         return Width_TTF (S, F);
      end if;
      for Ch of S loop
         declare
            Code : constant Natural := Character'Pos (Ch);
         begin
            if Code <= 127 and then F.T (Code).Valid then
               W := W + F.T (Code).DW;
            else
               E := Ext_Find (F, Code);
               if E /= 0 then
                  W := W + F.Ext (E).G.DW;
               else
                  W := W + 8;
               end if;
            end if;
         end;
      end loop;
      return W;
   end Width_From;

   procedure Draw_CP
     (C : Canvas; CP : Natural; X, Y : U64; FG : Pixel;
      F : in out Font_Rec)
   is
      Baseline : constant Integer := Integer (Y) + Integer (F.Ascent);
      E        : Natural;
   begin
      if F.Ttf /= null then
         declare
            U : constant Natural := TTF_Use (F, CP);
         begin
            if U /= 0 then
               Draw_TTF_CP (C, F, U, X, Y, FG);
            end if;
         end;
         return;
      end if;
      if CP <= 127 and then F.T (CP).Valid then
         Draw_One (C, F.T (CP), Integer (X), Baseline, FG);
      else
         E := Ext_Find (F, CP);
         if E /= 0 then
            Draw_One (C, F.Ext (E).G, Integer (X), Baseline, FG);
         end if;
      end if;
   end Draw_CP;

   function Present (F : Font_Rec; CP : Natural) return Boolean is
   begin
      if F.Ttf /= null then
         return Present_TTF (F, CP);
      end if;
      return (CP <= 127 and then F.T (CP).Valid)
        or else (CP > 127 and then Ext_Find (F, CP) /= 0);
   end Present;

   function Text_Width (S : String) return U64 is
     (Width_From (S, Global));

   procedure Draw_Text
     (C : Canvas; X, Y : U64; S : String; FG : Pixel)
   is
   begin
      Draw_From (C, X, Y, S, FG, Global);
   end Draw_Text;

   procedure Draw_Text_Mono
     (C : Canvas; X, Y : U64; S : String; FG : Pixel)
   is
   begin
      Draw_From (C, X, Y, S, FG, Mono);
   end Draw_Text_Mono;

   function Has_Glyph (CP : Natural) return Boolean is
     (Present (Global, CP));

   procedure Draw_Glyph
     (C : Canvas; CP : Natural; X, Y : U64; FG : Pixel)
   is
   begin
      Draw_CP (C, CP, X, Y, FG, Global);
   end Draw_Glyph;

   --  M89: private instances.

   function Load (Path : String; Pixel_Size : Natural := 16)
     return Handle is
      H  : Handle := new Font_Rec;
      OK : Boolean;
   begin
      Try_Load (Path, H.all, OK, Pixel_Size);
      if not OK then
         Free_Font (H);
         return null;
      end if;
      return H;
   end Load;

   procedure Unload (H : in out Handle) is
   begin
      if H /= null and then H.Ttf /= null then
         for I in H.Ttf.Cache'Range loop
            Free_Bmp (H.Ttf.Cache (I).B);
         end loop;
         FT_Close (H.Ttf.Face);
         Free (H.Ttf.Data);
         Free_Ttf (H.Ttf);
      end if;
      Free_Font (H);
   end Unload;

   function Line_Height (H : Handle) return U64 is
     (if H = null then 8 else H.Ascent + H.Descent);

   function Text_Width (H : Handle; S : String) return U64 is
     (if H = null then 0 else Width_From (S, H.all));

   function Has_Glyph (H : Handle; CP : Natural) return Boolean is
     (H /= null and then Present (H.all, CP));

   procedure Draw_Text
     (C : Canvas; H : Handle; X, Y : U64; S : String; FG : Pixel)
   is
   begin
      if H /= null then
         Draw_From (C, X, Y, S, FG, H.all);
      end if;
   end Draw_Text;

   procedure Draw_Glyph
     (C : Canvas; H : Handle; CP : Natural; X, Y : U64;
      FG : Pixel)
   is
   begin
      if H /= null then
         Draw_CP (C, CP, X, Y, FG, H.all);
      end if;
   end Draw_Glyph;

   procedure Probe
     (Path        : String;
      Family      : out String;
      Family_Len  : out Natural;
      Pixel_Size  : out Natural;
      OK          : out Boolean)
   is
      use Aegir_User;
      Size  : U64;
      Count : U64;
      St    : U64;
   begin
      OK := False;
      Family_Len := 0;
      Pixel_Size := 0;
      Ensure_FS;
      if Has_TTF_Suffix (Path) then
         --  M9A: family comes from the face's PostScript name.
         declare
            Buf : Str_Access := Read_All (Path);
         begin
            if Buf /= null then
               declare
                  Px   : constant Unsigned_32 := Unsigned_32 (TTF_Px);
                  Face : constant System.Address :=
                    FT_Open (Buf.all'Address,
                             Unsigned_64 (Buf.all'Length), Px);
               begin
                  if Face /= System.Null_Address then
                     declare
                        use Interfaces.C.Strings;
                        Nm : constant String :=
                          Value (FT_Family (Face));
                     begin
                        Family_Len :=
                          Natural'Min (Nm'Length, Max_Family);
                        Family_Len :=
                          Natural'Min (Family_Len, Family'Length);
                        if Family_Len > 0 then
                           Family (Family'First ..
                                   Family'First + Family_Len - 1) :=
                             Nm (Nm'First .. Nm'First + Family_Len - 1);
                        end if;
                     end;
                     Pixel_Size := TTF_Px;
                     OK := True;
                     FT_Close (Face);
                  end if;
               end;
               Free (Buf);
            end if;
         end;
         return;
      end if;
      St := Files.Open (Path, Size);
      if St /= Files.Status_Ok or else Size = 0 then
         return;
      end if;
      declare
         --  FAMILY_NAME/PIXEL_SIZE sit in the header property
         --  block; 4 KiB covers every BDF we ship.
         N   : constant Natural :=
           Natural (U64'Min (Size, 4096));
         Buf : Str_Access := new String (1 .. N);
         I        : Natural;
         Line_End : Natural;
      begin
         St := Files.Read (Path, 0, Buf.all'Address, U64 (N), Count);
         if St = Files.Status_Ok and then Count = U64 (N) then
            I := Buf'First;
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
                  if L'Length >= 13
                    and then L (L'First .. L'First + 11) = "FAMILY_NAME "
                    and then L (L'First + 12) = '"'
                  then
                     declare
                        Q : Natural := L'First + 13;
                     begin
                        while Q <= L'Last and then L (Q) /= '"' loop
                           Q := Q + 1;
                        end loop;
                        Family_Len :=
                          Natural'Min
                            (Q - (L'First + 13),
                             Natural'Min (Family'Length, Max_Family));
                        Family (Family'First ..
                                Family'First + Family_Len - 1) :=
                          L (L'First + 13 ..
                             L'First + 13 + Family_Len - 1);
                     end;
                  elsif L'Length >= 12
                    and then L (L'First .. L'First + 10) = "PIXEL_SIZE "
                  then
                     Pixel_Size :=
                       Natural'Value (L (L'First + 11 .. L'Last));
                  end if;
               end;
               exit when Family_Len > 0 and then Pixel_Size > 0;
               I := Line_End + 1;
            end loop;
            OK := Family_Len > 0 and then Pixel_Size > 0;
         end if;
         Free (Buf);
         St := Files.Close (Path);
      end;
   end Probe;

end Trinket.Fonts;
