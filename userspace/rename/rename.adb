with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Rename: rename or move within one volume (milestone 41; the
--  Amiga C:Rename analog). "Rename <from> <to>"; the target must
--  not exist and both names must resolve to the same volume.
--  Directories move with their contents.
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send).

procedure Rename is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   From : constant String := CLI.Argument (1);
   To   : constant String := CLI.Argument (2);
   St   : CLI.U64;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);
   Files.Set_Default_Volume ("BD0");

   if CLI.Arg_Count /= 2 then
      CLI.Fail_With ("usage: Rename <from> <to>", CLI.RC_Error);
   end if;

   St := Files.Rename (From, To);
   if St /= Files.Status_Ok then
      CLI.Fail_With
        ("Rename: can't rename " & From & " to " & To, CLI.RC_Error);
   end if;

   CLI.Exit_With (CLI.RC_Ok);
end Rename;
