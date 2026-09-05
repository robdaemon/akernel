--  Trinket fonts (milestone 56): BDF bitmap fonts from disk
--  (Sys:Fonts/*.bdf) with the compiled-in Font8x8 as fallback.
--  Loader subset: 8-bit-wide glyphs, <= 32 rows — covers the
--  X11 misc / Terminus 8-pixel family. Encodings reach 16#25FF#
--  (Latin-1, box drawing, block elements, geometric shapes) via
--  a sparse extension table, so shipped Terminus BDFs keep
--  their line-drawing glyphs. The rasterizer is this package's
--  only draw op; a freetype backend later slots behind the
--  same API.
--
--  M86f (proportional): the default UI font is font8x8p.bdf —
--  the same 8x8 glyphs trimmed to their ink bounds with a 1px
--  gap, so Draw_Text/Text_Width advance per-glyph DWIDTH (MUI's
--  XEN-font look; Bureau chrome stays monospace Topaz-style and
--  does not use this package). Grid devices (the terminal) call
--  Draw_Text_Mono: the compiled-in untrimmed 8x8 set on fixed
--  8px cells, pixel-identical to pre-M86f.
--
--  M89 (prefs): ENV:Font overrides the default path at Init, so
--  Prefs/Font's choice applies to every app launched after the
--  save (the global font latches at first Init — running apps
--  keep theirs). Load/Unload give callers private font
--  instances off the heap (the picker's live preview) without
--  disturbing the global font; Probe reads just the BDF header
--  properties (FAMILY_NAME/PIXEL_SIZE) for grouping listings.
package Trinket.Fonts is

   procedure Init (Path : String := "Sys:Fonts/font8x8p.bdf");
   --  Tries ENV:Font first, then the BDF at Path; on any
   --  failure installs the Font8x8 fallback. Idempotent (the
   --  first call latches the global font).

   function Loaded_From_Disk return Boolean;

   function Line_Height return U64;   --  ascent + descent
   function Text_Width (S : String) return U64;

   procedure Draw_Text
     (C : Canvas; X, Y : U64; S : String; FG : Pixel);
   --  Y is the line top; glyph bitmaps land at their BDF
   --  baseline offsets. Transparent background (caller fills).
   --  Bytes 16#A0#..16#FF# map straight to Latin-1 codepoints.

   procedure Draw_Text_Mono
     (C : Canvas; X, Y : U64; S : String; FG : Pixel);
   --  Same contract, but the compiled-in 8x8 glyphs on fixed
   --  8px advances — the terminal's grid.

   --  M89: codepoint-level access for the extended glyph
   --  ranges (box drawing et al. — the terminal's codepage
   --  wiring is a separate milestone).
   function Has_Glyph (CP : Natural) return Boolean;
   procedure Draw_Glyph
     (C : Canvas; CP : Natural; X, Y : U64; FG : Pixel);

   --  M89: private font instances (Prefs/Font preview).
   type Handle is private;
   Null_Handle : constant Handle;

   function Load (Path : String) return Handle;
   --  Parses the BDF at Path into a heap instance; returns
   --  Null_Handle on any failure.
   procedure Unload (H : in out Handle);

   function Line_Height (H : Handle) return U64;
   function Text_Width (H : Handle; S : String) return U64;
   function Has_Glyph (H : Handle; CP : Natural) return Boolean;
   procedure Draw_Text
     (C : Canvas; H : Handle; X, Y : U64; S : String; FG : Pixel);
   procedure Draw_Glyph
     (C : Canvas; H : Handle; CP : Natural; X, Y : U64;
      FG : Pixel);

   Max_Family : constant := 32;  --  BDF FAMILY_NAME cap
   procedure Probe
     (Path        : String;
      Family      : out String;
      Family_Len  : out Natural;
      Pixel_Size  : out Natural;
      OK          : out Boolean);
   --  Header-only read (FAMILY_NAME + PIXEL_SIZE); never
   --  touches the global font. Family is filled up to
   --  Max_Family chars; Family_Len reports the actual length.

private

   type Font_Rec;
   type Handle is access Font_Rec;
   Null_Handle : constant Handle := null;

end Trinket.Fonts;
