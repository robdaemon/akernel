--  Input (milestone 64): the single-line string gadget the m56
--  plan deferred (MUI String class lineage). Sunken pane field,
--  click focuses + positions the cursor, printables insert,
--  BS/Del edit, Left/Right/Home/End move, Enter fires On_Commit.
--  Keys are consumed ONLY while Focused — an unfocused Input is
--  transparent so sibling widgets (a listview's arrows) keep
--  working. M87h: the window manages the focus flag (click takes
--  it, Tab cycles, clicking elsewhere drops it); Focused moved
--  to the base Widget.
package Trinket.Widgets.Input is

   Max_Input : constant := 96;
   type Input is new Widget with record
      Buf       : String (1 .. Max_Input);
      Len       : Natural := 0;
      Cur       : Natural := 0;      --  0-based, insert BEFORE Cur
      HOff      : Natural := 0;      --  first visible char
      On_Commit : Click_Callback := null;
   end record;
   function New_Input return Any_Widget;
   function Get_Text (W : Input) return String;
   procedure Set_Text (W : in out Input; S : String);
   overriding function Wants_Focus (W : Input) return Boolean;
   overriding procedure Draw (W : Input; C : Canvas);
   overriding procedure Min_Size (W : Input; MW, MH : out U64);
   overriding function On_Key
     (W : access Input; Code : U64) return Boolean;
   overriding function On_Pointer
     (W : access Input; K : Pointer_Kind; PX, PY : U64)
      return Boolean;

end Trinket.Widgets.Input;
