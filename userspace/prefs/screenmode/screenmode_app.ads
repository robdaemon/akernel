--  Prefs/ScreenMode (M90): the Amiga ScreenMode editor — a static
--  list of display modes, Okay applies the pick at runtime
--  (Op_Set_Screen_Mode -> Bureau -> the display driver recreates
--  its scanout) and saves ENV:Screen.Width/Height; the Makefile
--  run recipe feeds those back to QEMU's xres/yres, so the mode
--  persists across reboots. Cancel quits without touching
--  anything.
package Screenmode_App is

   procedure Main;

end Screenmode_App;
