with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Get: print an environment variable (milestone 41b; the Amiga
--  C:Get analog). Variables are files in ENV: (resolved to
--  Sys:Prefs/Env). "Get NAME" prints the value; missing variables
--  are reported and the command exits with RC_Error.

procedure Get is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count /= 1 then
      CLI.Fail_With ("usage: Get NAME", CLI.RC_Error);
   end if;

   declare
      Value : constant String := CLI.Get_Env (CLI.Argument (1));
   begin
      if Value'Length = 0 then
         CLI.Fail_With
           (CLI.Argument (1) & ": not set", CLI.RC_Error);
      end if;
      Akernel_User.Console.Put_Line (Value);
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Get;
