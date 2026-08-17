--  Trinket widgets (milestone 56): the retained widget tree.
--  MUI classes map to Ada tagged types — Widget is the abstract
--  root; Group (H/V layout), Label and Button ship in 56;
--  String, Text_Edit, Listview, Scrollbar follow in 57+.
with Trinket.Images;
--
--  Geometry: X/Y/W/H are window-content-absolute, assigned by the
--  parent's Layout. Damage: a widget sets Dirty when its look
--  changes; the window unions dirty rects, clips, redraws, and
--  pushes one Surface_Update band per frame.
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
   procedure Set_Text (W : in out Label; S : String);
   --  Update an existing label's text and mark it dirty.

   --  Button: raised face, sunken while pressed, centered bold-ish
   --  label; fires On_Click on release-inside.
   type Click_Callback is access procedure;
   type Button is new Widget with record
      Txt      : String (1 .. Max_Text);
      Len      : Text_Len := 0;
      Pressed  : Boolean := False;
      On_Click : Click_Callback := null;
   end record;
   function New_Button
     (S : String; On_Click : Click_Callback := null) return Any_Widget;
   overriding procedure Draw (W : Button; C : Canvas);
   overriding function On_Pointer
     (W : access Button; K : Pointer_Kind; PX, PY : U64)
      return Boolean;

   --  Scrollbar (milestone 57): vertical; sunken track, arrow
   --  boxes, striped knob proportional to Visible / range.
   --  Arrow press steps 1, track press pages, knob drags (v4
   --  pointer capture delivers the drag + release even outside
   --  the window). On_Change fires on USER moves only.
   type Change_Callback is access procedure (Pos : U64);
   type Scrollbar is new Widget with record
      Min       : U64 := 0;
      Max       : U64 := 0;
      Visible   : U64 := 1;
      Pos       : U64 := 0;
      On_Change : Change_Callback := null;
      Dragging  : Boolean := False;
      Grab_DY   : U64 := 0;
   end record;
   function New_Scrollbar
     (On_Change : Change_Callback := null) return Any_Widget;
   procedure Set_Range
     (W : in out Scrollbar; Min, Max, Visible : U64);
   --  Clamps Pos; marks dirty; does NOT fire On_Change.
   procedure Set_Pos (W : in out Scrollbar; P : U64);
   overriding procedure Draw (W : Scrollbar; C : Canvas);
   overriding function On_Pointer
     (W : access Scrollbar; K : Pointer_Kind; PX, PY : U64)
      return Boolean;

   --  Group: H/V layout container with an optional frame +
   --  centered title breaking the top edge (the mockup's
   --  "File"/"Text" groups). Inset flips the frame sunken and
   --  fills the interior Pane-white (the text area look).
   type Direction is (Vertical, Horizontal);
   Max_Children : constant := 12;
   type Kid_Array is array (1 .. Max_Children) of Any_Widget;
   type Group is new Widget with record
      Dir        : Direction := Vertical;
      Title      : String (1 .. 24);
      Title_Len  : Natural := 0;
      Inset      : Boolean := False;
      Kids       : Kid_Array := (others => null);
      N          : Natural := 0;
   end record;
   function New_Group
     (Dir : Direction; Title : String := ""; Inset : Boolean := False)
      return Any_Widget;
   procedure Add (G : in out Group; Child : Any_Widget);
   overriding procedure Layout (W : in out Group);
   overriding procedure Draw (W : Group; C : Canvas);
   overriding function On_Pointer
     (W : access Group; K : Pointer_Kind; PX, PY : U64)
      return Boolean;
   overriding function On_Key
     (W : access Group; Code : U64) return Boolean;
   overriding function Dirty_Union
     (W : Group; X0, Y0, X1, Y1 : out U64) return Boolean;
   overriding procedure Clear_Dirty (W : in out Group);

end Trinket.Widgets;
