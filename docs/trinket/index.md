# Trinket GUI toolkit documentation

Trinket is the userspace retained-mode widget toolkit. It renders
client-side into Bureau window surfaces; Bureau owns the chrome,
focus, pointer capture, and menu bar.

- `docs/trinket/widgets.md` — widget catalogue and event model
- `docs/trinket/window.md` — window/event-loop lifecycle
- `docs/trinket/rendering.md` — canvas, clipping, and damage bands

Core packages:

| package | purpose |
|---|---|
| `Trinket` | pixel types, palette, navigation-key codes, `Canvas` |
| `Trinket.Widgets` | abstract `Widget`, concrete gadgets, `Group` layout |
| `Trinket.Listview` | scrolling selectable text list with optional icons |
| `Trinket.Images` | datatype-style image loader (`Bmp`, `Xpm`) |
| `Trinket.Paint` | span/fill/blit primitives used by widgets |
| `Trinket.Menus` | Amiga-style screen-bar menu tree serializer |
| `Trinket.Window` | Bureau surface lifecycle and blocking event loop |

Event model summary:

- `On_Pointer`/`On_Key` are dispatched from `Trinket.Window.Run` to
  the focused/under-cursor widget. Return `True` to consume the event.
- A widget marks itself `Dirty := True`; `Dirty_Union` builds one
  damage band, then `Draw` is called with a `Canvas` clipped to that
  band. Multiple dirty widgets are coalesced into a single
  `Surface_Update` RPC.
- Pointer events use **content-absolute** coordinates; Bureau delivers
  them relative to the window content origin.
