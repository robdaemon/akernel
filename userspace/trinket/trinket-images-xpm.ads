--  XPM decoder (milestone 64): the text-based X PixMap format
--  (XPM3), the repo-editable counterpart to Bmp — icon sources
--  are plain text files checked into the tree. Subset: quoted-
--  string body ("W H ncolors cpp" header, one color line per
--  entry, one pixel line per row); chars-per-pixel 1 or 2;
--  color specs are "c None" or "c #RRGGBB" / "c #RGB" (named
--  colors are NOT honored — a line with no recognized c-token
--  is Malformed). Pixels keyed "None" decode to pixel value 0
--  (alpha byte 0) and the decoder SETS Has_Key/Key := 0 —
--  unlike BMP (no mask on disk), XPM carries transparency, so
--  the decoded Image is blit-ready without client key setup.
with System;
package Trinket.Images.Xpm is

   function Claims (Buf : System.Address; Len : U64) return Boolean;
   --  True when the bytes start with the "/* XPM */" marker.

   procedure Decode
     (Buf : System.Address; Len : U64;
      Img : out Image; St : out Status);

end Trinket.Images.Xpm;
