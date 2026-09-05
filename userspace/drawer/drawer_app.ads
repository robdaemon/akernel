--  Drawer (M91): one drawer as an icon-view window — the
--  Workbench "open a volume/drawer" experience. Arg 1 = the
--  drawer path (default Sys:). Double-click navigates drawers
--  in the SAME window, spawns tools (ELF) with the full uniform
--  ABI, and opens everything else in System/Edit. Window
--  dimensions persist in the drawer's DRAWER:GEOM attribute
--  (journaled on BeFS, a silent no-op on FAT32); a per-entry
--  ICON attribute (CSTR path to an XPM) overrides the 32x32
--  deficons. Thin main + library-level app package (callbacks
--  must be library level).
package Drawer_App is
   procedure Main;
end Drawer_App;
