--  Toggles (M86e): Checkbox and Radio — a 14px framed box at
--  the left (square for checkboxes, a disc for radios), label
--  to the right; the whole rect is the hit area (MUI behavior).
--  The M86c state battery applies: hover brightens the box
--  face, a held press sinks it and shifts the glyph, Disabled
--  ghosts the label and ignores the pointer. The state flips on
--  release-inside and fires On_Change with the NEW state.
--  Radios sharing one Radio_Set are mutually exclusive
--  (selecting one clears the others and marks them dirty);
--  On_Change fires only for the radio that became selected.
--  M87h: Enter/Space activates the focused toggle; disabled
--  toggles skip the focus chain. Box/label geometry helpers
--  (Toggle_*) live in the parent's private part.
package Trinket.Widgets.Toggles is

   type Toggle_Callback is access procedure (On : Boolean);

   type Checkbox is new Widget with record
      Txt       : String (1 .. Max_Text);
      Len       : Text_Len := 0;
      Checked   : Boolean := False;
      Pressed   : Boolean := False;
      Hover     : Boolean := False;
      Disabled  : Boolean := False;
      On_Change : Toggle_Callback := null;
   end record;
   function New_Checkbox
     (S         : String;
      Checked   : Boolean := False;
      On_Change : Toggle_Callback := null;
      Disabled  : Boolean := False) return Any_Widget;
   procedure Set_Checked (W : in out Checkbox; On : Boolean);
   --  Programmatic set; marks dirty; does NOT fire On_Change.
   function Is_Checked (W : Checkbox) return Boolean is (W.Checked);
   overriding procedure Draw (W : Checkbox; C : Canvas);
   overriding procedure Min_Size (W : Checkbox; MW, MH : out U64);
   overriding function On_Pointer
     (W : access Checkbox; K : Pointer_Kind; PX, PY : U64)
      return Boolean;
   overriding function Wants_Focus (W : Checkbox) return Boolean;
   overriding function On_Key
     (W : access Checkbox; Code : U64) return Boolean;

   Max_Radio : constant := 8;
   type Radio_Members is array (1 .. Max_Radio) of Any_Widget;
   type Radio_Set is record
      Members : Radio_Members := (others => null);
      N       : Natural := 0;
   end record;
   type Radio_Set_Access is access all Radio_Set;

   type Radio is new Widget with record
      Txt       : String (1 .. Max_Text);
      Len       : Text_Len := 0;
      Selected  : Boolean := False;
      Pressed   : Boolean := False;
      Hover     : Boolean := False;
      Disabled  : Boolean := False;
      Peers     : Radio_Set_Access := null;
      On_Change : Toggle_Callback := null;
   end record;
   function New_Radio
     (S         : String;
      Peers     : Radio_Set_Access := null;
      Selected  : Boolean := False;
      On_Change : Toggle_Callback := null;
      Disabled  : Boolean := False) return Any_Widget;
   --  Registers the new radio in Peers (silently ungrouped past
   --  Max_Radio members — headroom note: 8 per set is the M86e
   --  policy constant, way past any dialog we ship).
   procedure Set_Selected (W : in out Radio; On : Boolean);
   --  On => True also clears + dirties the Peers; On => False
   --  clears only W. Never fires On_Change.
   function Is_Selected (W : Radio) return Boolean is (W.Selected);
   overriding procedure Draw (W : Radio; C : Canvas);
   overriding procedure Min_Size (W : Radio; MW, MH : out U64);
   overriding function On_Pointer
     (W : access Radio; K : Pointer_Kind; PX, PY : U64)
      return Boolean;
   overriding function Wants_Focus (W : Radio) return Boolean;
   overriding function On_Key
     (W : access Radio; Code : U64) return Boolean;

end Trinket.Widgets.Toggles;
