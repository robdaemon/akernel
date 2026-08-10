with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Version: print the system version (milestone 41b; the Amiga
--  C:Version analog). No arguments.

procedure Version is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count /= 0 then
      CLI.Fail_With ("usage: Version", CLI.RC_Warn);
   end if;

   Akernel_User.Console.Put_Line ("akernel milestone 41b");
   CLI.Exit_With (CLI.RC_Ok);
end Version;
