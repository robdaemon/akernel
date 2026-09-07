with Akernel_User.Syscalls;

--  Trinket file requester (milestone 9x): the shared file picker
--  for any GUI app — the Amiga ASL requester lineage. It opens
--  its OWN window (nested modal: call from the app's event
--  thread, e.g. a menu handler; the call blocks until the user
--  picks or cancels) and returns a full volume-qualified path.
--
--  Columns: Name | Size | Date (mtime from Op_ReadDir, epoch
--  seconds — Phase 1). Navigation: click a directory row or
--  press Return to descend, Up/Parent for the parent, and the
--  path field accepts a volume-qualified directory (type
--  "Data:" and Enter to jump drives). Modes:
--    Pick_Open    — pick an existing file (double-click or the
--                   Open button / Return on a file row).
--    Pick_Save_As — type a name in the field and Save (or
--                   Return); picks a directory name into the
--                   field so Save lands there.
--  The caller must have the file server bound (Files.Bind), as
--  every uniform-ABI program does.
package Trinket.File_Requester is

   type Mode_Kind is (Pick_Open, Pick_Save_As);

   --  Runs the modal requester. Bureau_EP is the app's window
   --  service handle (3 under the uniform ABI). Initial_Dir is
   --  a volume-qualified directory ("Sys:", "Sys:Tests"). On a
   --  pick, Chosen (caller buffer) receives the full path of
   --  the chosen file (Pick_Open) or the dir/name to create
   --  (Pick_Save_As) and True is returned; Cancel/close returns
   --  False.
   function Run
     (Bureau_EP   : Akernel_User.Syscalls.U64;
      Mode        : Mode_Kind;
      Initial_Dir : String;
      Chosen      : out String;
      Chosen_Len  : out Natural) return Boolean;

end Trinket.File_Requester;
