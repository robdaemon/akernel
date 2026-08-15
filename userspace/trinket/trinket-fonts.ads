--  Trinket fonts (milestone 56): BDF bitmap fonts from disk
--  (Sys:Fonts/*.bdf) with the compiled-in Font8x8 as fallback.
--  Loader subset: 8-bit-wide glyphs, <= 32 rows, encodings
--  32..126 — covers the X11 misc / Terminus 8-pixel family.
--  The rasterizer is this package's only draw op; a freetype
--  backend later slots behind the same API.
package Trinket.Fonts is

   procedure Init (Path : String := "Sys:Fonts/font8x8.bdf");
   --  Tries the BDF at Path; on any failure installs the Font8x8
   --  fallback. Idempotent (second call re-loads).

   function Loaded_From_Disk return Boolean;

   function Line_Height return U64;   --  ascent + descent
   function Text_Width (S : String) return U64;

   procedure Draw_Text
     (C : Canvas; X, Y : U64; S : String; FG : Pixel);
   --  Y is the line top; glyph bitmaps land at their BDF
   --  baseline offsets. Transparent background (caller fills).

end Trinket.Fonts;
