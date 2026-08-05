with Akernel_User.Syscalls;

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
--
--  Up to 4 windows. Bureau owns stacking, focus
--  (click-to-focus/raise), title dragging and per-window
--  titles.
--
--  Message words (raw Message.Words):
--    Op_Surface_Create (20): w0 = width, w1 = height (content
--      pixels requested); caps 0 = input queue memobj cap,
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
--    Op_Key (30): w0 = character code (translated by the
--      keyboard driver's keymap). Reply w0 = status.
--    Op_Pointer (31): w0 = x, w1 = y (raw absolute tablet
--      coords, 0..32767 — Bureau scales to the mode), w2 =
--      button bits (0 = left). Reply w0 = status.

package Akernel_User.Window is
   subtype U64 is Syscalls.U64;

   Op_Surface_Create        : constant U64 := 20;
   Op_Surface_Set_Buffer    : constant U64 := 21;
   Op_Surface_Commit_Buffer : constant U64 := 22;
   Op_Surface_Update        : constant U64 := 23;
   Op_Surface_Destroy       : constant U64 := 24;
   Op_Set_Title             : constant U64 := 25;
   Op_Set_Focus             : constant U64 := 26;
   Op_Key                   : constant U64 := 30;
   Op_Pointer               : constant U64 := 31;

   Status_Ok        : constant U64 := 0;
   Status_No_Slot   : constant U64 := 1;
   Status_Bad_Id    : constant U64 := 2;
   Status_Bad_Index : constant U64 := 3;
   Status_Bad_Caps  : constant U64 := 4;
   Status_Device    : constant U64 := 5;

   --  Input queue (v3): one page, u64 words; see the header.
   Input_Queue_Head   : constant := 0;  --  word index
   Input_Queue_Tail   : constant := 1;  --  word index
   Input_Queue_First  : constant := 2;  --  first event word
   Input_Queue_Events : constant := 255;  --  (512 - 2) / 2
   Input_Event_Key    : constant U64 := 1;
   Input_Signal_Bit   : constant U64 := 1;

   --  Client-side helpers (raw IPC_Call; replies are words-only).
   function Surface_Create
     (EP             : U64;
      Width, Height  : U64;
      Queue_Cap      : U64 := 0;
      Ntfn_Cap       : U64 := 0;
      Id, Pages      : out U64;
      Grant_W        : out U64;
      Grant_H        : out U64) return U64;
   function Surface_Set_Title
     (EP : U64; Id : U64; S : String) return U64;
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
   function Surface_Update
     (EP      : U64;
      Id      : U64;
      X, Y, W : U64;
      H       : U64) return U64;
end Akernel_User.Window;
