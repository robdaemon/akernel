--  BMP decoder (milestone 63): uncompressed BI_RGB, 24-bit and
--  32-bit, bottom-up (positive height) and top-down (negative).
--  32-bit files carry their alpha byte through to the pixel's high
--  byte; 24-bit pixels decode opaque (A = FF). Paletted and
--  compressed variants are Malformed, not Unsupported — the "BM"
--  magic already claimed them.
with System;
package Trinket.Images.Bmp is

   function Claims (Buf : System.Address; Len : U64) return Boolean;
   --  True when the bytes start with the "BM" magic.

   procedure Decode
     (Buf : System.Address; Len : U64;
      Img : out Image; St : out Status);

end Trinket.Images.Bmp;
