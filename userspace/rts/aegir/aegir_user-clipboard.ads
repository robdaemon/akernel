with Aegir_User.Syscalls;
with System;

--  Aegir_User.Clipboard (milestone 9x): client API for the
--  system clipboard — a resident shared library (Sys:Libs/
--  Clipboard, opened via Aegir_User.Libs.Open_Library, which
--  routes through the library manager at handle 6 so every app
--  shares the ONE resident instance; libman never expunges it,
--  so the buffer outlives its clients).
--
--  Plain text only, one buffer, replace-on-write. Transfers ride
--  a client-owned memory object (8 pages = 32 KiB) mapped at a
--  fixed VA and sent to the server with each request, exactly
--  like the file server's read buffer (Files.Buffer_VA sits at
--  16#4400_0000#; this buffer lives at 16#4500_0000#, disjoint
--  from the path page above it and below the 16#4600_0000# link
--  base).
package Aegir_User.Clipboard is

   use type Aegir_User.Syscalls.U64;

   subtype U64 is Aegir_User.Syscalls.U64;

   Clipboard_Max : constant := 32 * 1024;

   Buffer_Pages : constant U64 := 8;
   Buffer_VA    : constant U64 := 16#4500_0000#;

   --  Reply statuses (match userspace/clipboard/clipboard_lib.ads).
   Status_Ok      : constant U64 := 0;
   Status_Bad     : constant U64 := 1;
   Status_Too_Big : constant U64 := 2;

   --  Open/close the shared clipboard (libman at handle 6; falls
   --  back to a private spawn when no manager cap is present —
   --  that copy is NOT shared, which is why startup GUI apps must
   --  hold the manager handle).
   function Open return U64;
   procedure Close (Service : U64);

   --  Replace the clipboard contents with Text (whole-buffer,
   --  atomic). Returns Status_Ok; Status_Too_Big when Text is
   --  longer than Clipboard_Max (the old contents stay intact);
   --  Status_Bad on a failed call.
   function Put (Service : U64; Text : String) return U64;

   --  Low-level chunked read (mirrors Files.Read): server copies
   --  min(Clipboard_Max, remaining) bytes from Offset into Dest.
   function Read
     (Service : U64;
      Offset  : U64;
      Dest    : System.Address;
      Length  : U64;
      Count   : out U64) return U64;

   --  Fetch the whole clipboard into Text (chunked); Len receives
   --  the byte count (0 when empty). Returns Status_Ok.
   function Get
     (Service : U64;
      Text    : out String;
      Len     : out Natural) return U64;

end Aegir_User.Clipboard;
