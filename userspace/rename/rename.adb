with Ada.Command_Line;
with Ada.Directories;
with Akernel_User.CLI;

--  Rename: rename or move within one volume (milestone 41; the
--  Amiga C:Rename analog). "Rename <from> <to>"; the target must
--  not exist and both names must resolve to the same volume.
--  Directories move with their contents.
--
--  Milestone 54: standard library — Ada.Command_Line args,
--  Ada.Directories.Rename (gloss rename -> fs Op_Rename).

procedure Rename is
   package CLI renames Akernel_User.CLI;
begin
   CLI.Init;

   if Ada.Command_Line.Argument_Count /= 2 then
      CLI.Fail_With ("usage: Rename <from> <to>", CLI.RC_Error);
   end if;

   declare
      From : constant String :=
        CLI.Resolve_Path (Ada.Command_Line.Argument (1));
      To   : constant String :=
        CLI.Resolve_Path (Ada.Command_Line.Argument (2));
   begin
      Ada.Directories.Rename (From, To);
   exception
      when others =>
         CLI.Fail_With
           ("Rename: can't rename " & From & " to " & To,
            CLI.RC_Error);
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Rename;
