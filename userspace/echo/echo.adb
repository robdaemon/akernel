with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Echo: print arguments (milestone 41b; the Amiga C:Echo analog).
--  "Echo [args...]" prints all arguments separated by a single
--  space, followed by a newline.

procedure Echo is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);
   Files.Set_Default_Volume ("BD0");

   for I in 1 .. CLI.Arg_Count loop
      if I > 1 then
         Akernel_User.Console.Put (" ");
      end if;
      Akernel_User.Console.Put (CLI.Argument (I));
   end loop;
   Akernel_User.Console.Put_Line ("");

   CLI.Exit_With (CLI.RC_Ok);
end Echo;
