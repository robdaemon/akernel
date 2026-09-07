with Akernel_User.Syscalls;
use type Akernel_User.Syscalls.U64;

--  Bureau window protocol v3 (milestone 31). Clients
--  (terminal, demos) talk to Bureau's window-service endpoint.
--  Same direction rule as the display service: caps move caller
--  -> callee only, so the CLIENT allocates its surface buffer
--  (Mem_Alloc 64-page chunks) and pushes the chunk caps to
--  Bureau; Bureau Mem_Maps them (Map+Read rights required) and
--  copies damaged bands into the compositing buffer at the
--  window's pane origin (wl_shm model), then Presents the band
--  to the display service.
--
--  v3: input delivery is ASYNCHRONOUS (Amiga message-port
--  model: shared memory + notification, docs/IPC.md). v2
--  forwarded focused keys with a blocking rendezvous into the
--  client's input endpoint while clients rendezvous back with
--  Surface_Update — any overlap deadlocked the pair (burned in
--  milestone 31: one key in, GUI wedged, console server
--  cascade-stalled behind the terminal sink). Now each client
--  pushes at Surface_Create:
--    caps 0 = input queue memory object, ONE page (Map+Read+
--             Write+Transfer), Bureau maps it RW
--    caps 1 = notification cap (Write+Transfer), bound to the
--             client's service thread; Bureau signals bit 1
--             after enqueueing
--  Bureau enqueues focused-key events and signals — it NEVER
--  calls the client. The client's IPC_Recv multiplexes the
--  synthetic notification message (rng-style) with its normal
--  service traffic and drains the queue at its own pace,
--  outside any rendezvous with Bureau.
--
--  Input queue layout (one page, u64 words):
--    word 0: head  (producer = Bureau, monotonic write count)
--    word 1: tail  (consumer = client, monotonic read count)
--    words 2..: event ring, 2 words per event: (kind, value),
--    slot = head mod Input_Queue_Events. Empty: head = tail.
--    Full (head - tail = Input_Queue_Events): drop-new.
--    kind 1 = key (value = character code).
--    kind 2 = pointer (value = content-relative packed state:
--    bits 0..15 = x, 16..31 = y, 32..39 = buttons; delivered
--    only while the pointer is inside the window content and
--    no title drag is active; consecutive pointer events WITH
--    THE SAME button state are COALESCED in place so moves
--    cannot flood the ring — a press/release edge always lands
--    as its own event).
--    v4 (milestone 57): a press inside the content CAPTURES
--    the pointer: until buttons go 0 every move and the final
--    release are delivered to the capturing window even
--    outside the content, coordinates clamped to content
--    bounds. Clients can drag (scrollbar knobs, text
--    selection) without losing the release.
--    kind 3 = close (value unused): the close gadget was
--    clicked — the CLOSEWINDOW analog. The client is expected
--    to Surface_Destroy and exit; Bureau never kills the
--    window itself.
--    kind 4 = menu (value = item Id, milestone 61): a menu
--    item was picked from the screen-bar menus this window
--    declared with Op_Set_Menus.
--    kind 5 = resize (v5; value = requested content size, Pack_Size
--    packing): the zoom gadget was clicked. Only sent to windows
--    created with Flag_Resizable. The client answers with
--    Op_Surface_Resize + a fresh Set_Buffer/Commit_Buffer cycle
--    (below); until it does, the window's geometry is unchanged.
--
--  Zoom / resize (v5): the zoom title gadget toggles a resizable
--  window between its saved rect and the full screen below the
--  bar. Bureau owns the target geometry (it applies the saved or
--  full-screen position when the ack lands); the client owns the
--  pixels. Handshake, no rendezvous: Bureau enqueues kind 5 and
--  applies NOTHING until the client calls Op_Surface_Resize —
--  a client that never answers leaves the window untouched.
--    Op_Surface_Resize (28): w0 = surface id, w1 = content width,
--      w2 = content height (the kind-5 values, echoed). Bureau
--      clamps like create, tears down the old chunk mappings +
--      caps (Destroy discipline), updates the frame (position
--      from its pending zoom target), and replies w0 = status,
--      w1 = pages needed, w2 = granted width, w3 = granted
--      height. The client then reallocs its chunks and pushes
--      them with the ordinary Set_Buffer/Commit_Buffer ops
--      (Set_Buffer accepts caps again once the old buffer is
--      torn down). Between resize and commit the pane draws
--      blank, exactly like a not-yet-committed new window.
--
--  Menus (milestone 61, Amiga screen-bar lineage): menus are
--  CHROME — the client declares a tree, Bureau renders the bar
--  and dropdowns above all windows and owns the whole
--  interaction. The RIGHT mouse button is reserved to Bureau
--  (Amiga convention; window content never sees it): RMB down
--  opens the focused window's menu bar, holding it tracks
--  titles/items, releasing over an item picks it (classic
--  drag-select); releasing anywhere else leaves the bar OPEN
--  (sticky — touchpads), then hover switches dropdowns, a
--  left-click picks, and left-click elsewhere / RMB again /
--  Esc / focus loss dismisses. The tree crosses as a
--  serialized one-page memory object and is COPIED into Bureau
--  at set time (Bureau never re-reads client memory).
--    Op_Set_Menus (27): w0 = surface id; caps 0 = one-page
--      memobj (Map+Read+Transfer) holding the tree below;
--      caps 0 = 0 clears the window's menus. Reply w0 =
--      status. Page layout (u64 words, little-endian byte
--      packing like Op_Set_Title):
--        word 0 = menu count M (1..8), word 1 = item count N
--        (1..32). Then M menu records of 4 words: w0..w1 =
--        title (16 bytes), w2 = first item index (0-based
--        into the item records), w3 = item count. Then N item
--        records of 5 words: w0..w2 = label (24 bytes), w3 =
--        item Id (bits 0..31, echoed in the kind-4 event) |
--        flags (bit 32 = disabled/ghosted, bit 33 =
--        separator row), w4 = shortcut (bits 0..7 = character
--        code to match, bit 8 = Ctrl, bit 9 = Alt; 0 = no
--        shortcut). Separators have no Id and are never
--        hovered, picked or accelerated.
--
--  Up to 6 windows. Bureau owns stacking, focus
--  (click-to-focus/raise), title dragging and per-window
--  titles.
--
--  Message words (raw Message.Words):
--    Op_Surface_Create (20): w0 = width, w1 = height (content
--      pixels requested); w2 = flags (v5: bit 0 = Flag_Resizable,
--      the client handles kind-5 resize events; zoom gadget is
--      ghosted without it); caps 0 = input queue memobj cap,
--      caps 1 = input notification cap (0/0 = no input).
--      Reply w0 = status, w1 = surface id, w2 = pages needed,
--      w3 = granted width, w4 = granted height.
--    Op_Surface_Set_Buffer (21): w0 = surface id, w1 = base
--      chunk index; caps 0..3 = up to 4 chunk caps (Map+Read+
--      Transfer rights). Reply w0 = status.
--    Op_Surface_Commit_Buffer (22): w0 = surface id. Bureau
--      maps the chunks read-only. Reply w0 = status.
--    Op_Surface_Update (23): w0 = surface id, w1 = x, w2 = y,
--      w3 = w, w4 = h (damaged band in surface coords; clamped).
--      Bureau copies the band and presents it. Reply w0 = status.
--    Op_Surface_Destroy (24): w0 = surface id. Bureau unmaps +
--      deletes the chunk caps, frees the slot, repaints.
--    Op_Set_Title (25): w0 = surface id, w1..w5 = title text
--      (up to 40 bytes, little-endian byte packing). Reply
--      w0 = status.
--
--  Seat (milestone 28 slice 4): the virtio-input drivers push
--  events to Bureau (Op_Key / Op_Pointer) once devmgr hands
--  them Bureau's endpoint (seat-config message on their service
--  endpoint). Bureau enqueues keys into the FOCUSED window's
--  input queue (v3, above) and software-sprites the pointer
--  (hw cursor ops stay reserved in the display protocol; the
--  software sprite is the arch-independent fallback by
--  design). Op_Set_Focus (26) from the v1 devmgr wiring is
--  obsolete since v2 (focus is Bureau-internal) but still
--  answered.
--    Op_Set_Focus (26): caps 0 = focused client's stream
--      endpoint (Send+Transfer). Reply w0 = status.
--    Op_Key (30): w0 = character code (translated by the keyboard
--      driver's keymap); w1 = qualifier bits held at keypress
--      (bit 0 = Ctrl, bit 1 = Alt — Shift is folded into the
--      character by the keymaps and never appears here). Reply
--      w0 = status.
--    Op_Pointer (31): w0 = x, w1 = y (raw absolute tablet
--      coords, 0..32767 — Bureau scales to the mode), w2 =
--      button bits (0 = left). Reply w0 = status.
--
--  Screen mode (M90): runtime geometry switch, Amiga ScreenMode
--  prefs lineage.
--    Op_Set_Screen_Mode (32): w0 = width, w1 = height; 0/0 is a
--      pure query. A real request goes Bureau -> display service
--      (Op_Set_Mode): the scanout resource is recreated, Bureau
--      tears down and rebuilds the compositing buffer for the new
--      geometry (old frames return to the PMM on last-cap close),
--      window origins clamp into the new screen, and the full
--      frame repaints. Client surface buffers are untouched.
--      Reply w0 = status (Status_Bad_Mode when the driver rejects
--      the geometry), w1 = current width, w2 = current height —
--      the actual mode AFTER the call, so a rejected switch still
--      answers the query.
--
--  Desktop windows (M91): two create flags make a client window
--  behave like the Workbench backdrop.
--    Flag_Borderless (w2 bit 1): no frame/title/gadgets — FW=PW,
--      the pane is the whole window. No title drag, no close,
--      no zoom (there is no chrome to hit).
--    Flag_Backdrop (w2 bit 2): a content click focuses but NEVER
--      raises — the window stays below every normal window.
--    w3/w4 = requested frame X/Y (0,0 = Bureau cascade, the old
--      behavior; honored only when one of the new flags is set,
--      so pre-M91 clients that zero the words are unaffected).
--    Screen-mode switches (M90) enqueue a kind-6 event
--      (Input_Event_Screen_Mode, value = Pack_Size of the new
--      content target) into BACKDROP windows' queues; Bureau
--      owns the target position (0, Bar_H+1) through the same
--      pending-geometry machinery as zoom, and the client acks
--      with Op_Surface_Resize exactly like a kind-5 resize.
--    The screen bar height is part of the geometry contract
--      (a backdrop's initial open needs it): Screen_Bar_H.

package Akernel_User.Window is
   subtype U64 is Syscalls.U64;

    Op_Surface_Create        : constant U64 := 20;
    Op_Surface_Set_Buffer    : constant U64 := 21;
    Op_Surface_Commit_Buffer : constant U64 := 22;
    Op_Surface_Update        : constant U64 := 23;
    Op_Surface_Destroy       : constant U64 := 24;
    Op_Set_Title             : constant U64 := 25;
    Op_Set_Focus             : constant U64 := 26;
    Op_Set_Menus             : constant U64 := 27;
    Op_Surface_Resize        : constant U64 := 28;  --  v5
    Op_Key                   : constant U64 := 30;
    Op_Pointer               : constant U64 := 31;
    Op_Set_Screen_Mode       : constant U64 := 32;  --  M90

    --  Op_Surface_Create w2 flags (v5).
    Flag_Resizable : constant U64 := 1;
    Flag_Backdrop  : constant U64 := 2;  --  M91: never raises
    Flag_Borderless : constant U64 := 4; --  M91: no chrome

   Status_Ok        : constant U64 := 0;
   Status_No_Slot   : constant U64 := 1;
   Status_Bad_Id    : constant U64 := 2;
   Status_Bad_Index : constant U64 := 3;
   Status_Bad_Caps  : constant U64 := 4;
   Status_Device    : constant U64 := 5;
   Status_Bad_Mode  : constant U64 := 6;  --  M90

   --  Input queue (v3): one page, u64 words; see the header.
   Input_Queue_Head   : constant := 0;  --  word index
   Input_Queue_Tail   : constant := 1;  --  word index
   Input_Queue_First  : constant := 2;  --  first event word
   Input_Queue_Events : constant := 255;  --  (512 - 2) / 2
    Input_Event_Key    : constant U64 := 1;
    Input_Event_Pointer : constant U64 := 2;
    Input_Event_Close  : constant U64 := 3;
    Input_Event_Menu   : constant U64 := 4;
    Input_Event_Resize : constant U64 := 5;  --  v5, Pack_Size value
    Input_Event_Screen_Mode : constant U64 := 6;  --  M91, backdrop only
    Input_Signal_Bit   : constant U64 := 1;

    --  Bureau's screen bar height (M92): a backdrop window's
    --  initial frame is (0, Screen_Bar_H + 1) with height
    --  Screen_H - Screen_Bar_H - 1; later mode switches arrive
    --  as kind-6 events with Bureau-computed targets.
    Screen_Bar_H : constant U64 := 18;

    --  Pointer event value packing (content-relative).
    function Pack_Pointer (X, Y, Buttons : U64) return U64 is
      ((X and 16#FFFF#) or ((Y and 16#FFFF#) * 2**16)
       or ((Buttons and 16#FF#) * 2**32));
    function Pointer_X (V : U64) return U64 is (V and 16#FFFF#);
    function Pointer_Y (V : U64) return U64 is
      ((V / 2**16) and 16#FFFF#);
    function Pointer_Buttons (V : U64) return U64 is
      ((V / 2**32) and 16#FF#);

    --  Resize event value packing (v5): content pixel size.
    function Pack_Size (W, H : U64) return U64 is
      ((W and 16#FFFF#) or ((H and 16#FFFF#) * 2**16));
    function Size_W (V : U64) return U64 is (V and 16#FFFF#);
    function Size_H (V : U64) return U64 is
      ((V / 2**16) and 16#FFFF#);

    --  Client-side helpers (raw IPC_Call; replies are words-only).
    --  M91: Pos_X/Pos_Y request a frame position (0,0 = cascade;
    --  honored only with Flag_Backdrop/Flag_Borderless).
    function Surface_Create
      (EP             : U64;
       Width, Height  : U64;
       Queue_Cap      : U64 := 0;
       Ntfn_Cap       : U64 := 0;
       Id, Pages      : out U64;
       Grant_W        : out U64;
       Grant_H        : out U64;
       Flags          : U64 := 0;
       Pos_X, Pos_Y   : U64 := 0) return U64;
   function Surface_Set_Title
     (EP : U64; Id : U64; S : String) return U64;
   function Surface_Set_Menus
     (EP : U64; Id : U64; Page_Cap : U64) return U64;
   --  Page_Cap = one-page memobj (Map+Read+Transfer) with the
   --  serialized menu tree, or 0 to clear.
   function Surface_Destroy (EP : U64; Id : U64) return U64;
   function Surface_Set_Buffer
     (EP   : U64;
      Id   : U64;
      Base : U64;
      C0   : U64;
      C1   : U64 := 0;
      C2   : U64 := 0;
      C3   : U64 := 0) return U64;
    function Surface_Commit_Buffer (EP : U64; Id : U64) return U64;
    function Surface_Resize
      (EP             : U64;
       Id             : U64;
       Width, Height  : U64;
       Pages          : out U64;
       Grant_W        : out U64;
       Grant_H        : out U64) return U64;
    --  v5: answer a kind-5 resize event. Tears down the current
    --  buffer server-side; follow with Set_Buffer/Commit_Buffer.
    function Surface_Update
     (EP      : U64;
      Id      : U64;
      X, Y, W : U64;
      H       : U64) return U64;
    --  M90: query (Width = Height = 0) or switch the screen mode.
    --  Cur_W/Cur_H always come back with the mode in effect
    --  after the call.
    function Set_Screen_Mode
      (EP            : U64;
       Width, Height : U64;
       Cur_W, Cur_H  : out U64) return U64;
end Akernel_User.Window;
