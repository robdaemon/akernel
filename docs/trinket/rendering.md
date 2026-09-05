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

1. Calls `Root.Dirty_List` to collect each dirty widget's rect,
   merging intersecting ones into clusters (max `Max_Damage` = 8;
   overflow degrades to the `Dirty_Union` bounding rectangle).
2. Per cluster: fills the rect with `Trinket.Face` to erase old
   pixels, calls `Root.Draw` with the canvas clipped to it, and sends
   one `Op_Surface_Update` RPC.
3. Calls `Root.Clear_Dirty` once all bands are pushed.

Containers override `Dirty_List`/`Dirty_Union` to recurse into their
children (a dirty group contributes its whole extent — the kids sit
inside it) and `Clear_Dirty` to recurse. Widgets should mark themselves
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
falls back to a compiled-in 8x8 font if loading fails. The default UI
font is `font8x8p.bdf` (M86f): the same 8x8 glyphs trimmed to their
ink bounds with a 1px gap, so `Draw_Text`/`Text_Width` advance by
per-glyph `DWIDTH` (pseudo-proportional, MUI XEN-font look). Bureau
chrome stays monospace and does not use this package.

```ada
procedure Init (Path : String := "Sys:Fonts/font8x8p.bdf");
function Loaded_From_Disk return Boolean;
function Line_Height return U64;
function Text_Width (S : String) return U64;
procedure Draw_Text (C : Canvas; X, Y : U64; S : String; FG : Pixel);
procedure Draw_Text_Mono (C : Canvas; X, Y : U64; S : String; FG : Pixel);
```

- `Y` is the line top; glyph bitmaps are placed at their BDF baseline
  offsets.
- `Draw_Text` has transparent background; the caller must fill the
  field or band first.
- `Draw_Text_Mono` renders the compiled-in untrimmed 8x8 glyphs on
  fixed 8px advances — for grid devices (the terminal), where cell
  alignment matters more than look.
- `Init` latches: the first call fixes the global font for the
  process's lifetime, so a saved font change applies to apps
  launched afterwards. `Init` consults `ENV:Font` (M89) before the
  default path — that is the Prefs/Font save target.

M89 additions:

```ada
type Handle is private;                 --  private font instance
function Load (Path : String) return Handle;
procedure Unload (H : in out Handle);
function Line_Height (H : Handle) return U64;
function Text_Width (H : Handle; S : String) return U64;
procedure Draw_Text (C : Canvas; H : Handle; X, Y : U64; S : String; FG : Pixel);
procedure Draw_Glyph (C : Canvas; H : Handle; CP : Natural; X, Y : U64; FG : Pixel);
procedure Probe (Path : String; Family : out String; Family_Len : out Natural;
                 Pixel_Size : out Natural; OK : out Boolean);
```

- `Load`/`Unload` give callers a heap font off the global latch —
  the Prefs/Font live preview renders with one while the UI keeps
  the global font.
- Glyph coverage reaches codepoint 16#25FF# (Latin-1, box drawing,
  block elements, geometric shapes) through a sparse extension
  table; `Draw_Glyph`/`Has_Glyph` (global and per-handle) address
  any codepoint. Bytes 16#A0#..16#FF# in `Draw_Text` map straight
  to Latin-1.
- `Probe` reads only the BDF header properties (`FAMILY_NAME`,
  `PIXEL_SIZE`) so listings can group fonts without loading them.
- Files larger than the fs one-shot read buffer load in a loop —
  full Terminus BDFs (~180 KiB) parse whole. The pre-M89 64 KiB
  "font cap" was that one-shot read semantic, and `Files.Open`
  needs the fs endpoint bound — Fonts binds handle 2 lazily if
  the program hasn't (never clobbering a custom binding).

The fonts shipped in `Sys:Fonts/`: `font8x8.bdf` (mono 8x8),
`font8x8p.bdf` (pseudo-proportional 8), `font8x8t.bdf` (8x16,
rows doubled — same family, second size), and Terminus
`ter-u12n/14n/16n.bdf` (OFL, sha256-pinned third_party fetch,
license at `Sys:Fonts/OFL.TXT`).

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
