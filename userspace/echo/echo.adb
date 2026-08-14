with Ada.Command_Line;
with Ada.Text_IO;
with Akernel_User.CLI;

--  Echo: print arguments (milestone 41b; the Amiga C:Echo analog).
--  "Echo [args...]" prints all arguments separated by a single
--  space, followed by a newline.
--
--  Milestone 53c: migrated to the standard library as the first
--  proof program — arguments come from Ada.Command_Line (the m33a
--  args page, tokenized by crt0 into gnat_argv), output goes
--  through Ada.Text_IO -> newlib stdio -> gloss fd 1 -> the
--  console, so shell redirection (> file, | pipe) composes.
--  CLI.Init parses the args-page redirection trailer (we never
--  touch CLI.Arg_Count), CLI.Exit_With closes redirects.

procedure Echo is
   package CLI renames Akernel_User.CLI;
   package ACL renames Ada.Command_Line;
begin
   CLI.Init;

   for I in 1 .. ACL.Argument_Count loop
      if I > 1 then
         Ada.Text_IO.Put (" ");
      end if;
      Ada.Text_IO.Put (ACL.Argument (I));
   end loop;
   Ada.Text_IO.Put_Line ("");

   CLI.Exit_With (CLI.RC_Ok);
end Echo;
