with Interfaces;
with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Fault: translate a return code to text (milestone 41b; the
--  Amiga C:Fault analog). "Fault <n>" prints the description and
--  exits with RC_Ok.

procedure Fault is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   function Parse (S : String) return CLI.U64 is
      Result : CLI.U64 := 0;
   begin
      for C of S loop
         if C not in '0' .. '9' then
            return CLI.U64'Last;
         end if;
         Result := Result * 10 + CLI.U64 (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      return Result;
   end Parse;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);
   Files.Set_Default_Volume ("BD0");

   if CLI.Arg_Count /= 1 then
      CLI.Fail_With ("usage: Fault <return-code>", CLI.RC_Error);
   end if;

   declare
      Code : constant CLI.U64 := Parse (CLI.Argument (1));
   begin
      if Code = CLI.U64'Last then
         CLI.Fail_With
           ("Fault: not a number: " & CLI.Argument (1), CLI.RC_Error);
      end if;

      if Code = CLI.RC_Ok then
         Akernel_User.Console.Put_Line
           (CLI.Argument (1) & " = OK");
      elsif Code = CLI.RC_Warn then
         Akernel_User.Console.Put_Line
           (CLI.Argument (1) & " = Warning");
      elsif Code = CLI.RC_Error then
         Akernel_User.Console.Put_Line
           (CLI.Argument (1) & " = Error");
      elsif Code = CLI.RC_Fail then
         Akernel_User.Console.Put_Line
           (CLI.Argument (1) & " = Fail");
      else
         Akernel_User.Console.Put_Line
           (CLI.Argument (1) & " = return code " & CLI.Argument (1));
      end if;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Fault;
