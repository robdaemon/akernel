with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Akernel_User.CLI;
with Akernel_User.Files;
with Akernel_User.Glob;

--  List: detailed directory listing (milestone 41c; the Amiga
--  C:List analog). "List [<dir>]"; no argument lists the root of
--  the default volume BD0:. One line per entry: name, then the
--  byte size right-aligned, directories tagged "(dir)". Milestone
--  59: the stat reply carries FAT write date/time (words 2/3), so
--  files get an Amiga-style stamp column; volumes without
--  timestamps (initrd, procfs, pipes) print none.
--
--  Milestone 85c: a wildcard pattern (Akernel_User.Glob syntax)
--  filters by name, split off at the last ':' or '/' like Dir
--  ("List #?.info", "List BD0:(foo|bar)"); no separator lists the
--  cwd.  Arguments without wildcard tokens keep the plain-
--  directory behaviour.
--
--  Milestone 54: standard library — Ada.Directories.Start_Search
--  (Op_ReadDir under the hood), Ada.Text_IO output. An empty or
--  missing directory still prints the header; a missing one
--  raises in Start_Search and exits RC_Error like before.

procedure List is
   package CLI renames Akernel_User.CLI;
   package Dirs renames Ada.Directories;
   use type Dirs.File_Kind;
   use type Akernel_User.Files.U64;

   Months : constant array (1 .. 12) of String (1 .. 3) :=
     ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec");

   function Two (N : Akernel_User.Files.U64) return String is
     (Character'Val (Character'Pos ('0') + Natural (N / 10))
      & Character'Val (Character'Pos ('0') + Natural (N mod 10)));

   --  FAT encodings -> "15-Aug-2026 19:12:34"; a zero stamp
   --  (volumes without timestamps) prints nothing.
   procedure Put_Stamp (Path, Name : String) is
      use type Akernel_User.Files.U64;
      Size, D, T : Akernel_User.Files.U64;
      Is_D       : Boolean;
      Full : constant String :=
        (if Path'Length > 0
           and then (Path (Path'Last) = ':'
                     or else Path (Path'Last) = '/')
         then Path & Name
         else Path & "/" & Name);
   begin
      if Akernel_User.Files.Stat_Ex (Full, Size, D, T, Is_D) /=
           Akernel_User.Files.Status_Ok
        or else D = 0
      then
         return;
      end if;
      Ada.Text_IO.Put
        ("  " & Two (D mod 32) & "-"
         & Months (Natural ((D / 32) mod 16)) & "-"
         & Two (((D / 512) + 1_980) / 100)
         & Two ((D / 512 + 1_980) mod 100)
         & " " & Two (T / 2_048) & ":"
         & Two ((T / 32) mod 64) & ":" & Two ((T mod 32) * 2));
   end Put_Stamp;

   procedure Put_Size (S : Dirs.File_Size) is
      Img   : constant String := S'Image;  --  leading space
      Field : constant := 10;
      Pad   : constant Natural :=
        (if Img'Length - 1 >= Field then 1
         else Field - (Img'Length - 1));
   begin
      Ada.Text_IO.Put (String'(1 .. Pad => ' '));
      Ada.Text_IO.Put (Img (2 .. Img'Last));
   end Put_Size;

begin
   CLI.Init;

   declare
      Arg : constant String :=
        (if Ada.Command_Line.Argument_Count = 0 then ""
         else Ada.Command_Line.Argument (1));
      Sep : Natural := 0;  --  last ':' or '/' in Arg, 0 = none
      Search : Dirs.Search_Type;
      Ent    : Dirs.Directory_Entry_Type;
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
           (if Arg'Length = 0 then "BD0:"
            elsif Has_Pat and Sep = 0 then CLI.Get_Cwd
            elsif Has_Pat
            then CLI.Resolve_Path (Arg (Arg'First .. Sep))
            else CLI.Resolve_Path (Arg));
         Pattern : constant String :=
           (if Has_Pat then Arg (Sep + 1 .. Arg'Last) else "");
      begin
         Dirs.Start_Search (Search, Path, "*");
         Ada.Text_IO.Put_Line ("Directory """ & Path & """:");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Ent);
            if Has_Pat
              and then not Akernel_User.Glob.Match
                (Pattern, Dirs.Simple_Name (Ent))
            then
               null;  --  filtered out
            else
               Ada.Text_IO.Put (Dirs.Simple_Name (Ent));
               if Dirs.Kind (Ent) = Dirs.Directory then
                  Ada.Text_IO.Put_Line ("             (dir)");
               else
                  Put_Size (Dirs.Size (Ent));
                  Put_Stamp (Path, Dirs.Simple_Name (Ent));
                  Ada.Text_IO.New_Line;
               end if;
            end if;
         end loop;
         Dirs.End_Search (Search);
      exception
         when Dirs.Name_Error | Dirs.Use_Error =>
            CLI.Fail_With ("List: can't read " & Path, CLI.RC_Error);
      end;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end List;
