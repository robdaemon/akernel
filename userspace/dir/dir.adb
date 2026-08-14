with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Akernel_User.CLI;

--  Dir: list a directory (milestone 32; the Amiga C:Dir analog —
--  lives in Sys:C/Dir). No argument lists the CURRENT DIRECTORY
--  (milestone 44 — the Amiga semantic); "Dir <path>" lists that
--  directory, resolved against the cwd. Directories print with
--  a "(dir)" tag; files with their byte size.
--
--  Milestone 54: standard library — Ada.Directories.Start_Search
--  walks the directory (adaint -> gloss akernel_opendir/readdir
--  -> fs Op_ReadDir); the walk raises Name_Error/Use_Error on an
--  unreadable directory, which maps to the old "can't open".
--  An empty directory keeps the historical quirk of reporting
--  failure (zero entries == can't open, milestone 32 semantics).

procedure Dir is
   package CLI renames Akernel_User.CLI;
   package Dirs renames Ada.Directories;
   use type Dirs.File_Kind;
begin
   CLI.Init;

   declare
      Path   : constant String :=
        (if Ada.Command_Line.Argument_Count = 0 then CLI.Get_Cwd
         else CLI.Resolve_Path (Ada.Command_Line.Argument (1)));
      Search : Dirs.Search_Type;
      Ent    : Dirs.Directory_Entry_Type;
      N      : Natural := 0;
   begin
      Dirs.Start_Search (Search, Path, "*");
      while Dirs.More_Entries (Search) loop
         Dirs.Get_Next_Entry (Search, Ent);
         if Dirs.Kind (Ent) = Dirs.Directory then
            Ada.Text_IO.Put_Line
              ("  " & Dirs.Simple_Name (Ent) & "  (dir)");
         else
            Ada.Text_IO.Put_Line
              ("  " & Dirs.Simple_Name (Ent) & Dirs.Size (Ent)'Image);
         end if;
         N := N + 1;
      end loop;
      Dirs.End_Search (Search);

      if N = 0 then
         CLI.Fail_With ("Dir: can't open " & Path, CLI.RC_Error);
      end if;
   exception
      when Dirs.Name_Error | Dirs.Use_Error =>
         CLI.Fail_With ("Dir: can't open " & Path, CLI.RC_Error);
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Dir;
