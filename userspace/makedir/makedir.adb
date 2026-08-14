with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Akernel_User.CLI;

--  MakeDir: create directories (milestone 41; the Amiga
--  C:MakeDir analog). "MakeDir <name> [<name> ...]"; each
--  argument is created in turn, failures are reported per
--  directory and the command continues; the exit code is
--  RC_Error when anything failed.
--
--  Milestone 54: standard library — Ada.Command_Line args,
--  Ada.Directories.Create_Directory (vendored mkdir.c ->
--  gloss _mkdir -> fs Op_Mkdir), Ada.Text_IO messages.

procedure Makedir is
   package CLI renames Akernel_User.CLI;
   Worst : CLI.U64 := CLI.RC_Ok;
begin
   CLI.Init;

   if Ada.Command_Line.Argument_Count = 0 then
      CLI.Fail_With ("usage: MakeDir <name> [<name> ...]", CLI.RC_Error);
   end if;

   for I in 1 .. Ada.Command_Line.Argument_Count loop
      declare
         Name : constant String :=
           CLI.Resolve_Path (Ada.Command_Line.Argument (I));
      begin
         Ada.Directories.Create_Directory (Name);
      exception
         when others =>
            Ada.Text_IO.Put_Line ("MakeDir: can't create " & Name);
            Worst := CLI.RC_Error;
      end;
   end loop;

   CLI.Exit_With (Worst);
end Makedir;
