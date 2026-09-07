with Aegir_User.CLI;
with Aegir_User.Console;
with Aegir_User.Files;

--  Version: print the system version (milestone 41b; the Amiga
--  C:Version analog). No arguments.

procedure Version is
   package CLI renames Aegir_User.CLI;
   package Files renames Aegir_User.Files;
begin
   Aegir_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count /= 0 then
      CLI.Fail_With ("usage: Version", CLI.RC_Warn);
   end if;

   Aegir_User.Console.Put_Line ("aegir milestone 41b");
   CLI.Exit_With (CLI.RC_Ok);
end Version;
