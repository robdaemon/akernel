with Akernel_User.Syscalls;

--  Bureau window protocol v1 (milestone 28, slice 3). Clients
--  (first: the terminal) talk to Bureau's window-service
--  endpoint. Same direction rule as the display service: caps
--  move caller -> callee only, so the CLIENT allocates its
--  surface buffer (Mem_Alloc 64-page chunks) and pushes the
--  chunk caps to Bureau; Bureau Mem_Maps them (Map+Read rights
--  required) and copies damaged bands into the compositing
--  buffer at the window's pane origin (wl_shm model), then
--  Presents the band to the display service.
--
--  v1 simplifications (milestone 29 generalizes): exactly ONE
--  window/surface slot — the first Surface_Create binds the
--  window Bureau drew at startup; the pane geometry is
--  Bureau-fixed; one Commit_Buffer per surface (no remap);
--  Destroy accepted but a no-op.
--
--  Message words (raw Message.Words):
--    Op_Surface_Create (20): w0 = width, w1 = height (content
--      pixels). Reply w0 = status, w1 = surface id, w2 = pages
--      needed, w3 = granted width, w4 = granted height.
--    Op_Surface_Set_Buffer (21): w0 = surface id, w1 = base
--      chunk index; caps 0..3 = up to 4 chunk caps (Map+Read+
--      Transfer rights). Reply w0 = status.
--    Op_Surface_Commit_Buffer (22): w0 = surface id. Bureau
--      maps the chunks read-only. Reply w0 = status.
--    Op_Surface_Update (23): w0 = surface id, w1 = x, w2 = y,
--      w3 = w, w4 = h (damaged band in surface coords; clamped).
--      Bureau copies the band and presents it. Reply w0 = status.
--    Op_Surface_Destroy (24): w0 = surface id (no-op in v1).

package Akernel_User.Window is
   subtype U64 is Syscalls.U64;

   Op_Surface_Create        : constant U64 := 20;
   Op_Surface_Set_Buffer    : constant U64 := 21;
   Op_Surface_Commit_Buffer : constant U64 := 22;
   Op_Surface_Update        : constant U64 := 23;
   Op_Surface_Destroy       : constant U64 := 24;

   Status_Ok        : constant U64 := 0;
   Status_No_Slot   : constant U64 := 1;
   Status_Bad_Id    : constant U64 := 2;
   Status_Bad_Index : constant U64 := 3;
   Status_Bad_Caps  : constant U64 := 4;
   Status_Device    : constant U64 := 5;

   --  Client-side helpers (raw IPC_Call; replies are words-only).
   function Surface_Create
     (EP             : U64;
      Width, Height  : U64;
      Id, Pages      : out U64;
      Grant_W        : out U64;
      Grant_H        : out U64) return U64;
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
