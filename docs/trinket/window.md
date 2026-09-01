# Trinket window lifecycle and event loop

`Trinket.Window` wraps the Bureau window protocol v3 and drives the
widget tree.

## Typical program shape

```ada
Win : Trinket.Window.Window;
Root : constant Trinket.Widgets.Any_Widget := ...;
begin
   if Trinket.Window.Open (Win, 3, 400, 300, "Demo", Root) then
      Trinket.Window.Run (Win);        --  blocks until close/quit
      Trinket.Window.Close (Win);
   end if;
end;
```

`3` is the uniform-ABI Bureau service endpoint handle.

## Opening a window

`Open` performs the following setup:

1. `Fonts.Init` loads the BDF font (falls back to compiled-in 8x8).
2. Allocates a one-page **input queue** memory object and maps it at
   `Queue_VA` (`0x5F00_0000`).
3. Creates a `Sink_EP` endpoint for the client side of the v3 async
   input channel, and a `Ntfn_Cap` notification bound to the calling
   thread.
4. Mints the queue cap with `Map+Read+Write+Transfer` and the
   notification cap with `Write+Transfer`.
5. Calls Bureau `Op_Surface_Create` (20). Bureau replies with the
   surface id and the number of 4 KiB pages needed.
6. Allocates the surface buffer in up to four 64-page **chunks** and
   maps them contiguously at `Surf_VA` (`0x5F80_0000`). Each chunk
   cap is minted `Map+Read+Transfer` and handed to Bureau via
   `Op_Surface_Set_Buffer` (21), then committed with
   `Op_Surface_Commit_Buffer` (22).
7. Sets the title (`Op_Set_Title`, 25).
8. Positions the root widget at `(0,0,w,h)` and calls its `Layout`.

If any step fails, `Open` returns `False` and releases what it already
allocated.

### Why chunked surface buffers?

A single `Mem_Alloc` can request at most 64 pages (256 KiB). A
1024x768 32-bit surface needs 3 MiB, so the buffer is split into
64-page chunks that are mapped contiguously in the client's address
space and handed to Bureau one by one.

## Event loop

`Run` loops until either Bureau sends a `close` event or the app calls
`Request_Quit`.

```
while running:
    Flush_Dirty()               --  repaint any damaged band
    IPC_Recv(Sink_EP)           --  blocks until notification/signal
    if message is a notification:
        drain input queue
        dispatch events
```

`IPC_Recv` is multiplexed: Bureau signals the bound notification when
input is available, and the synthetic notification message has
`Label = Notification_Label` (`U64'Last`). The queue is a ring
buffer shared between Bureau and the client; Bureau writes to `head`,
the client updates `tail`.

### Input queue layout

One 4 KiB page mapped at `Queue_VA`, interpreted as `Word_Array`:

| word | name | meaning |
| --- | --- | --- |
| 0 | `head` | producer write count (Bureau) |
| 1 | `tail` | consumer read count (client) |
| 2+ | ring | 2 words per event: `(kind, value)` |

`Input_Queue_Events = 255`. A slot is computed as
`2 + (tail mod 255) * 2`.

Event kinds (`Akernel_User.Window`):

| kind | value | meaning |
| --- | --- | --- |
| `Input_Event_Key` | 1 | `value` = ASCII/non-ASCII character code |
| `Input_Event_Pointer` | 2 | `value` = packed `(x, y, buttons)` |
| `Input_Event_Close` | 3 | close gadget clicked |
| `Input_Event_Menu` | 4 | `value` = menu item id |

### Pointer event packing

```
bits 0..15   = x
bits 16..31  = y
bits 32..39  = buttons (bit 0 = left)
```

`Trinket.Window.Run` converts the raw stream into `Press`/`Release`/
`Move` calls by comparing the current and previous button states.

### Pointer capture

Bureau v4 captures the pointer on a content press. Until all buttons
are released, every pointer event is delivered to the capturing
window even if the cursor leaves the content area; coordinates are
clamped to the content rect. This lets scrollbars and selection
widgets track drags and receive the final release.

## Dirty flush

`Flush_Dirty` collects the dirty rects with `Root.Dirty_List`
(intersecting rects merge into clusters), then per cluster: sets the
canvas clip, fills it with `Face`, calls `Root.Draw` (clipped to the
cluster), and sends one `Op_Surface_Update` RPC. Dirty flags are
cleared once at the end.

Multiple dirty widgets are therefore pushed as several narrow bands
per event loop iteration instead of one bounding band — two distant
dirty widgets no longer repaint everything between them. More than
`Max_Damage` (8) disjoint dirty rects overflows the list and degrades
to the old single `Dirty_Union` band.

## Menus

Screen-bar menus are chrome owned by Bureau (Amiga convention):

```ada
Trinket.Window.Set_Menus      (Win, My_Menu_Tree);
Trinket.Window.Set_Menu_Handler (Win, My_Handler'Access);
```

- `Set_Menus` serializes the tree with `Trinket.Menus.Serialize`,
  allocates a temporary one-page memobj at `Menu_VA`
  (`0x5F10_0000`), maps it, mints it `Map+Read+Transfer`, and calls
  Bureau `Op_Set_Menus` (27). The page is unmapped and deleted right
  after the call because Bureau copies the tree.
- The right mouse button is reserved to Bureau; window content never
  sees it.
- When the user picks an item, Bureau enqueues an
  `Input_Event_Menu` event carrying the 32-bit item id; the handler
  is called from inside `Run`.

## Closing

`Close` calls `Op_Surface_Destroy` (24) and marks the window record
closed. Process teardown reclaims the remaining memory objects and
endpoints.

## Threading (milestone 68)

Trinket follows the Swing/Amiga rule: only the event-dispatch
thread — the one running `Run` — touches the widget tree. Worker
tasks communicate with the UI through the window's **app port**, a
one-page kernel-free ring of 127 four-word messages
(`Code, A0, A1, A2`) in a process-shared memory object:

```ada
--  any thread:
Ok := Trinket.Window.Post (Win, Code, A0, A1, A2);   --  drop-new when full

--  before Run, on the loop thread:
Trinket.Window.Set_App_Handler (Win, My_Handler'Access);
--  My_Handler (Code, A0, A1, A2 : U64) runs ON THE LOOP THREAD,
--  once per queued message, FIFO.
```

`Post` is multi-producer safe (protected-object lock around the
ring), copies the message, and signals the loop thread's bound
notification (bit 2; Bureau input uses bit 1). `Run` drains the
port on every notification wake and dispatches each message to the
installed handler. `Request_Quit` is now just `Post` of the
reserved code 0, safe from any thread; quit codes are intercepted
by the drain and never reach the app handler. See
`userspace/tdemo` (Work button: click kicks a background worker
that loads/decodes an image off the event thread and Posts the
result; the handler swaps it into the widget tree with
`Widgets.Set_Image`) and the headless port test
`userspace/fuzz/fuzz_port`.

