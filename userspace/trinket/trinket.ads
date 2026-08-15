with System;
with Interfaces;
with Akernel_User.Syscalls;

--  Trinket (milestone 56): the opt-in GUI widget library — the
--  MUI-style retained widget tree that renders client-side into
--  Bureau window surfaces. Bureau keeps chrome/focus/routing;
--  Trinket owns everything inside the pane.
--
--  Root package: pixel types, the Workbench-3.x palette (the SAME
--  constants Bureau draws its chrome with, so widget faces match
--  the frame), and the Canvas record every draw op takes.
package Trinket is
   subtype U64 is Akernel_User.Syscalls.U64;
   subtype Pixel is Interfaces.Unsigned_32;  -- AARRGGBB

   --  Palette (userspace/bureau/bureau.adb, same values).
   Face      : constant Pixel := 16#FFC0_C0C4#;  --  gadget face
   Bevel_Hi  : constant Pixel := 16#FFFF_FFFF#;
   Bevel_Lo  : constant Pixel := 16#FF40_4040#;
   Border    : constant Pixel := 16#FF10_1010#;
   Pane      : constant Pixel := 16#FFFF_FFFF#;  --  editable field
   Sel_Blue  : constant Pixel := 16#FF60_68B0#;  --  selection
   Text_Dark : constant Pixel := 16#FF20_2020#;

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
