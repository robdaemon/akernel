with Aegir_User.Syscalls;
with Trinket.Window;

--  Trinket file requester (milestone 9x): the shared file picker
--  for any GUI app — the Amiga ASL requester lineage. It runs as
--  a CONTENT-SWAP modal driven by the host window's OWN event
--  loop (Trinket.Window.Start_Modal): the kernel only wakes a
--  thread that is blocked when its notification is signalled, so
--  a nested event loop starves; the dialog is queued and Run
--  swaps it in as the window root on its next iteration. The
--  kernel also binds one notification per thread, so a second
--  live window in one process is not possible.
--
--  Request() is NON-BLOCKING (call from a menu handler): when
--  the user finishes or cancels, On_Result fires with the picked
--  path (Pick_Open: an existing file; Pick_Save_As: the dir/name
--  to create). Cancelling via Cancel or the close gadget fires
--  On_Result with Picked = False.
--
--  Columns: Name | Size | Date (mtime from Op_ReadDir, epoch
--  seconds). Navigation: click a directory row or press Return
--  to descend, Up/Parent for the parent, and the path field
--  accepts a volume-qualified directory ("Data:" + Enter).
--  The caller must have the file server bound (Files.Bind).
package Trinket.File_Requester is

   type Mode_Kind is (Pick_Open, Pick_Save_As);

   type Result_Callback is access procedure
     (Picked : Boolean; Path : String);

   --  Queue the requester as a content-swap modal in Win (which
   --  must be open and running on the current thread). Initial_
   --  Dir is volume-qualified ("Sys:", "Sys:Tests"). The result
   --  is delivered to On_Result from the event loop.
   procedure Request
     (Win         : in out Trinket.Window.Window;
      Mode        : Mode_Kind;
      Initial_Dir : String;
      On_Result   : Result_Callback);

end Trinket.File_Requester;
