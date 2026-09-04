with System;
with Interfaces;
with Akernel_User.Syscalls;
with Akernel_User.Theme;

--  Trinket (milestone 56): the opt-in GUI widget library — the
--  MUI-style retained widget tree that renders client-side into
--  Bureau window surfaces. Bureau keeps chrome/focus/routing;
--  Trinket owns everything inside the pane.
--
--  Root package: pixel types, the palette (renames of
--  Akernel_User.Theme, milestone 86a — one skin shared with
--  Bureau's chrome), and the Canvas record every draw op takes.
package Trinket is
   subtype U64 is Akernel_User.Syscalls.U64;
   subtype Pixel is Interfaces.Unsigned_32;  -- AARRGGBB

   --  Palette (milestone 86a: Akernel_User.Theme, shared with
   --  Bureau; renames keep widget code untouched).
   Face      : Pixel renames Akernel_User.Theme.Face;
   Win_Face  : Pixel renames Akernel_User.Theme.Win_Face;
   Bevel_Hi  : Pixel renames Akernel_User.Theme.Bevel_Hi;
   Bevel_Lo  : Pixel renames Akernel_User.Theme.Bevel_Lo;
   Border    : Pixel renames Akernel_User.Theme.Border;
   Pane      : Pixel renames Akernel_User.Theme.Pane;
   Sel_Blue  : Pixel renames Akernel_User.Theme.Sel_Blue;
   Text_Dark : Pixel renames Akernel_User.Theme.Text_Dark;

   --  Navigation key codes (milestone 57): virtio_input sends
   --  these for keys outside ASCII. Text-only consumers drop
   --  codes >= 16#80#.
   Key_Up       : constant U64 := 16#80#;
   Key_Down     : constant U64 := 16#81#;
   Key_Left     : constant U64 := 16#82#;
   Key_Right    : constant U64 := 16#83#;
   Key_Home     : constant U64 := 16#84#;
   Key_End      : constant U64 := 16#85#;
   Key_Pageup   : constant U64 := 16#86#;
   Key_Pagedown : constant U64 := 16#87#;
   Key_Delete   : constant U64 := 16#88#;

   type Pixel_Array is
     array (U64 range <>) of Pixel with Volatile_Components;

   --  A drawing target: a mapped surface buffer plus a clip rect
   --  (half-open: pixels [CX0, CX1) x [CY0, CY1)). Draw ops
   --  intersect every write with the clip.
   type Canvas is record
      Base          : System.Address := System.Null_Address;
      W, H          : U64 := 0;
      CX0, CY0      : U64 := 0;
      CX1, CY1      : U64 := 0;
   end record;

   procedure Set_Clip
     (C : in out Canvas; X0, Y0, X1, Y1 : U64);
   --  Intersects the canvas clip with the given half-open rect.

   procedure Reset_Clip (C : in out Canvas);

end Trinket;
