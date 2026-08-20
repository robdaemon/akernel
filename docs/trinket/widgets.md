# Trinket widget catalogue

This page lists the widgets available in `userspace/trinket/`.
Coordinates and sizes are `U64` (unsigned 64-bit), measured in pixels,
and are **content-absolute** inside the window.

## Base types

### `Trinket.Pixel`

`subtype Pixel is Interfaces.Unsigned_32;` — little-endian `AARRGGBB`.

Palette constants (match Bureau chrome):

| name | value | use |
|---|---|---|
| `Face` | `16#FFC0_C0C4#` | gadget face |
| `Bevel_Hi` | `16#FFFF_FFFF#` | highlight bevel |
| `Bevel_Lo` | `16#FF40_4040#` | shadow bevel |
| `Border` | `16#FF10_1010#` | thin border |
| `Pane` | `16#FFFF_FFFF#` | editable field background |
| `Sel_Blue` | `16#FF60_68B0#` | selection |
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
| `Draw (W : Widget; C : Canvas) is abstract` | paint into clipped canvas |
| `On_Pointer (W : access Widget; K : Pointer_Kind; PX, PY : U64) return Boolean` | pointer event; default unconsumed |
| `On_Key (W : access Widget; Code : U64) return Boolean` | key event; default unconsumed |
| `Inside (W : Widget; PX, PY : U64) return Boolean` | hit test against `W`'s rect |
| `Dirty_Union` / `Clear_Dirty` / `Intersects` | damage-band bookkeeping |

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
   On_Click : Click_Callback := null;
end record;
```

Raised face, sunken while pressed, centered label. Fires `On_Click`
on release inside the button.

```ada
type Click_Callback is access procedure;

function New_Button
  (S : String; On_Click : Click_Callback := null) return Any_Widget;
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
fires on Enter.

Keys are consumed **only while focused**, so sibling widgets (e.g. a
listview's arrows) keep working when focus is elsewhere.

```ada
function New_Input return Any_Widget;
function Get_Text (W : Input) return String;
procedure Set_Text (W : in out Input; S : String);
procedure Set_Focused (W : in out Input; F : Boolean);
function Is_Focused (W : Input) return Boolean;
```

### `Scrollbar` (vertical)

```ada
type Scrollbar is new Widget with record
   Min       : U64 := 0;
   Max       : U64 := 0;
   Visible   : U64 := 1;
   Pos       : U64 := 0;
   On_Change : Change_Callback := null;
   Dragging  : Boolean := False;
   Grab_DY   : U64 := 0;
end record;
```

Vertical scrollbar. Sunken track, arrow boxes, proportional striped
knob. Pointer capture (Bureau v4) delivers drag and release outside the
window. `On_Change` fires **only for user moves**, not for
programmatic `Set_Pos`.

```ada
type Change_Callback is access procedure (Pos : U64);

function New_Scrollbar
  (On_Change : Change_Callback := null) return Any_Widget;

procedure Set_Range
  (W : in out Scrollbar; Min, Max, Visible : U64);
procedure Set_Pos (W : in out Scrollbar; P : U64);
```

`Set_Range` clamps `Pos` and marks dirty without firing `On_Change`.

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
```

See also `Trinket.Images` (Bmp/Xpm loaders) and `Trinket.Paint.Blit`.

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

Children share the group's extent in the layout direction
proportionally to their `Weight` (MUI lineage). Default weight is 1;
a tall listview might get 5 while surrounding buttons stay thin.
Horizontal groups pin scrollbars to arrow-width before splitting the
remainder.

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

Vertical scrolling list of text items with selection. Designed to pair
with a `Scrollbar` in a horizontal `Group`.

```ada
function New_Listview
  (On_Change : Selected_Callback := null) return Any_Listview;

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
