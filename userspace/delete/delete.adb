with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Delete: remove files (milestone 41; the Amiga C:Delete
--  analog). "Delete <name> [<name> ...]"; each argument is
--  deleted in turn, failures are reported per file and the
--  command continues (Amiga behavior); the exit code is RC_Error
--  when anything failed. Directories are rejected by the file
--  protocol (use a future Rmdir command / Op_Rmdir).
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send).

procedure Delete is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   Worst : CLI.U64 := CLI.RC_Ok;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count = 0 then
      CLI.Fail_With ("usage: Delete <name> [<name> ...]", CLI.RC_Error);
   end if;

   for I in 1 .. CLI.Arg_Count loop
      declare
         Name : constant String := CLI.Resolve_Path (CLI.Argument (I));
         St   : constant CLI.U64 := Files.Delete (Name);
      begin
         if St /= Files.Status_Ok then
            Akernel_User.Console.Put_Line ("Delete: can't delete " & Name);
            Worst := CLI.RC_Error;
         end if;
      end;
   end loop;

   CLI.Exit_With (Worst);
end Delete;
