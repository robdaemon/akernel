--  Numeric (M87g): MUI numeric gadget — a sunken Pane field
--  showing an integer value, up/down arrow mini-buttons in a
--  right column (step on release-over, clamped, pre-clamped
--  down-steps like Scrollbar). No auto-repeat (the widget event
--  model has no timers) and no keyboard editing — it's a
--  spinner, not an Input. M86c battery: hover brightens the
--  arrow under the pointer, a held arrow sinks + shifts its
--  chevron. On_Change fires on USER steps only (Set_Value never
--  fires it). M87h: a focused numeric's Up/Right step +Step,
--  Down/Left -Step (pre-clamped).
package Trinket.Widgets.Numeric is

   type Numeric_Callback is access procedure (Value : U64);
   type Numeric is new Widget with record
      Min        : U64 := 0;
      Max        : U64 := 100;
      Step       : U64 := 1;
      Val        : U64 := 0;
      Hover_Arr  : Integer := 0;  --  0, -1 down-half, +1 up-half
      Arrow_Dn   : Integer := 0;  --  0, -1 down held, +1 up held
      On_Change  : Numeric_Callback := null;
   end record;
   function New_Numeric
     (Min : U64 := 0; Max : U64 := 100;
      On_Change : Numeric_Callback := null) return Any_Widget;
   procedure Set_Value (W : in out Numeric; V : U64);
   function Value (W : Numeric) return U64;
   overriding procedure Draw (W : Numeric; C : Canvas);
   overriding procedure Min_Size (W : Numeric; MW, MH : out U64);
   overriding function On_Pointer
     (W : access Numeric; K : Pointer_Kind; PX, PY : U64)
      return Boolean;
   overriding function Wants_Focus (W : Numeric) return Boolean;
   overriding function On_Key
     (W : access Numeric; Code : U64) return Boolean;

end Trinket.Widgets.Numeric;
