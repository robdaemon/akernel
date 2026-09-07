with Akernel_User.Syscalls;
with Trinket.Window;

--  Trinket file requester (milestone 9x): the shared file picker
--  for any GUI app — the Amiga ASL requester lineage. It runs as
--  a CONTENT-SWAP modal inside the caller's already-open window
--  (Trinket.Window.Run_Modal): the kernel binds one notification
--  per thread, so a second live window in one process is not
--  possible; the dialog temporarily replaces the host window's
--  root and the call returns the picked path when the user
--  finishes or cancels. Call from the app's event thread (e.g. a
--  menu handler).
--
--  Columns: Name | Size | Date (mtime from Op_ReadDir, epoch
--  seconds — Phase 1). Navigation: click a directory row or
--  press Return to descend, Up/Parent for the parent, and the
--  path field accepts a volume-qualified directory (type
--  "Data:" and Enter to jump drives). Modes:
--    Pick_Open    — pick an existing file (double-click or the
--                   Open button / Return on a file row).
--    Pick_Save_As — type a name in the field and Save (or
--                   Return); picking a directory fills the name
--                   field so Save lands there.
--  The caller must have the file server bound (Files.Bind), as
--  every uniform-ABI program does.
package Trinket.File_Requester is

   type Mode_Kind is (Pick_Open, Pick_Save_As);

   --  Runs the modal requester in Host's window (must be open on
   --  the current thread). Initial_Dir is a volume-qualified
   --  directory ("Sys:", "Sys:Tests"). On a pick, Chosen (caller
   --  buffer) receives the full path of the chosen file
   --  (Pick_Open) or the dir/name to create (Pick_Save_As) and
   --  True is returned; Cancel/close-gadget returns False.
   function Run
     (Win         : in out Trinket.Window.Window;
      Mode        : Mode_Kind;
      Initial_Dir : String;
      Chosen      : out String;
      Chosen_Len  : out Natural) return Boolean;

end Trinket.File_Requester;
