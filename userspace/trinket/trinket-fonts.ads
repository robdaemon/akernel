--  Trinket fonts (milestone 56): BDF bitmap fonts from disk
--  (Sys:Fonts/*.bdf) with the compiled-in Font8x8 as fallback.
--  Loader subset: 8-bit-wide glyphs, <= 32 rows, encodings
--  32..126 — covers the X11 misc / Terminus 8-pixel family.
--  The rasterizer is this package's only draw op; a freetype
--  backend later slots behind the same API.
--
--  M86f (proportional): the default UI font is font8x8p.bdf —
--  the same 8x8 glyphs trimmed to their ink bounds with a 1px
--  gap, so Draw_Text/Text_Width advance per-glyph DWIDTH (MUI's
--  XEN-font look; Bureau chrome stays monospace Topaz-style and
--  does not use this package). Grid devices (the terminal) call
--  Draw_Text_Mono: the compiled-in untrimmed 8x8 set on fixed
--  8px cells, pixel-identical to pre-M86f.
package Trinket.Fonts is

   procedure Init (Path : String := "Sys:Fonts/font8x8p.bdf");
   --  Tries the BDF at Path; on any failure installs the Font8x8
   --  fallback. Idempotent (second call re-loads).

   function Loaded_From_Disk return Boolean;

   function Line_Height return U64;   --  ascent + descent
   function Text_Width (S : String) return U64;

   procedure Draw_Text
     (C : Canvas; X, Y : U64; S : String; FG : Pixel);
   --  Y is the line top; glyph bitmaps land at their BDF
   --  baseline offsets. Transparent background (caller fills).

   procedure Draw_Text_Mono
     (C : Canvas; X, Y : U64; S : String; FG : Pixel);
   --  Same contract, but the compiled-in 8x8 glyphs on fixed
   --  8px advances — the terminal's grid.

end Trinket.Fonts;
