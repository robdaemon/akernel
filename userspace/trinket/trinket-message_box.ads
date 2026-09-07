with Trinket.Window;

--  Trinket message box (M9z): the generic modal prompt dialog,
--  shared by apps — the Amiga requester lineage alongside
--  Trinket.File_Requester. It runs as a floating OVERLAY modal on
--  the host window's own event loop (single loop, no nested
--  recursion — see File_Requester's header for why).
--
--  Request() is NON-BLOCKING (call from a menu handler). A button
--  click delivers its 1-based index (left to right) to On_Choice
--  and closes the dialog; dismissing it via the window close
--  gadget closes WITHOUT a callback. When an app maps its own
--  "Cancel" button it receives that button's index like any other.
--
--  Chaining (M9z): a handler that must open a successor dialog
--  (Edit's per-doc Save prompt) is safe to call Request again —
--  the dialog is exited before On_Choice fires, so the successor
--  is queued and starts as soon as this one closes.
package Trinket.Message_Box is

   Max_Buttons : constant := 4;

   --  0 = dismissed without a choice (close gadget);
   --  1 .. Max_Buttons = the clicked button (index in Buttons).
   type Choice_Callback is access procedure (Choice : Natural);

   --  Show a modal overlay dialog titled Title with the (word-
   --  wrapped) Prompt and a row of buttons given as a
   --  '|'-separated list of 1 .. Max_Buttons labels ("Save|Save
   --  All|Cancel"). Win must be open and running on this thread.
   procedure Request
     (Win       : in out Trinket.Window.Window;
      Title     : String;
      Prompt    : String;
      Buttons   : String;
      On_Choice : Choice_Callback);

end Trinket.Message_Box;
