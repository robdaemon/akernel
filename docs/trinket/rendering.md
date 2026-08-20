# Trinket rendering model

Trinket is a client-side software renderer. The application owns a
linear 32-bit pixel buffer; Trinket draws into it, then asks Bureau to
copy a damaged band to the screen.

## Pixel format

`Trinket.Pixel = Interfaces.Unsigned_32`, little-endian `AARRGGBB`.
The alpha byte is mostly ignored by the current rasterizer except for
color-key transparency in images. Bureau's own chrome uses the same
palette constants defined in `Trinket` so gadget faces match the window
frame.

## Canvas and clipping

```ada
type Canvas is record
   Base     : System.Address := System.Null_Address;
   W, H     : U64 := 0;
   CX0, CY0 : U64 := 0;
   CX1, CY1 : U64 := 0;
end record;
```

- `Base` points to the top-left pixel of the mapped surface buffer.
- `W,H` are the full surface dimensions.
- `(CX0,CY0) .. (CX1,CY1)` is the half-open clip rectangle.

Every draw operation clips output to `[CX0,CX1) x [CY0,CY1)`.
`Set_Clip` intersects a new rectangle with the current clip.
`Reset_Clip` restores the full surface rect.

`Trinket.Window.Run` sets the clip to the current damage band before
calling `Root.Draw`.

## Damage model

A widget sets `Dirty := True` whenever its appearance changes. Before
each blocking input receive, `Trinket.Window.Flush_Dirty`:

1. Calls `Root.Dirty_Union` to get one bounding rectangle covering all
   dirty widgets.
2. Fills that rectangle with `Trinket.Face` to erase old pixels.
3. Calls `Root.Draw` with the canvas clipped to the damage band.
4. Calls `Root.Clear_Dirty`.
5. Sends one `Op_Surface_Update` RPC for the band.

Containers override `Dirty_Union` to union their children's dirty
rectangles and `Clear_Dirty` to recurse. Widgets should mark themselves
dirty when state changes; the window coalesces updates automatically.

## Paint primitives

`Trinket.Paint` provides low-level geometry:

### `Fill_Rect`

```ada
procedure Fill_Rect (C : Canvas; X0, Y0, X1, Y1 : U64; Col : Pixel);
```

Fills a half-open rectangle with `Col`, clipped to the canvas clip.
This is the erase used before redrawing a damage band.

### `Bevel2`

```ada
procedure Bevel2
  (C : Canvas; X0, Y0, X1, Y1 : U64; Raised : Boolean := True);
```

Draws a Workbench-3.x double-ridge bevel frame: a black outer border,
white top-left highlight, and dark-gray/black bottom-right shadow.
`Raised => False` inverts the inner highlight/shadow for a sunken
look. The interior is **not** filled; callers fill with `Pane` or
`Face` first.

Widgets combine `Fill_Rect` + `Bevel2` to draw buttons, input fields,
scrollbars, and group frames.

## Text

`Trinket.Fonts` loads BDF bitmap fonts from `Sys:Fonts/*.bdf` and
falls back to a compiled-in 8x8 font if loading fails.

```ada
procedure Init (Path : String := "Sys:Fonts/font8x8.bdf");
function Loaded_From_Disk return Boolean;
function Line_Height return U64;
function Text_Width (S : String) return U64;
procedure Draw_Text (C : Canvas; X, Y : U64; S : String; FG : Pixel);
```

- `Y` is the line top; glyph bitmaps are placed at their BDF baseline
  offsets.
- `Draw_Text` has transparent background; the caller must fill the
  field or band first.
- `Init` is idempotent and can be called again to reload a font.

## Images

`Trinket.Images` implements Amiga datatypes-style loading:

```ada
procedure Load (Path : String; Img : out Image; St : out Status);
procedure Free (Img : in out Image);
procedure Blit (C : Canvas; Img : Image; DX, DY : U64);
```

- `Load` sniffs the magic bytes and dispatches to the appropriate
  decoder (`Bmp`, `Xpm`; `ILBM` slots in as a sibling).
- Decoded pixels are chunky `AARRGGBB`, row-major in `Img.Data`.
- `Blit` copies the image top-left to `(DX, DY)`, clipped to the
  canvas, with optional color-key transparency:
  - `Has_Key => True` means pixels equal to `Key` are skipped.
  - `Xpm` sets the key automatically for `"None"` transparent pixels.
  - `Bmp` does **not** set a key; 32-bit alpha bytes are preserved but
    not blended. The client can set `Has_Key` and `Key` manually.
- No scaling, no blending. Future backends can replace the decoder
  without changing this API.

`Image_Widget` simply centers an `Image` inside its layout rect and
lets the clip rectangle handle the rest.

## Coordinate system

All widget geometry is **content-absolute** inside the window: `(0,0)`
is the top-left of the usable pane below the title bar. Bureau strips
the title bar and border before delivering pointer events, so widgets
can hit-test against their own `X/Y/W/H` directly.
