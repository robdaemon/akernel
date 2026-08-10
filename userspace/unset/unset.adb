with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Unset: delete an environment variable (milestone 41b; the Amiga
--  C:Unset analog). "Unset NAME" deletes ENV:NAME.

procedure Unset is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;
begin
   Akernel_User.Console.Set_Endpoint (1);
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
