--  Button (milestone 56): raised face, sunken while pressed,
--  centered bold-ish label; fires On_Click on release-inside.
--  M86c: lighter face while the pointer hovers; Disabled ghosts
--  the label (embossed) and ignores the pointer entirely. M87h:
--  Enter/Space activates the focused button.
package Trinket.Widgets.Button is

   type Button is new Widget with record
      Txt      : String (1 .. Max_Text);
      Len      : Text_Len := 0;
      Pressed  : Boolean := False;
      Hover    : Boolean := False;
      Disabled : Boolean := False;
      On_Click : Click_Callback := null;
   end record;
    function New_Button
      (S        : String;
       On_Click : Click_Callback := null;
       Disabled : Boolean        := False) return Any_Widget;
     overriding procedure Draw (W : Button; C : Canvas);
     overriding procedure Min_Size (W : Button; MW, MH : out U64);
     overriding function On_Pointer
      (W : access Button; K : Pointer_Kind; PX, PY : U64)
       return Boolean;
     overriding function Wants_Focus (W : Button) return Boolean;
     overriding function On_Key
      (W : access Button; Code : U64) return Boolean;

end Trinket.Widgets.Button;
