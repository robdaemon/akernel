with Aegir_User.CLI;
with Aegir_User.Console;
with Aegir_User.Files;

--  Unset: delete an environment variable (milestone 41b; the Amiga
--  C:Unset analog). "Unset NAME" deletes ENV:NAME.

procedure Unset is
   package CLI renames Aegir_User.CLI;
   package Files renames Aegir_User.Files;
   use type CLI.U64;
begin
   Aegir_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count /= 1 then
      CLI.Fail_With ("usage: Unset NAME", CLI.RC_Error);
   end if;

   if Files.Delete ("ENV:" & CLI.Argument (1)) /= Files.Status_Ok then
      CLI.Fail_With
        ("Unset: can't delete " & CLI.Argument (1), CLI.RC_Error);
   end if;

   CLI.Exit_With (CLI.RC_Ok);
end Unset;
