--  Cycle (M87f): MUI cycle gadget — a raised field showing the
--  current entry, up/down chevron pair in a right glyph column;
--  each click rotates to the next entry (wraps). M86c battery:
--  hover brightens, press sinks + shifts. Entries cap at
--  Max_Children (12) of Max_Text (48) chars — Group's ceiling,
--  same justification. M87h: a focused cycle rotates on
--  Enter/Space/Right (forward) and Left (back), wrapping.
package Trinket.Widgets.Cycle is

   type Cycle_Callback is access procedure (Index : Natural);
   type Cycle is new Widget with record
      Entries   : Text_Array;
      N         : Natural := 0;
      Sel       : Natural := 0;   --  1-based
      Hover     : Boolean := False;
      Pressed   : Boolean := False;
      On_Change : Cycle_Callback := null;
   end record;
   function New_Cycle
     (On_Change : Cycle_Callback := null) return Any_Widget;
   procedure Add_Entry (W : in out Cycle; S : String);
   procedure Set_Selected (W : in out Cycle; I : Natural);
   function Selected (W : Cycle) return Natural;
   overriding procedure Draw (W : Cycle; C : Canvas);
   overriding procedure Min_Size (W : Cycle; MW, MH : out U64);
   overriding function On_Pointer
     (W : access Cycle; K : Pointer_Kind; PX, PY : U64)
      return Boolean;
   overriding function Wants_Focus (W : Cycle) return Boolean;
   overriding function On_Key
     (W : access Cycle; Code : U64) return Boolean;

end Trinket.Widgets.Cycle;
