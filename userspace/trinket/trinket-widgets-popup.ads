--  Popup (M88): the menu-list panel for the window's overlay
--  layer (Trinket.Window.Open_Popup) — MUI popup-list lineage.
--  A raised Pane panel with one row per item; hover inverts the
--  row (listview selection style), release-over fires On_Pick
--  with the 1-based index. The window owns the dismissal rules
--  (pick, click-outside, Escape); the widget only reports picks.
--  Not a layout citizen (the window positions it) and not a
--  focus-chain member.
package Trinket.Widgets.Popup is

   type Pick_Callback is access procedure (Index : Natural);

   --  Items cap at Max_Children (12) of Max_Text (48) chars —
   --  Group's ceiling, same justification (transient menu text).
   type Popup is new Widget with record
      Items    : Text_Array;
      N        : Natural := 0;
      Hover    : Natural := 0;   --  row under the pointer, 0 none
      Pressed  : Natural := 0;   --  row held down, 0 none
      On_Pick  : Pick_Callback := null;
   end record;
   function New_Popup
     (On_Pick : Pick_Callback := null) return Any_Widget;
   procedure Add_Item (W : in out Popup; S : String);
   overriding procedure Draw (W : Popup; C : Canvas);
   overriding procedure Min_Size (W : Popup; MW, MH : out U64);
   overriding function On_Pointer
     (W : access Popup; K : Pointer_Kind; PX, PY : U64)
      return Boolean;

end Trinket.Widgets.Popup;
