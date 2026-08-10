with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Which: command path resolution (milestone 41b). "Which NAME"
--  prints the fully-qualified path where the shell would find the
--  command, or fails with RC_Error if not found.

procedure Which is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count /= 1 then
      CLI.Fail_With ("usage: Which NAME", CLI.RC_Error);
   end if;

   declare
      Path : constant String := CLI.Resolve_Command (CLI.Argument (1));
   begin
      if Path'Length = 0 then
         CLI.Fail_With
           (CLI.Argument (1) & ": not found", CLI.RC_Error);
      end if;
      Akernel_User.Console.Put_Line (Path);
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Which;
