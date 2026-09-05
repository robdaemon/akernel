# Trinket widget catalogue

This page lists the widgets available in `userspace/trinket/`.
Coordinates and sizes are `U64` (unsigned 64-bit), measured in pixels,
and are **content-absolute** inside the window.

## Base types

### `Trinket.Pixel`

`subtype Pixel is Interfaces.Unsigned_32;` — little-endian `AARRGGBB`.

Palette constants (renames of `Akernel_User.Theme`, M86a — one
skin shared with Bureau chrome; Xen values since M86b):

| name | value | use |
|---|---|---|
| `Face` | `16#FFAF_AFAF#` | gadget face |
| `Win_Face` | `16#FF95_9595#` | window background behind widgets |
| `Bevel_Hi` | `16#FFFF_FFFF#` | highlight bevel |
| `Bevel_Lo` | `16#FF7B_7B7B#` | shadow bevel |
| `Border` | `16#FF10_1010#` | thin border |
| `Pane` | `16#FFAF_AFAF#` | editable field background |
| `Sel_Blue` | `16#FF3B_67A2#` | selection |
| `Text_Dark` | `16#FF20_2020#` | text |

Navigation key codes delivered by Bureau/virtio-input for non-ASCII
keys (text consumers drop `>= 16#80#`):

`Key_Up`, `Key_Down`, `Key_Left`, `Key_Right`, `Key_Home`, `Key_End`,
`Key_Pageup`, `Key_Pagedown`, `Key_Delete`.

### `Trinket.Canvas`

```ada
type Canvas is record
   Base          : System.Address := System.Null_Address;
   W, H          : U64 := 0;
   CX0, CY0      : U64 := 0;
   CX1, CY1      : U64 := 0;
end record;
```

Drawing target: mapped surface buffer plus a half-open clip rectangle
`[CX0,CX1) x [CY0,CY1)`. Every paint op clips to this rectangle.
`Set_Clip` intersects; `Reset_Clip` restores to the full surface.

### `Trinket.Widgets.Widget`

```ada
type Widget is abstract tagged record
   X, Y, W, H : U64 := 0;
   Dirty      : Boolean := True;
end record;
type Any_Widget is access all Widget'Class;
```

Abstract root. Concrete widgets override `Draw`; containers override
`Layout` and event dispatch. Primitive operations:

| operation | role |
|---|---|
| `Layout (W : in out Widget)` | compute children from `W`'s rect; default no-op |
| `Min_Size (W : Widget; MW, MH : out U64)` | content-driven floor at the current font; default 0x0 |
| `Draw (W : Widget; C : Canvas) is abstract` | paint into clipped canvas |
| `On_Pointer (W : access Widget; K : Pointer_Kind; PX, PY : U64) return Boolean` | pointer event; default unconsumed |
| `On_Key (W : access Widget; Code : U64) return Boolean` | key event; default unconsumed |
| `Inside (W : Widget; PX, PY : U64) return Boolean` | hit test against `W`'s rect |
| `Dirty_List` / `Dirty_Union` / `Clear_Dirty` / `Intersects` | damage-band bookkeeping |

`Pointer_Kind` is `Move`, `Press`, or `Release`.

## Concrete widgets

### `Label`

```ada
type Label is new Widget with record
   Txt       : String (1 .. Max_Text);
   Len       : Text_Len := 0;
   Align     : Alignment := Left;
   Inset     : Boolean := False;
end record;
```

Static text. `Inset => True` draws a sunken bevel + pane background
like a mockup path gadget.

Constructors / methods:

```ada
function New_Label
  (S : String; Align : Alignment := Left; Inset : Boolean := False)
   return Any_Widget;
procedure Set_Text (W : in out Label; S : String);
```

`Set_Text` updates the string and marks the widget dirty.

### `Button`

```ada
type Button is new Widget with record
   Txt      : String (1 .. Max_Text);
   Len      : Text_Len := 0;
   Pressed  : Boolean := False;
   Hover    : Boolean := False;      --  M86c: pointer over it
   Disabled : Boolean := False;      --  M86c: ghosted, inert
   On_Click : Click_Callback := null;
end record;
```

Raised face, sunken while pressed, centered label. Fires `On_Click`
on release inside the button. M86c states: the face brightens to
`Theme.Face_Hi` while hovered (Bureau delivers a leave-marker move
one pixel past the pane corner when the pointer exits the window,
so hover never latches); `Disabled` draws the label embossed
(highlight over shadow) and ignores the pointer.

```ada
type Click_Callback is access procedure;

function New_Button
  (S        : String;
   On_Click : Click_Callback := null;
   Disabled : Boolean        := False) return Any_Widget;
```

### `Input` (single-line string gadget)

```ada
type Input is new Widget with record
   Buf       : String (1 .. Max_Input);  -- Max_Input = 96
   Len       : Natural := 0;
   Cur       : Natural := 0;      -- 0-based insert point
   HOff      : Natural := 0;      -- first visible char
   Focused   : Boolean := False;
   On_Commit : Click_Callback := null;
end record;
```

Sunken pane field. Click focuses and positions the cursor. Printable
keys insert, `BS`/`Del` delete, arrows/home/end move. `On_Commit`
fires on Enter (M84 fix: the input seat delivers Return as LF (10);
both CR and LF commit).

Keys are consumed **only while focused**, so sibling widgets (e.g. a
listview's arrows) keep working when focus is elsewhere.

```ada
function New_Input return Any_Widget;
function Get_Text (W : Input) return String;
procedure Set_Text (W : in out Input; S : String);
procedure Set_Focused (W : in out Input; F : Boolean);
function Is_Focused (W : Input) return Boolean;
```

### `Checkbox` / `Radio` (toggles)

```ada
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

Max_Radio : constant := 8;  --  per set (policy constant)
type Radio_Set is record
   Members : Radio_Members := (others => null);
   N       : Natural := 0;
end record;

type Radio is new Widget with record
   --  same battery, plus
   Selected  : Boolean := False;
   Peers     : Radio_Set_Access := null;
end record;
```

Toggle gadgets (M86e): a 14px framed box at the left — square for
`Checkbox`, a disc for `Radio` — with the label to its right; the
**whole rect is the hit area** (MUI behavior). The state battery
matches `Button` (M86c): hover brightens the box face, a held
press sinks it and shifts the glyph, `Disabled` ghosts the label
and ignores the pointer. The state flips on release-inside and
`On_Change` fires with the NEW state. A checked box carries an
embossed check (dark stroke, white shadow); a selected radio a
solid dot.

Radios sharing one `Radio_Set` (pass `Set'Access` to `New_Radio`'s
`Peers`) are mutually exclusive: selecting one clears and dirties
the others; `On_Change` fires only for the radio that became
selected. `Max_Radio` = 8 members per set is a policy constant
with headroom past any dialog we ship.

```ada
function New_Checkbox
  (S : String; Checked : Boolean := False;
   On_Change : Toggle_Callback := null;
   Disabled : Boolean := False) return Any_Widget;
function New_Radio
  (S : String; Peers : Radio_Set_Access := null;
   Selected : Boolean := False;
   On_Change : Toggle_Callback := null;
   Disabled : Boolean := False) return Any_Widget;
procedure Set_Checked (W : in out Checkbox; On : Boolean);
procedure Set_Selected (W : in out Radio; On : Boolean);
```

The programmatic setters mark dirty and never fire `On_Change`;
`Set_Selected (W, True)` also clears the peers.

### `Scrollbar`

```ada
type Bar_Callback is access procedure (Bar : Any_Widget; Pos : U64);

type Scrollbar is new Widget with record
   Min       : U64 := 0;
   Max       : U64 := 0;
   Visible   : U64 := 1;
   Pos       : U64 := 0;
   Step      : U64 := 1;   --  M87c: arrow-click delta
   Dir       : Direction := Vertical;  --  M87c
   Ctx       : Any_Widget := null;     --  owner's context (M87e)
   On_Change : Bar_Callback := null;
   Dragging  : Boolean := False;
   Grab_DY   : U64 := 0;
   Arrow_Dn  : Integer := 0;  --  M86c: 0, -1 up held, +1 down held
end record;
```

Scrollbar in the MUI/Xen look (M86d): flat black/white
frame, track and knob of 1px window-gray/gadget-gray
stripes, and — MUI's signature layout — **both arrow boxes
clustered together** (bottom for vertical, right for
horizontal) with thin embossed chevron glyphs.
Pointer capture (Bureau v4) delivers drag and release outside the
window. `On_Change` fires **only for user moves**, not for
programmatic `Set_Pos`, and carries the bar itself; `Bar.Ctx`
holds the owner's context object, so one package-level handler
can serve every instance (the scrolled composites use this —
one `Bar_Moved` per content package). M86c press feedback: a
held arrow draws sunken with its glyph shifted one pixel; the
knob draws sunken while dragged.

```ada
function New_Scrollbar
  (On_Change : Bar_Callback := null;
   Dir       : Direction := Vertical;
   Ctx       : Any_Widget := null) return Any_Widget;

procedure Set_Range
  (W : in out Scrollbar; Min, Max, Visible : U64);
procedure Set_Pos (W : in out Scrollbar; P : U64);
procedure Set_Step (W : in out Scrollbar; S : U64);
```

`Set_Range` clamps `Pos` and marks dirty without firing `On_Change`
(and no-ops entirely when the metrics didn't change, so composites
can re-sync on every draw). **M87c**: `Dir => Horizontal`
mirrors the bar across the diagonal — arrow cluster at the right,
`<`/`>` chevrons, stripes by row; `Min_Size` is `3*Arrow x Arrow`
(vs `Arrow x 3*Arrow`). Groups pin a scrollbar to `Arrow` in its
cross axis automatically. `Set_Step` sets the arrow-click delta in
`Pos` units (default 1; pixel-based bars want ~a char cell).
**M87e**: apps normally don't construct bars at all —
`Text_Edit.New_Scrolled_Editor` and `Listview.New_Scrolled_List`
build the content widget with its bars attached; hand-wiring a bar
is for custom canvases (the terminal).

### `Separator` (M87d)

```ada
function New_Separator return Any_Widget;
```

Etched horizontal groove (1px `Bevel_Lo` line with a `Bevel_Hi`
line right under it), for visual grouping inside a vertical group —
tdemo has one between the Choices and Font groups. `Min_Size` is
`0 x 2`.

### `Tabs` (M87e)

```ada
type Tab_Callback is access procedure (Index : Natural);

function New_Tabs
  (On_Change : Tab_Callback := null) return Any_Widget;
procedure Add_Tab (W : in out Tabs; Label : String; Page : Any_Widget);
procedure Set_Selected (W : in out Tabs; I : Natural);
function Selected (W : Tabs) return Natural;
```

MUI register-group lineage: a tab strip across the top, one page
per tab. `Tabs` IS a `Group` subtype — pages are the kids — but
only the **selected** page is laid out, drawn and dispatched;
hidden pages hold a zero rect and contribute no damage (`Dirty_List`
walks the active page only). Tabs have chamfered (rounded) top
corners, `Tab_Gap` (3px) between them, and **no bottom edge of
their own** — the page frame's top line is the shared boundary;
the active tab's fill runs 2px lower, covering the frame bevel in
its span so it merges into the page. M86c battery: hover brightens
an inactive tab, a held press shifts the label one pixel; a
click commits only on release-over the same tab. Per-tab disabled
doesn't map onto a strip (apps add/remove pages instead), so it
isn't modeled. `Set_Selected` re-lays-out immediately, full-redraws,
and fires `On_Change`. Labels cap at `Max_Text` (48) chars, pages at
`Max_Children` (12) — Group's ceiling, same justification.
`Min_Size`: strip height (`LH + 8`) + tallest page + frame; width
covers the whole strip (gaps included) or the widest page,
whichever is larger. tdemo showcases a two-page strip reporting
switches on the status line.

### `Image_Widget`

```ada
type Image_Widget is new Widget with record
   Img : Trinket.Images.Image;
end record;
```

Centers a decoded `Trinket.Images.Image` inside its layout rect. The
widget **borrows** the image; the app owns `Load`/`Free`.

```ada
function New_Image (Img : Trinket.Images.Image) return Any_Widget;
procedure Set_Image (W : in out Image_Widget; Img : Trinket.Images.Image);
```

`Set_Image` swaps the borrowed image and marks the widget dirty —
the handoff point for worker-decoded images arriving via the window
app port (milestone 68; see tdemo's Work button). Free the previous
image only after the swap, so the widget never references freed
pixels.

See also `Trinket.Images` (Bmp/Xpm loaders) and `Trinket.Paint.Blit`.

### `Slider` (M87b)

```ada
type Slider is new Widget with record
   Min       : U64 := 0;
   Max       : U64 := 100;
   Pos       : U64 := 0;
   On_Change : Change_Callback := null;
   ...
end record;
function New_Slider
  (Min : U64 := 0; Max : U64 := 100;
   On_Change : Change_Callback := null) return Any_Widget;
procedure Set_Range (W : in out Slider; Min, Max : U64);
procedure Set_Pos (W : in out Slider; P : U64);
```

Horizontal continuous-value gadget, Scrollbar's sibling: sunken
track channel, raised 12px knob with grip lines. Clicking the track
pages toward the point (10% of range); the knob drags (same v4
pointer capture — drag and release arrive even outside the window).
State battery: hover brightens the knob face, dragging sinks it and
shifts the grips. `On_Change` fires on user moves only; `Set_Pos` /
`Set_Range` clamp and mark dirty without firing. `Min_Size` is
64x14. tdemo wires it to the Gauge (slider position = gauge
percent).

Down-steps (here and in `Scrollbar`, fixed in M87b) are pre-clamped:
`Pos - Page` is U64 and wraps past `Min`, and the clamp would read
the wrap as "past Max" — the up arrow at the top used to jump to
the bottom.

### `Cycle` (M87f)

```ada
type Cycle_Callback is access procedure (Index : Natural);

function New_Cycle
  (On_Change : Cycle_Callback := null) return Any_Widget;
procedure Add_Entry (W : in out Cycle; S : String);
procedure Set_Selected (W : in out Cycle; I : Natural);
function Selected (W : Cycle) return Natural;
```

MUI cycle gadget: a raised field showing the current entry with an
up/down chevron pair in a separated right glyph column. Each
release-over rotates to the next entry (wraps at the end) and fires
`On_Change`; `Set_Selected` does the same programmatically. M86c
battery: hover brightens, press sinks + shifts text and glyph one
pixel. Entries cap at `Max_Children` (12) of `Max_Text` (48) chars —
Group's ceiling, same justification. `Min_Size`: widest entry +
padding + glyph column, `LH + 8` tall. tdemo: a first/second/third
cycle in the Choices row, rotations report on the status line.

### `Gauge` (progress bar, M87a)
```ada
type Gauge is new Widget with record
   Num      : U64 := 0;
   Den      : U64 := 100;
   Show_Pct : Boolean := True;
end record;
function New_Gauge (Show_Pct : Boolean := True) return Any_Widget;
procedure Set_Fraction (W : in out Gauge; Num, Den : U64);
```

Workbench fuelgauge lineage: sunken frame, `Sel_Blue` fill
left→right, and (with `Show_Pct`) a centered `NN%` label drawn light
on the fill and dark on the empty half (two clip passes). Pure
display — no pointer or key handling. `Set_Fraction` treats
`Den = 0` as 1, clamps `Num` to `Den`, and marks the widget dirty
only when the rendered pixels actually change. `Min_Size` floors at
the `"100%"` label width + 16 and `Line_Height + 8` vertically.

tdemo's "Worker" group showcases it: Work clicks set 50%, the
worker task's completion message sets 100% (0% on failure).

## Layout container

### `Group`

```ada
type Group is new Widget with record
   Dir        : Direction := Vertical;
   Title      : String (1 .. 24);
   Title_Len  : Natural := 0;
   Inset      : Boolean := False;
   Kids       : Kid_Array := (others => null);
   Wts        : Wt_Array := (others => 1);
   N          : Natural := 0;
end record;
```

H/V layout container with optional frame and title breaking the top
edge. `Inset => True` draws a sunken frame and fills the interior with
`Pane` white.

Children are first granted their `Min_Size` in the layout direction
(M86g): every widget reports a content-driven floor derived from the
current font metrics (`Text_Width`/`Line_Height`), so a font change
re-flows the layout instead of overflowing frames. Only the
*remainder* over the summed minimums splits proportionally to each
child's `Weight` (MUI lineage) — weights express who gets the slack,
never who gives up content. If the minimums exceed the inner extent
(a huge user font), children keep their minimums and the canvas clip
takes the overflow. Default weight is 1; a tall listview might get 5
while surrounding buttons stay thin. Groups pin scrollbars to `Arrow`
in the cross axis before splitting the remainder (M87c: both
orientations, in either group direction; the cross axis centers).

```ada
type Direction is (Vertical, Horizontal);
Max_Children : constant := 12;

function New_Group
  (Dir : Direction; Title : String := ""; Inset : Boolean := False)
   return Any_Widget;
procedure Add (G : in out Group; Child : Any_Widget; Weight : U64 := 1);
```

`Layout` is called by `Trinket.Window.Run` before drawing. Pointer and
key events dispatch to children in reverse add order (`On_Key` walks
children backwards so focus/focused widgets see keys first).

## Listview

`Trinket.Listview` is a separate package because it carries its own
item storage.

```ada
type Listview is new Widgets.Widget with private;
type Any_Listview is access all Listview;
```

Vertical scrolling list of text items with selection. Ships with its
scrollbar attached via `New_Scrolled_List` (M87e).

```ada
function New_Listview
  (On_Change : Selected_Callback := null) return Any_Listview;

--  M87e: the list with its v-bar as one component (flush right,
--  self-wired). Preferred over bare New_Listview + Scrollbar.
function New_Scrolled_List
  (LV        : out Any_Listview;
   On_Change : Selected_Callback := null) return Widgets.Any_Widget;

procedure Clear (W : in out Listview);
procedure Add_Item (W : in out Listview; S : String);
procedure Set_Item_Icon
  (W : in out Listview; I : Positive;
   Icon : access constant Trinket.Images.Image);

function Item_Count (W : Listview) return Natural;
function Get_Item (W : Listview; I : Positive) return String;

procedure Set_Selected (W : in out Listview; I : Natural);
function Selected (W : Listview) return Natural;

procedure Set_Top (W : in out Listview; T : U64);
function Top (W : Listview) return U64;
function Visible_Rows (W : Listview) return U64;
function Max_Top (W : Listview) return U64;
```

- Selection is 1-based; `0` = none.
- `Set_Selected` scrolls the item into view and fires `On_Change` if
  it changed.
- `Icon_Size = 16`. The first `Set_Item_Icon` flips every row to icon
  height (`Icon_Size + 2`); the list borrows the image.

## Text editor widget

`Trinket.Text_Edit` is a separate package (own line storage, like
Listview) — the multi-line editor behind the edit app.

```ada
--  M87e: the editor with both bars as one component — v-bar
--  flush right, h-bar flush under the TEXT only (the corner
--  square stays window face). Self-wired; this is what apps use.
function New_Scrolled_Editor
  (Editor : out Any_Text_Edit) return Widgets.Any_Widget;

function New_Text_Edit return Widgets.Any_Widget;  --  bare

procedure Clear (W : in out Text_Edit);
procedure Append_Line (W : in out Text_Edit; S : String);
function Line_Count (W : Text_Edit) return Natural;
function Get_Line (W : Text_Edit; I : Natural) return String;
function Modified (W : Text_Edit) return Boolean;
procedure Clear_Modified (W : in out Text_Edit);

--  Scroll state (the composite reads/drives these itself)
procedure Set_Top (W : in out Text_Edit; T : U64);
function Top_Line (W : Text_Edit) return U64;
function Visible_Rows (W : Text_Edit) return U64;
procedure Set_HOff (W : in out Text_Edit; O : U64);  --  pixels
function H_Offset (W : Text_Edit) return U64;
function Max_HOff (W : Text_Edit) return U64;
function Visible_Width (W : Text_Edit) return U64;
```

- Fixed capacity: `Max_Lines` x `Max_Cols` per line.
- Full cursor/selection editing: arrows/Home/End/PgUp/PgDn,
  shift-selection, drag-select, insert/backspace/delete/enter.
- `Ensure_Cursor_Visible` auto-scrolls both axes on every handled
  key; the horizontal side scrolls in pixels (proportional font).
- M87c h-scroll rendering skips whole dropped characters plus a
  sub-char `Spill`, so text slides smoothly rather than jumping per
  character. `Locate` (click → cursor position) maps through `HOff`.
- Composite wiring: the bars' `On_Change` points at one
  package-level `Bar_Moved` with the editor in each bar's `Ctx`
  (the bar's `Dir` picks the axis); the content→bar direction
  re-syncs at the head of the composite's `Draw`, which is free
  because `Scrollbar.Set_Range`/`Set_Pos` no-op on unchanged
  metrics. The h-bar's `Step` is 8 (Pos units are pixels).

## Event dispatch notes

- `Trinket.Window.Run` reads Bureau input events and calls the root
  widget's `On_Pointer`/`On_Key`.
- `Group.On_Pointer` hit-tests children in reverse add order so the
  top-most widget gets the press.
- `Group.On_Key` walks children in reverse add order; focused inputs
  should sit late in the list so they see keys before transparent
  siblings.
- A widget that changes state sets `Dirty := True`. `Window.Run`
  unions all dirty rects into one band and calls `Draw` on the root
  with a `Canvas` clipped to that band.
