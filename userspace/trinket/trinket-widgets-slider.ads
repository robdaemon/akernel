--  Slider (M87b): horizontal continuous-value gadget — sunken
--  track, raised knob with grip lines; click on the track pages
--  toward the point, the knob drags (same v4 pointer capture as
--  Scrollbar: drag + release arrive even outside the window).
--  M86c state battery: hover brightens the knob, dragging sinks
--  it and shifts the grips. On_Change fires on USER moves only
--  (Set_Pos never does). M87h: a focused slider's Left/Down
--  step -1%, Right/Up +1% (min 1 Pos unit).
package Trinket.Widgets.Slider is

   type Slider is new Widget with record
      Min       : U64 := 0;
      Max       : U64 := 100;
      Pos       : U64 := 0;
      On_Change : Change_Callback := null;
      Dragging  : Boolean := False;
      Grab_DX   : U64 := 0;
      Hover     : Boolean := False;
   end record;
   function New_Slider
     (Min       : U64 := 0;
      Max       : U64 := 100;
      On_Change : Change_Callback := null) return Any_Widget;
   procedure Set_Range (W : in out Slider; Min, Max : U64);
   procedure Set_Pos (W : in out Slider; P : U64);
   --  Clamps Pos; marks dirty; does NOT fire On_Change.
   overriding procedure Draw (W : Slider; C : Canvas);
   overriding procedure Min_Size (W : Slider; MW, MH : out U64);
   overriding function On_Pointer
     (W : access Slider; K : Pointer_Kind; PX, PY : U64)
      return Boolean;
   overriding function Wants_Focus (W : Slider) return Boolean;
   overriding function On_Key
     (W : access Slider; Code : U64) return Boolean;

end Trinket.Widgets.Slider;
