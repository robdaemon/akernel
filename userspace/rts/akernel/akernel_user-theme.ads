--  Single source of truth for the GUI palette (milestone 86a).
--  Bureau draws chrome (frames, title bars, menus, screen bar,
--  desktop, cursor) and Trinket widgets draw pane interiors, but
--  a window must read as ONE skin — so both sides reference these
--  constants instead of keeping hand-synced duplicate blocks
--  (which had already drifted once: Pane was #F8F8F8 in Bureau,
--  #FFFFFF in Trinket; Bureau's copy only filled the transient
--  blank of a not-yet-mapped window, so unifying on #FFFFFF is
--  visually nil).
--
--  Pure constants, no dependencies, opt-in: the package lands in
--  a binary only when that program withs it (Bureau and Trinket
--  do; drivers and CLI commands never will).  Same pattern as
--  Font8x8: a userspace-wide resource living in the shared RTS
--  rather than inside the client toolkit, because the compositor
--  must not depend on Trinket.
--
--  Pixel format: AARRGGBB.  (B8G8R8A8 little-endian scanout means
--  the u32 low byte is BLUE — the format name's channel order is
--  memory byte order.  Decode PPM/PNG bytes straight as R,G,B.)

with Interfaces;

package Akernel_User.Theme is

   subtype Pixel is Interfaces.Unsigned_32;  --  AARRGGBB

   --  Shared widget/chrome colors (Workbench-3.x values for now;
   --  M86b re-skins to the MUI Xen palette).
   Face      : constant Pixel := 16#FFC0_C0C4#;  --  gadget face
   Bevel_Hi  : constant Pixel := 16#FFFF_FFFF#;
   Bevel_Lo  : constant Pixel := 16#FF40_4040#;
   Border    : constant Pixel := 16#FF10_1010#;
   Pane      : constant Pixel := 16#FFFF_FFFF#;  --  editable field
   Sel_Blue  : constant Pixel := 16#FF60_68B0#;  --  selection
   Text_Dark : constant Pixel := 16#FF20_2020#;

   --  Bureau chrome.
   Desktop    : constant Pixel := 16#FFA0_A0A4#;
   Bar_Face   : constant Pixel := Face;   --  screen bar / menus
   Win_Face   : constant Pixel := Face;   --  window frame fill
   Title_Blue : constant Pixel := Sel_Blue;  --  focused title bar
   Title_Gray : constant Pixel := 16#FF8C_8C90#;  --  unfocused
   Title_Text : constant Pixel := 16#FFFF_FFFF#;
   Title_Dim  : constant Pixel := Text_Dark;

   --  Software cursor.
   Cur_Outline : constant Pixel := Border;
   Cur_Fill    : constant Pixel := 16#FFFF_FFFF#;

end Akernel_User.Theme;
