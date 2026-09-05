--  Trinket widgets (milestone 56): the retained widget tree.
--  MUI classes map to Ada tagged types — Widget is the abstract
--  root; Group (H/V layout), Label and Button ship in 56;
--  String, Text_Edit, Listview, Scrollbar follow in 57+.
with Trinket.Images;
--
--  Geometry: X/Y/W/H are window-content-absolute, assigned by the
--  parent's Layout. Damage: a widget sets Dirty when its look
--  changes; the window collects the dirty rects (Dirty_List,
--  union fallback), clips, redraws, and pushes one Surface_Update
--  per band.
package Trinket.Widgets is
   use type Trinket.U64;

   type Widget is abstract tagged record
      X, Y, W, H : U64 := 0;
      Dirty      : Boolean := True;
   end record;
   type Any_Widget is access all Widget'Class;

   type Pointer_Kind is (Move, Press, Release);

   procedure Layout (W : in out Widget);
   --  Computes child geometry from W's own rect. Default: no
   --  children, nothing to do. Group overrides.

   procedure Min_Size (W : Widget; MW, MH : out U64);
   --  Content-driven floor (M86g): the smallest rect that still
   --  fits the widget's content at the CURRENT font. Default
   --  0x0 = no floor. Group.Layout grants every child its min
   --  first and splits only the remainder by weight; Window.Open
   --  grows the requested size to the root's min. Content set
   --  after Open does not renegotiate (same caveat as MUI).

   procedure Draw (W : Widget; C : Canvas) is abstract;
   --  Paint into the canvas; the canvas clip is the damage band
   --  (widgets may skip work via Intersects).

   function On_Pointer
     (W : access Widget; K : Pointer_Kind; PX, PY : U64)
      return Boolean;
   --  PX/PY content-absolute. Returns True when consumed.
   --  Default: not consumed.

   function On_Key (W : access Widget; Code : U64) return Boolean;
   --  Default: not consumed. Focus chains land with Text_Edit.

   function Inside (W : Widget; PX, PY : U64) return Boolean;

    function Dirty_Union
      (W : Widget; X0, Y0, X1, Y1 : out U64) return Boolean;
    --  True + union rect when this subtree has dirty widgets.

    --  Fine-grained damage: Dirty_List appends each dirty
    --  widget's rect instead of unioning the whole subtree —
    --  two distant dirty widgets no longer repaint everything
    --  between them (the old union made a maximized window copy
    --  near its whole pane when e.g. text + scrollbar were dirty
    --  together). Intersecting rects merge; more than
    --  Max_Damage disjoint rects sets Overflow and the caller
    --  falls back to Dirty_Union (one band, the old behavior).
    type Rect is record
       X0, Y0, X1, Y1 : U64;
    end record;
    Max_Damage : constant := 8;
    type Rect_Array is array (1 .. Max_Damage) of Rect;
    procedure Dirty_List
      (W        : Widget;
       Rects    : in out Rect_Array;
       N        : in out Natural;
       Overflow : in out Boolean);

    procedure Clear_Dirty (W : in out Widget);

   function Intersects (W : Widget; C : Canvas) return Boolean;


   --  Image widget (milestone 63): a decoded Trinket.Images.Image
   --  painted centered in its layout rect (clip does the rest).
   --  The widget borrows the image — the app owns Load/Free.
   type Image_Widget is new Widget with record
      Img : Trinket.Images.Image;
   end record;
   function New_Image (Img : Trinket.Images.Image) return Any_Widget;
   overriding procedure Draw (W : Image_Widget; C : Canvas);
   overriding procedure Min_Size (W : Image_Widget; MW, MH : out U64);
   procedure Set_Image (W : in out Image_Widget; Img : Trinket.Images.Image);
   --  Swap the borrowed image and mark dirty (milestone 68: worker
   --  tasks decode images off the event thread and hand them over
   --  via the window app port). The app still owns Load/Free — free
   --  the PREVIOUS image only after the swap, so the widget never
   --  references freed pixels.

   Max_Text : constant := 48;
   subtype Text_Len is Natural range 0 .. Max_Text;

   type Alignment is (Left, Center);

   --  Label: static text, optionally an inset field (sunken
   --  bevel + pane background — the mockup's path gadget look).
   type Label is new Widget with record
      Txt       : String (1 .. Max_Text);
      Len       : Text_Len := 0;
      Align     : Alignment := Left;
      Inset     : Boolean := False;
   end record;
   function New_Label
     (S : String; Align : Alignment := Left; Inset : Boolean := False)
      return Any_Widget;
   overriding procedure Draw (W : Label; C : Canvas);
   overriding procedure Min_Size (W : Label; MW, MH : out U64);
   procedure Set_Text (W : in out Label; S : String);
   --  Update an existing label's text and mark it dirty.

   --  Input (milestone 64): the single-line string gadget the
   --  m56 plan deferred (MUI String class lineage). Sunken pane
   --  field, click focuses + positions the cursor, printables
   --  insert, BS/Del edit, Left/Right/Home/End move, Enter fires
   --  On_Commit. Keys are consumed ONLY while Focused — an
   --  unfocused Input is transparent so sibling widgets (a
   --  listview's arrows) keep working; the app clears focus when
   --  the user clicks elsewhere (e.g. from a selection callback).
   type Click_Callback is access procedure;
   Max_Input : constant := 96;
   type Input is new Widget with record
      Buf       : String (1 .. Max_Input);
      Len       : Natural := 0;
      Cur       : Natural := 0;      --  0-based, insert BEFORE Cur
      HOff      : Natural := 0;      --  first visible char
      Focused   : Boolean := False;
      On_Commit : Click_Callback := null;
   end record;
   function New_Input return Any_Widget;
   function Get_Text (W : Input) return String;
   procedure Set_Text (W : in out Input; S : String);
   procedure Set_Focused (W : in out Input; F : Boolean);
   function Is_Focused (W : Input) return Boolean is (W.Focused);
   overriding procedure Draw (W : Input; C : Canvas);
   overriding procedure Min_Size (W : Input; MW, MH : out U64);
   overriding function On_Key
     (W : access Input; Code : U64) return Boolean;
   overriding function On_Pointer
     (W : access Input; K : Pointer_Kind; PX, PY : U64)
      return Boolean;

   --  Button: raised face, sunken while pressed, centered bold-ish
   --  label; fires On_Click on release-inside.  M86c: lighter
   --  face while the pointer hovers; Disabled ghosts the label
   --  (embossed) and ignores the pointer entirely.
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

    --  Gauge (M87a): progress bar — sunken frame, accent fill
    --  left->right, optional centered NN% label drawn light on
    --  the fill and dark on the empty half (Workbench fuelgauge
    --  lineage). Pure display: no pointer/key handling.
    type Gauge is new Widget with record
       Num      : U64 := 0;
       Den      : U64 := 100;
       Show_Pct : Boolean := True;
    end record;
    function New_Gauge (Show_Pct : Boolean := True) return Any_Widget;
    procedure Set_Fraction (W : in out Gauge; Num, Den : U64);
    --  Den = 0 is treated as 1; Num is clamped to Den. Marks
    --  dirty only when the rendered pixels actually change.
    overriding procedure Draw (W : Gauge; C : Canvas);
    overriding procedure Min_Size (W : Gauge; MW, MH : out U64);

    --  Checkbox / Radio (M86e): toggle gadgets — a 14px framed
    --  box at the left (square for checkboxes, a disc for
    --  radios), label to the right; the whole rect is the hit
    --  area (MUI behavior). The M86c state battery applies:
    --  hover brightens the box face, a held press sinks it and
    --  shifts the glyph, Disabled ghosts the label and ignores
    --  the pointer. The state flips on release-inside and fires
    --  On_Change with the NEW state. Radios sharing one
    --  Radio_Set are mutually exclusive (selecting one clears
    --  the others and marks them dirty); On_Change fires only
    --  for the radio that became selected.
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


   --  Scrollbar (milestone 57): vertical; sunken track, arrow
   --  boxes, striped knob proportional to Visible / range.
   --  Arrow press steps 1, track press pages, knob drags (v4
   --  pointer capture delivers the drag + release even outside
   --  the window). On_Change fires on USER moves only.
   --  M86c press feedback: the pressed arrow draws sunken with
   --  its glyph shifted, the knob draws sunken while dragged.
   type Change_Callback is access procedure (Pos : U64);
   type Scrollbar is new Widget with record
      Min       : U64 := 0;
      Max       : U64 := 0;
      Visible   : U64 := 1;
      Pos       : U64 := 0;
      On_Change : Change_Callback := null;
      Dragging  : Boolean := False;
      Grab_DY   : U64 := 0;
      Arrow_Dn  : Integer := 0;  --  0, -1 up pressed, +1 down
   end record;
   function New_Scrollbar
     (On_Change : Change_Callback := null) return Any_Widget;
   procedure Set_Range
     (W : in out Scrollbar; Min, Max, Visible : U64);
   --  Clamps Pos; marks dirty; does NOT fire On_Change.
   procedure Set_Pos (W : in out Scrollbar; P : U64);
   overriding procedure Draw (W : Scrollbar; C : Canvas);
   overriding procedure Min_Size (W : Scrollbar; MW, MH : out U64);
   overriding function On_Pointer
     (W : access Scrollbar; K : Pointer_Kind; PX, PY : U64)
      return Boolean;

   --  Slider (M87b): horizontal continuous-value gadget — sunken
   --  track, raised knob with grip lines; click on the track
   --  pages toward the point, the knob drags (same v4 pointer
   --  capture as Scrollbar: drag + release arrive even outside
   --  the window). M86c state battery: hover brightens the knob,
   --  dragging sinks it and shifts the grips. On_Change fires
   --  on USER moves only (Set_Pos never does).
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

   --  Group: H/V layout container with an optional frame +
   --  centered title breaking the top edge (the mockup's
   --  "File"/"Text" groups). Inset flips the frame sunken and
   --  fills the interior Pane-white (the text area look).
   --  Kids are first granted their Min_Size in the layout
   --  direction (M86g — content can never be squeezed below its
   --  floor by a font change), then the REMAINDER splits
   --  proportionally to their WEIGHT (MUI lineage; milestone
   --  64): default 1 = the original equal split; a listview in
   --  a tall row takes Weight 5+ and the labels/buttons stay
   --  thin. Horizontal groups still pin scrollbars to Arrow
   --  wide before splitting the remainder by weight.
   type Direction is (Vertical, Horizontal);
   Max_Children : constant := 12;
   type Kid_Array is array (1 .. Max_Children) of Any_Widget;
   type Wt_Array is array (1 .. Max_Children) of U64;
   type Group is new Widget with record
      Dir        : Direction := Vertical;
      Title      : String (1 .. 24);
      Title_Len  : Natural := 0;
      Inset      : Boolean := False;
      Kids       : Kid_Array := (others => null);
      Wts        : Wt_Array := (others => 1);
      N          : Natural := 0;
   end record;
   function New_Group
     (Dir : Direction; Title : String := ""; Inset : Boolean := False)
      return Any_Widget;
   procedure Add (G : in out Group; Child : Any_Widget; Weight : U64 := 1);
   overriding procedure Layout (W : in out Group);
   overriding procedure Min_Size (W : Group; MW, MH : out U64);
   overriding procedure Draw (W : Group; C : Canvas);
   overriding function On_Pointer
     (W : access Group; K : Pointer_Kind; PX, PY : U64)
      return Boolean;
   overriding function On_Key
     (W : access Group; Code : U64) return Boolean;
    overriding function Dirty_Union
      (W : Group; X0, Y0, X1, Y1 : out U64) return Boolean;
    overriding procedure Dirty_List
      (W        : Group;
       Rects    : in out Rect_Array;
       N        : in out Natural;
       Overflow : in out Boolean);
    overriding procedure Clear_Dirty (W : in out Group);

end Trinket.Widgets;
