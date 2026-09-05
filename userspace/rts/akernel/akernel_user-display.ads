with Akernel_User.Syscalls;

--  Display-service wire protocol (milestone 28, slice 1). A display
--  driver (today: Drivers/VirtioGpu) serves these labels on its
--  service endpoint alongside the stream labels (Op_Write etc.),
--  which is why the numbering starts at 10 — stream labels own
--  1..4. The compositor (Servers/Bureau) is the only intended
--  client; the device manager hands it the endpoint cap.
--
--  Direction rule (burned): IPC replies carry WORDS ONLY — caps
--  move caller -> callee. So the compositor ALLOCATES the
--  compositing buffer itself (Mem_Alloc chunks, max 64 pages
--  each, Mem_Map'ed contiguously) and PUSHES the chunk caps to
--  the display service with Op_Set_Buffer (Wayland wl_shm
--  direction). The driver re-attaches the scanout resource's
--  backing onto those pages at Op_Commit_Buffer; from then on
--  Op_Present bands copy straight from the compositor's buffer
--  (zero extra copy; TRANSFER_TO_HOST_2D reads the backing).
--
--  Chunk caps must arrive with the Manage right (the driver runs
--  Mem_Object_PA on them); the driver KEEPS the transferred caps
--  for the session so the frames outlive any compositor death —
--  deliberate exception to the per-op cap_delete rule (one-time
--  setup, 12 slots, not a per-request accumulator).
--
--  Message word layout (raw Message.Words; clients use IPC_Call,
--  the driver replies with Message words):
--
--  Op_Get_Info (10): request none.
--    reply w0 = Status_Ok, w1 = width, w2 = height,
--    w3 = stride (bytes per row = width*4, B8G8R8A8),
--    w4 = total buffer pages, w5 = max pages per memory object.
--
--  Op_Set_Buffer (11): request w0 = base chunk index,
--    caps 0..3 = up to 4 memory-object caps (chunk base*64 ..
--    covers the buffer in order).
--    reply w0 = Status_Ok / Status_Bad_Index.
--
--  Op_Commit_Buffer (12): request none. Detaches the driver's
--    own boot framebuffer backing, attaches the stored chunks,
--    pushes one full-screen TRANSFER + FLUSH.
--    reply w0 = Status_Ok / Status_No_Buffer / Status_Bad_Caps.
--
--  Op_Present (13): request w0 = x, w1 = y, w2 = w, w3 = h
--    (pixel band, clamped to the mode; empty bands are no-ops).
--    TRANSFER_TO_HOST_2D + RESOURCE_FLUSH for the band.
--    reply w0 = Status_Ok.
--
--  Op_Set_Cursor (14) / Op_Move_Cursor (15): reserved for the
--  hardware cursor (virtio cursorq UPDATE_CURSOR 0x300 /
--  MOVE_CURSOR 0x301), slice 4.
--
--  Op_Set_Mode (16): request w0 = width, w1 = height (M90).
--    Must fit the driver's static [640x480 .. 1920x1080] clamp
--    or Status_Bad_Mode comes back (geometry words then hold the
--    CURRENT mode). On success the driver DELETES any stored
--    compositor chunk caps (they describe the old geometry — the
--    compositor re-pushes with Op_Set_Buffer), destroys and
--    re-creates the scanout resource, re-attaches its own boot
--    framebuffer (extending the allocation when the new mode
--    needs more pages) and clears to black. The compositor then
--    repeats its boot dance: Set_Buffer x N + Commit_Buffer.
--    reply w0 = Status_Ok / Status_Bad_Mode / Status_Device,
--    w1..w5 = geometry, same layout as Op_Get_Info.

package Akernel_User.Display is
   subtype U64 is Syscalls.U64;

   Op_Get_Info      : constant U64 := 10;
   Op_Set_Buffer    : constant U64 := 11;
   Op_Commit_Buffer : constant U64 := 12;
   Op_Present       : constant U64 := 13;
   Op_Set_Cursor    : constant U64 := 14;  --  reserved
   Op_Move_Cursor   : constant U64 := 15;  --  reserved
   Op_Set_Mode      : constant U64 := 16;  --  M90

   Status_Ok         : constant U64 := 0;
   Status_Bad_Index  : constant U64 := 1;
   Status_No_Buffer  : constant U64 := 2;
   Status_Bad_Caps   : constant U64 := 3;
   Status_Device     : constant U64 := 4;
   Status_Bad_Mode   : constant U64 := 5;  --  M90

   --  Client-side helpers (compositor). Get_Info returns the
   --  mode geometry; Set_Buffer pushes up to 4 chunk caps per
   --  call (Base = first chunk index covered by this call);
   --  Commit_Buffer swaps the scanout backing; Present pushes a
   --  pixel band. All return a Status_* code.
   function Get_Info
     (EP                    : U64;
      Width, Height, Stride : out U64;
      Total_Pages           : out U64) return U64;
   function Set_Buffer
     (EP   : U64;
      Base : U64;
      C0   : U64;
      C1   : U64 := 0;
      C2   : U64 := 0;
      C3   : U64 := 0) return U64;
    function Commit_Buffer (EP : U64) return U64;
    function Present
      (EP      : U64;
       X, Y, W : U64;
       H       : U64) return U64;
    --  M90: switch the scanout mode. On Status_Ok the out
    --  parameters carry the NEW geometry (the compositor rebuilds
    --  its buffer from Total_Pages and re-pushes chunks).
    function Set_Mode
      (EP                    : U64;
       Req_W, Req_H          : U64;
       Width, Height, Stride : out U64;
       Total_Pages           : out U64) return U64;
end Akernel_User.Display;
