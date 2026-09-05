--  Prefs/Font (M89): the Amiga fontrequester — font families in
--  the left listview, sizes in the right, a live preview of the
--  selected font below, Okay/Cancel at the bottom. Okay writes
--  ENV:Font (the BDF path); Trinket.Fonts.Init consults it, so
--  the choice applies to every app launched afterwards.
package Font_App is

   procedure Main;

end Font_App;
