with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Akernel_User.CLI;
with Akernel_User.Glob;

--  Dir: list a directory (milestone 32; the Amiga C:Dir analog —
--  lives in Sys:C/Dir). No argument lists the CURRENT DIRECTORY
--  (milestone 44 — the Amiga semantic); "Dir <path>" lists that
--  directory, resolved against the cwd. Directories print with
--  a "(dir)" tag; files with their byte size.
--
--  Milestone 85c: a wildcard pattern (Akernel_User.Glob syntax)
--  filters by name: "Dir #?.info", "Dir BD0:(a|b).txt". The
--  pattern is the tail after the last ':' or '/' (no separator:
--  the whole argument, listed from the cwd); a matchless pattern
--  is not an error. Arguments without wildcard tokens keep the
--  plain-directory behaviour (so "Dir BD0:SUBDIR" still lists
--  SUBDIR's contents).
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
      Arg : constant String :=
        (if Ada.Command_Line.Argument_Count = 0 then ""
         else Ada.Command_Line.Argument (1));
      Sep : Natural := 0;  --  last ':' or '/' in Arg, 0 = none
      Search : Dirs.Search_Type;
      Ent    : Dirs.Directory_Entry_Type;
      N      : Natural := 0;
   begin
      for I in reverse Arg'Range loop
         if Arg (I) = ':' or else Arg (I) = '/' then
            Sep := I;
            exit;
         end if;
      end loop;

      declare
         Has_Pat : constant Boolean :=
           Arg'Length > 0
           and then Akernel_User.Glob.Is_Pattern
             (Arg (Sep + 1 .. Arg'Last));
         Path : constant String :=
           (if Arg'Length = 0 or else (Has_Pat and Sep = 0)
            then CLI.Get_Cwd
            elsif Has_Pat
            then CLI.Resolve_Path (Arg (Arg'First .. Sep))
            else CLI.Resolve_Path (Arg));
         Pattern : constant String :=
           (if Has_Pat then Arg (Sep + 1 .. Arg'Last) else "");
      begin
         Dirs.Start_Search (Search, Path, "*");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Ent);
            if Has_Pat
              and then not Akernel_User.Glob.Match
                (Pattern, Dirs.Simple_Name (Ent))
            then
               null;  --  filtered out
            elsif Dirs.Kind (Ent) = Dirs.Directory then
               Ada.Text_IO.Put_Line
                 ("  " & Dirs.Simple_Name (Ent) & "  (dir)");
               N := N + 1;
            else
               Ada.Text_IO.Put_Line
                 ("  " & Dirs.Simple_Name (Ent) & Dirs.Size (Ent)'Image);
               N := N + 1;
            end if;
         end loop;
         Dirs.End_Search (Search);

         if N = 0 and then not Has_Pat then
            CLI.Fail_With ("Dir: can't open " & Path, CLI.RC_Error);
         end if;
      exception
         when Dirs.Name_Error | Dirs.Use_Error =>
            CLI.Fail_With ("Dir: can't open " & Path, CLI.RC_Error);
      end;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Dir;
