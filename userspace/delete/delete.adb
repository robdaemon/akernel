with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Akernel_User.CLI;

--  Delete: remove files (milestone 41; the Amiga C:Delete
--  analog). "Delete <name> [<name> ...]"; each argument is
--  deleted in turn, failures are reported per file and the
--  command continues (Amiga behavior); the exit code is RC_Error
--  when anything failed. Directories are rejected by the file
--  protocol (use a future Rmdir command / Op_Rmdir).
--
--  Milestone 54: lives on the standard library — args from
--  Ada.Command_Line (the m33a args page via crt0/argv.c),
--  deletion via Ada.Directories.Delete_File (gloss unlink ->
--  fs Op_Delete), messages via Ada.Text_IO (stdout rides the
--  console, shell redirection composes). CLI.Init wires the
--  default endpoint binding + redirection trailer; CLI.Exit_With
--  flushes a piped consumer's EOF.

procedure Delete is
   package CLI renames Akernel_User.CLI;
   Worst : CLI.U64 := CLI.RC_Ok;
begin
   CLI.Init;

   if Ada.Command_Line.Argument_Count = 0 then
      CLI.Fail_With ("usage: Delete <name> [<name> ...]", CLI.RC_Error);
   end if;

   for I in 1 .. Ada.Command_Line.Argument_Count loop
      declare
         Name : constant String :=
           CLI.Resolve_Path (Ada.Command_Line.Argument (I));
      begin
         Ada.Directories.Delete_File (Name);
      exception
         when others =>
            Ada.Text_IO.Put_Line ("Delete: can't delete " & Name);
            Worst := CLI.RC_Error;
      end;
   end loop;

   CLI.Exit_With (Worst);
end Delete;
