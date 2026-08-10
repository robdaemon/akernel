with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  MakeDir: create directories (milestone 41; the Amiga
--  C:MakeDir analog). "MakeDir <name> [<name> ...]"; each
--  argument is created in turn, failures are reported per
--  directory and the command continues; the exit code is
--  RC_Error when anything failed.
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send).

procedure Makedir is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   Worst : CLI.U64 := CLI.RC_Ok;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count = 0 then
      CLI.Fail_With ("usage: MakeDir <name> [<name> ...]", CLI.RC_Error);
   end if;

   for I in 1 .. CLI.Arg_Count loop
      declare
         Name : constant String := CLI.Resolve_Path (CLI.Argument (I));
         St   : constant CLI.U64 := Files.Mkdir (Name);
      begin
         if St /= Files.Status_Ok then
            Akernel_User.Console.Put_Line
              ("MakeDir: can't create " & Name);
            Worst := CLI.RC_Error;
         end if;
      end;
   end loop;

   CLI.Exit_With (Worst);
end Makedir;
