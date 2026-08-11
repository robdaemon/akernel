with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.CLI;
with Type_Buf;

--  Type: print a file to the console (milestone 33a; the Amiga
--  C:Type analog — lives in Sys:C/Type). Uniform program ABI
--  (1 = console, 2 = file server, 3 = Bureau svc) plus the
--  optional argument page at handle 4: "Type README.TXT".
--
--  Streams the file through the file protocol's read buffer in
--  32 KiB chunks; the console device renders (LF newlines as
--  stored). No paging yet (Amiga Type has one; the terminal has
--  no scrollback to page against). Milestone 46b: Type keeps
--  its RAW argument line (paths may contain spaces, unlike
--  CLI tokens) but taps CLI.Arg_Count once so Parse_Args runs
--  and the redirection trailer wires in — and exits through
--  CLI.Exit_With so a piped consumer gets its EOF.

procedure Type_Cmd is
   use Akernel_User.Syscalls;
   use System.Storage_Elements;
   use type U64;
   package CLI renames Akernel_User.CLI;

   Console_EP : constant U64 := 1;
   FS_EP      : constant U64 := 2;

   Arg_Buf : String (1 .. 240);
   Arg_Len : Natural;

   Chunk : String renames Type_Buf.Chunk;
   Size  : U64 := 0;
   Off   : U64 := 0;
   Count : U64 := 0;
   St    : U64;
begin
   Akernel_User.Console.Set_Endpoint (Console_EP);
   Akernel_User.Files.Bind (FS_EP);

   --  Trigger CLI.Parse_Args (maps the args page AND parses
   --  the redirection trailer, m46b); Type still reads its
   --  path raw below.
   declare
      Ignore : constant Natural := CLI.Arg_Count;
   begin
      null;
   end;

   Read_Args (Arg_Buf, Arg_Len);
   if Arg_Len = 0 then
      Akernel_User.Console.Put_Line ("usage: Type <file>");
      CLI.Exit_With (CLI.RC_Error);
   end if;

   St := Akernel_User.Files.Open
     (Akernel_User.CLI.Resolve_Path (Arg_Buf (1 .. Arg_Len)), Size);
   if St /= Akernel_User.Files.Status_Ok then
      Akernel_User.Console.Put_Line
        ("Type: can't open " & Arg_Buf (1 .. Arg_Len));
      CLI.Exit_With (CLI.RC_Error);
   end if;

   declare
      Full : constant String :=
        Akernel_User.CLI.Resolve_Path (Arg_Buf (1 .. Arg_Len));
   begin
   while Off < Size loop
      St := Akernel_User.Files.Read
        (Full, Off, Chunk'Address,
         U64'Min (U64 (Chunk'Length), Size - Off), Count);
      exit when St /= Akernel_User.Files.Status_Ok or else Count = 0;
      Akernel_User.Console.Put (Chunk (1 .. Natural (Count)));
      Off := Off + Count;
   end loop;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Type_Cmd;
