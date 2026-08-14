with Ada.Text_IO;
with Akernel_User.Syscalls;
with Akernel_User.CLI;

--  Type: print a file to the console (milestone 33a; the Amiga
--  C:Type analog — lives in Sys:C/Type). Uniform program ABI
--  (1 = console, 2 = file server, 3 = Bureau svc) plus the
--  optional argument page at handle 4: "Type README.TXT".
--
--  Milestone 54: content streams through Ada.Text_IO (Get_Line /
--  Put_Line; stdout rides the console so shell redirection
--  composes). Type keeps its RAW argument line — paths may
--  contain spaces, unlike CLI/argv tokens; Read_Args stops at
--  the newline so the redirection trailer is excluded. CLI.Init
--  parses that trailer (m46b) and CLI.Exit_With flushes a piped
--  consumer's EOF. No paging yet (the terminal has no
--  scrollback to page against).

procedure Type_Cmd is
   package CLI renames Akernel_User.CLI;
   use type CLI.U64;

   Arg_Buf : String (1 .. 240);
   Arg_Len : Natural;
begin
   --  Binds the default endpoints (console 1, fs 2) and parses
   --  the args-page redirection trailer.
   CLI.Init;

   Akernel_User.Syscalls.Read_Args (Arg_Buf, Arg_Len);
   if Arg_Len = 0 then
      Ada.Text_IO.Put_Line ("usage: Type <file>");
      CLI.Exit_With (CLI.RC_Error);
   end if;

   declare
      Full : constant String :=
        CLI.Resolve_Path (Arg_Buf (1 .. Arg_Len));
      F    : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Full);
      while not Ada.Text_IO.End_Of_File (F) loop
         Ada.Text_IO.Put_Line (Ada.Text_IO.Get_Line (F));
      end loop;
      Ada.Text_IO.Close (F);
   exception
      when Ada.Text_IO.Name_Error =>
         Ada.Text_IO.Put_Line
           ("Type: can't open " & Arg_Buf (1 .. Arg_Len));
         CLI.Exit_With (CLI.RC_Error);
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Type_Cmd;
