--  Trinket widgets (milestone 56): the retained widget tree.
--  MUI classes map to Ada tagged types — Widget is the abstract
--  root. This package holds the framework: the Widget base type,
--  geometry/damage, the M87h focus chain, and the Group layout
--  container. The gadgets live in per-widget child packages:
--  Image, Label, Input, Button, Gauge, Separator, Toggles
--  (Checkbox+Radio), Scrollbar, Slider, Tabs, Cycle, Numeric
--  (Text_Edit and Listview are older flat Trinket children).
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
      --  M87h focus chain state. Tab_Rank 0 = the widget's add
      --  position; a positive rank sorts it as that chain
      --  position (ties keep add order). Focused draws the
      --  dotted ring and lets the gadget answer keys; the
      --  window keeps at most one widget focused (it clears
      --  focus on every pointer press, the pressed gadget
      --  re-takes it).
      Tab_Rank   : Natural := 0;
      Focused    : Boolean := False;
   end record;
   type Any_Widget is access all Widget'Class;

   type Pointer_Kind is (Move, Press, Release);

   type Direction is (Vertical, Horizontal);

   --  Scrollbar arrow-box extent (also the pinned cross-axis
   --  thickness of a bar in a Group, and the bar strip in the
   --  scrolled composites).
   Arrow : constant U64 := 16;

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

   function Wants_Focus (W : Widget) return Boolean;
   --  M87h: membership in the window's Tab focus chain. Default
   --  False; the interactive gadgets override True.

   procedure Set_Tab_Rank (W : in out Widget; Rank : Natural);
   --  M87h: 0 (default) = chain position is the add position; a
   --  positive Rank sorts the widget as if added Rank-th. Ties:
   --  a ranked widget beats the natural occupant of the slot
   --  (rank 1 = focus FIRST); two widgets with the same rank
   --  keep add order. Applies to the NEXT Tab press — the chain
   --  is rebuilt on every cycle.

   procedure Set_Focused (W : in out Widget; F : Boolean);
   --  M87h: set the focus flag, dirty on change. Apps rarely
   --  call this — Tab cycles and pointer presses manage focus.
   function Is_Focused (W : Widget) return Boolean;

   procedure Cycle_Focus (Root : Any_Widget);
   --  M87h: move focus to the next member of Root's focus chain
   --  (wraps; focuses the first member when none was). The
   --  window calls this on Tab.

   procedure Clear_Focus (Root : Any_Widget);
   --  M87h: drop every Focused flag in the subtree. The window
   --  calls this before dispatching a pointer press; the pressed
   --  gadget re-takes focus in its Press handler.

   Max_Focus_Chain : constant := 64;
   --  Transient staging for one Tab press, rebuilt each time —
   --  not a capacity table. The biggest app tree (tdemo) has
   --  ~20 focusable gadgets; past the ceiling the rest are just
   --  unreachable via Tab (pointer focus is unaffected).

   function Inside (W : Widget; PX, PY : U64) return Boolean;

   --  Group layout hooks (M87c): how the widget sits in a Group
   --  with direction Group_Dir. A Scrollbar overrides both: a
   --  bar whose own Dir DIFFERS from the group's takes a fixed
   --  Arrow slot along the main axis (no weight share); a bar
   --  whose Dir MATCHES shrinks to Arrow in the cross axis,
   --  centered. Defaults False: weight split both ways. Keeps
   --  Group decoupled from the Scrollbar child package.
   function Fixed_Main (W : Widget; Group_Dir : Direction) return Boolean;
   function Narrow_Cross (W : Widget; Group_Dir : Direction) return Boolean;

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

   --  Shared callback profiles: Click_Callback serves Button's
   --  On_Click and Input's On_Commit; Change_Callback is the
   --  Slider's (and Scrollbar's legacy) position report.
   type Click_Callback is access procedure;
   type Change_Callback is access procedure (Pos : U64);

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

   --  Shared short-string cells: Label/Button/Toggles text,
   --  Tabs labels, Cycle entries. Public because the gadget
   --  child packages embed them in their records (a public
   --  child spec cannot see this package's private part).
   Max_Text : constant := 48;
   subtype Text_Len is Natural range 0 .. Max_Text;
   type Text_Rec is record
      Buf : String (1 .. Max_Text);
      Len : Text_Len := 0;
   end record;
   type Text_Array is array (1 .. Max_Children) of Text_Rec;

private

   --  Internals shared by the per-widget child packages
   --  (Trinket.Widgets.*) — visible to their BODIES only, not
   --  client API.

   function Max (A, B : U64) return U64 is (if A > B then A else B);
   function Min (A, B : U64) return U64 is (if A < B then A else B);

   --  Copy S into a fixed text cell, truncating at Buf'Length.
   procedure Set_Text (Buf : out String; Len : out Text_Len; S : String);

   --  Damage-list append with in-place merge: a rect that
   --  intersects an existing entry unions into it (single pass —
   --  a merge that bridges a THIRD entry is left as-is; the
   --  overlap repaints identically, just twice). A full list
   --  sets Overflow; the caller degrades to Dirty_Union.
   procedure Add_Rect
     (Rects    : in out Rect_Array;
      N        : in out Natural;
      Overflow : in out Boolean;
      X0, Y0, X1, Y1 : U64);

   --  Box geometry shared by both Toggles: box at the left edge,
   --  vertically centered; the label sits Toggle_Gap right of it.
   Toggle_Box : constant U64 := 14;  --  square box / disc size
   Toggle_Gap : constant U64 := 6;   --  box-to-label spacing
   procedure Toggle_Metrics
     (W : Widget'Class; BX, BY, TX, TY : out U64);
   procedure Toggle_Label
     (W : Widget'Class; C : Canvas; Txt : String; Len : Text_Len;
      Disabled : Boolean; Shift : U64);
   --  Shared toggle floor: the taller of box/text plus padding.
   procedure Toggle_Min (Txt : String; MW, MH : out U64);

   --  Right chevron column width (Cycle, Numeric).
   Glyph_Col : constant U64 := 18;

end Trinket.Widgets;
