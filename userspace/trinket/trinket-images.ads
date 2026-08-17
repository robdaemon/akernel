with System;

--  Trinket images (milestone 63): Amiga datatypes-style pluggable
--  picture decoding. Load sniffs the format and dispatches to a
--  decoder child package (Bmp today; Xpm/ILBM slot in as sibling
--  decoders without touching this API). Decoded pixels are chunky
--  AARRGGBB, same layout as surfaces, so Blit is a clipped span
--  copy into any Canvas.
--
--  Transparency is color-key (Workbench mask lineage): an image
--  with Has_Key skips pixels equal to Key during Blit. Loaders
--  leave Has_Key False — the CLIENT sets the key (BMP carries no
--  mask; 32-bit alpha bytes are preserved but never blended).
package Trinket.Images is

   type Status is (Ok, IO_Error, Unsupported, Malformed);
   --  Unsupported: no decoder claims the bytes. Malformed: a
   --  decoder claimed them and the file failed bounds/consistency
   --  checks. IO_Error: stat/open/read/close failed.

   type Pixel_Data is array (U64 range <>) of Pixel;
   type Pixel_Access is access Pixel_Data;

   type Image is record
      W, H    : U64 := 0;
      Data    : Pixel_Access := null;   -- W * H pixels, row-major
      Has_Key : Boolean := False;
      Key     : Pixel := 0;
   end record;

   function Loaded (Img : Image) return Boolean is (Img.Data /= null);

   procedure Load (Path : String; Img : out Image; St : out Status);
   --  Slurps the file and dispatches on magic bytes. Img.Data is
   --  freshly allocated on success; on failure Img is empty.

   procedure Free (Img : in out Image);

   procedure Blit (C : Canvas; Img : Image; DX, DY : U64);
   --  Copies the image with its top-left pixel at content coords
   --  (DX, DY), intersected with the canvas clip. Color-keyed
   --  images skip Key pixels. No scaling, no blending.

end Trinket.Images;
