--  Scrollbar (milestone 57): sunken track, arrow boxes, striped
--  knob proportional to Visible / range. Arrow press steps 1,
--  track press pages, knob drags (v4 pointer capture delivers
--  the drag + release even outside the window). On_Change fires
--  on USER moves only. M86c press feedback: the pressed arrow
--  draws sunken with its glyph shifted, the knob draws sunken
--  while dragged. M87c: Dir selects the axis — Vertical
--  (default) stacks the arrow cluster at the bottom, Horizontal
--  mirrors everything with the cluster at the right. Scrolled
--  composites (Text_Edit.New_Scrolled_Editor,
--  Listview.New_Scrolled_List) attach the bars flush to their
--  content; wiring by hand is only for custom canvases
--  (terminal).
package Trinket.Widgets.Scrollbar is

   --  Bar callback carrying the bar itself; Bar.Ctx holds the
   --  owner's context object (set via New_Scrollbar), so one
   --  package-level handler can serve every instance.
   type Bar_Callback is access procedure (Bar : Any_Widget; Pos : U64);

   type Scrollbar is new Widget with record
      Min       : U64 := 0;
      Max       : U64 := 0;
      Visible   : U64 := 1;
      Pos       : U64 := 0;
      Step      : U64 := 1;   --  arrow-click delta (Pos units)
      Dir       : Direction := Vertical;
      Ctx       : Any_Widget := null;
      On_Change : Bar_Callback := null;
      Dragging  : Boolean := False;
      Grab_DY   : U64 := 0;
      Arrow_Dn  : Integer := 0;  --  0, -1 up/left pressed, +1 down/right
   end record;
   function New_Scrollbar
     (On_Change : Bar_Callback := null;
      Dir       : Direction := Vertical;
      Ctx       : Any_Widget := null) return Any_Widget;
   procedure Set_Range
     (W : in out Scrollbar; Min, Max, Visible : U64);
   --  Arrow-click delta; default 1 (one Pos unit). Pixel-based
   --  bars (Text_Edit h-scroll) want ~a char width.
   procedure Set_Step (W : in out Scrollbar; S : U64);
   --  Clamps Pos; marks dirty; does NOT fire On_Change.
   procedure Set_Pos (W : in out Scrollbar; P : U64);
   overriding procedure Draw (W : Scrollbar; C : Canvas);
   overriding procedure Min_Size (W : Scrollbar; MW, MH : out U64);
   overriding function On_Pointer
     (W : access Scrollbar; K : Pointer_Kind; PX, PY : U64)
      return Boolean;
   --  M87c Group layout hooks: pin cross-axis to Arrow.
   overriding function Fixed_Main
     (W : Scrollbar; Group_Dir : Direction) return Boolean;
   overriding function Narrow_Cross
     (W : Scrollbar; Group_Dir : Direction) return Boolean;

end Trinket.Widgets.Scrollbar;
