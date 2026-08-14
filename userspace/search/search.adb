with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Akernel_User.CLI;

--  Search: print the lines of a file containing a string
--  (milestone 41c; the Amiga C:Search analog, grep-lite).
--  "Search <file> <string>"; case-sensitive substring match,
--  matching lines print verbatim.
--
--  Milestone 54: standard library — the file streams through
--  Ada.Text_IO.Get_Line (no more heap slurp, no 2 MiB file cap),
--  matching is Ada.Strings.Fixed.Index, output is Put_Line
--  (redirect composes through the console).

procedure Search is
   package CLI renames Akernel_User.CLI;
   Hits : Natural := 0;
begin
   CLI.Init;

   if Ada.Command_Line.Argument_Count /= 2 then
      CLI.Fail_With ("usage: Search <file> <string>", CLI.RC_Error);
   end if;

   declare
      Src : constant String :=
        CLI.Resolve_Path (Ada.Command_Line.Argument (1));
      Pat : constant String := Ada.Command_Line.Argument (2);
      F   : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Src);
      while not Ada.Text_IO.End_Of_File (F) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (F);
         begin
            if Ada.Strings.Fixed.Index (Line, Pat) > 0 then
               Ada.Text_IO.Put_Line (Line);
               Hits := Hits + 1;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (F);
   exception
      when Ada.Text_IO.Name_Error =>
         CLI.Fail_With ("Search: can't open " & Src, CLI.RC_Error);
   end;

   if Hits = 0 then
      Ada.Text_IO.Put_Line ("Search: no match");
   end if;

   CLI.Exit_With (CLI.RC_Ok);
end Search;
