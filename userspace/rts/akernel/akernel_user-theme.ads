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

   --  MUI Xen palette (milestone 86b; decoded from sasg.com's
   --  preview.gif and the MUI 3.8 Presets/XEN.prefs pens — BGR
   --  hex strings — plus the XEN/Plain brush palettes):
   --  steel blue #3B67A2 chrome, mid gray #959595 window face,
   --  light gray #AFAFAF gadgets and fields, soft #7B7B7B
   --  shadows.  Face is the GADGET face; Win_Face the window
   --  background behind the widgets (Trinket fills pane bands
   --  with it) — Xen gadgets sit a shade lighter than the
   --  window, the inverse of the old Workbench flat gray.
   Face      : constant Pixel := 16#FFAF_AFAF#;  --  gadget face
   Face_Hi   : constant Pixel := 16#FFCF_CFCF#;  --  hover (M86c)
   Bevel_Hi  : constant Pixel := 16#FFFF_FFFF#;
   Bevel_Lo  : constant Pixel := 16#FF7B_7B7B#;
   Border    : constant Pixel := 16#FF10_1010#;
   Pane      : constant Pixel := 16#FFAF_AFAF#;  --  editable field
   Sel_Blue  : constant Pixel := 16#FF3B_67A2#;  --  selection
   Text_Dark : constant Pixel := 16#FF20_2020#;

   --  Bureau chrome.
   Desktop    : constant Pixel := 16#FF88_8888#;  --  marble -> solid
   Bar_Face   : constant Pixel := Face;   --  screen bar / menus
   Win_Face   : constant Pixel := 16#FF95_9595#;  --  window bg
   Title_Blue : constant Pixel := Sel_Blue;  --  focused title bar
   Title_Gray : constant Pixel := 16#FFAF_AFAF#;  --  unfocused
   Title_Text : constant Pixel := 16#FFFF_FFFF#;
   Title_Dim  : constant Pixel := Text_Dark;

   --  Software cursor.
   Cur_Outline : constant Pixel := Border;
   Cur_Fill    : constant Pixel := 16#FFFF_FFFF#;

end Akernel_User.Theme;
