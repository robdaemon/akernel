--  Tdemo app logic at LIBRARY level: Trinket's Click_Callback is a
--  library-level access-to-procedure type, so the click handlers
--  must live at library level too (a main procedure's nested
--  handlers fail accessibility).
package Tdemo_App is
   procedure Main;
end Tdemo_App;
