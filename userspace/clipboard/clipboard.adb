with Clipboard_Lib;
with Libserv;

--  Clipboard: the system clipboard server. Runs as a resident
--  shared library (Sys:Libs/Clipboard, version 1.0): libman keeps
--  it loaded after every client closes, so the buffer outlives
--  the apps that copy and paste (Amiga clipboard.device).
procedure Clipboard is
begin
   Libserv.Run
     (Clipboard_Lib.On_Open'Access,
      Clipboard_Lib.Dispatch'Access,
      Version => 1, Revision => 0);
end Clipboard;
