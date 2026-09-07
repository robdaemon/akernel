with Aegir_User.Syscalls;
with Libserv;

--  Clipboard_Lib (milestone 9x): request dispatch for the system
--  clipboard library. One plain-text buffer, replace-on-write,
--  snapshot-on-read (last writer wins). Clipboard transfers ride
--  a shared client buffer memobj, exactly like the file server's
--  Op_Read/Op_Write: the caller maps a small memory object at a
--  fixed VA, writes/copies the bytes there, and sends the memobj
--  cap in the message; the server maps that cap into its own
--  scratch window, copies, and unmaps. A per-op transferred cap
--  must not linger — every request deletes it before replying.
package Clipboard_Lib is
   use type Aegir_User.Syscalls.U64;

   subtype U64 is Aegir_User.Syscalls.U64;
   subtype Words is Libserv.Words;
   subtype Caps is Libserv.Caps;

   --  Buffer ceiling (bytes). Must equal the client buffer size
   --  (Aegir_User.Clipboard). Put of a larger text fails with
   --  Status_Too_Big and leaves the old contents intact.
   Clip_Max : constant := 32 * 1024;

   --  Request labels (0 is Libserv.Shutdown_Label and is never
   --  a data op).
   Label_Put : constant := 1;   --  words(0)=len, caps(0)=buffer
   Label_Get : constant := 2;   --  words(0)=offset, caps(0)=buffer

   --  Reply status (word 0 of every reply).
   Status_Ok     : constant := 0;
   Status_Bad    : constant := 1;  --  no/foreign buffer cap
   Status_Too_Big : constant := 2; --  Put longer than Clip_Max

   procedure On_Open;

   procedure Dispatch
     (Label        : U64;
      Request      : Libserv.Words;
      Request_Caps : Libserv.Caps;
      Reply_Handle : U64;
      Shutdown     : out Boolean);

end Clipboard_Lib;
