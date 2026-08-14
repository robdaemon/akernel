with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Akernel_User.CLI;

--  CD: current directory (milestone 42; the Amiga C:CD analog).
--  "CD" prints the cwd; "CD <dir>" changes it. Relative paths
--  resolve against the cwd; "/" is the Amiga parent idiom
--  (cd / goes up one level, // two) via CLI.Resolve_Path. The
--  cwd is the ENV:CWD variable — global like every variable —
--  so a child CD moves the parent's session too, Amiga-style.
--
--  Milestone 54: standard library — Ada.Directories.Set_
--  Directory validates the target (Is_Directory through the
--  dir-aware gloss stat) and writes ENV:CWD via gloss chdir;
--  Current_Directory prints the normalized form (trailing
--  separator, a-direct convention).

procedure CD is
   package CLI renames Akernel_User.CLI;
   package Dirs renames Ada.Directories;
begin
   CLI.Init;

   if Ada.Command_Line.Argument_Count = 0 then
      Ada.Text_IO.Put_Line (Dirs.Current_Directory);
      CLI.Exit_With (CLI.RC_Ok);
   end if;

   declare
      Target : constant String :=
        CLI.Resolve_Path (Ada.Command_Line.Argument (1));
   begin
      Dirs.Set_Directory (Target);
   exception
      when Dirs.Name_Error =>
         CLI.Fail_With ("CD: no such directory " & Target,
                        CLI.RC_Error);
      when others =>
         CLI.Fail_With ("CD: can't read " & Target, CLI.RC_Error);
   end;

   CLI.Exit_With (CLI.RC_Ok);
end CD;
