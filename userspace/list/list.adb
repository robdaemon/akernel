with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Akernel_User.CLI;

--  List: detailed directory listing (milestone 41c; the Amiga
--  C:List analog). "List [<dir>]"; no argument lists the root of
--  the default volume BD0:. One line per entry: name, then the
--  byte size right-aligned, directories tagged "(dir)". The
--  file protocol carries no timestamps (FAT dirents stamp the
--  fixed 2025-01-01), so no date column yet.
--
--  Milestone 54: standard library — Ada.Directories.Start_Search
--  (Op_ReadDir under the hood), Ada.Text_IO output. An empty or
--  missing directory still prints the header; a missing one
--  raises in Start_Search and exits RC_Error like before.

procedure List is
   package CLI renames Akernel_User.CLI;
   package Dirs renames Ada.Directories;
   use type Dirs.File_Kind;

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
      Path   : constant String :=
        (if Ada.Command_Line.Argument_Count = 0 then "BD0:"
         else CLI.Resolve_Path (Ada.Command_Line.Argument (1)));
      Search : Dirs.Search_Type;
      Ent    : Dirs.Directory_Entry_Type;
   begin
      Dirs.Start_Search (Search, Path, "*");
      Ada.Text_IO.Put_Line ("Directory """ & Path & """:");
      while Dirs.More_Entries (Search) loop
         Dirs.Get_Next_Entry (Search, Ent);
         Ada.Text_IO.Put (Dirs.Simple_Name (Ent));
         if Dirs.Kind (Ent) = Dirs.Directory then
            Ada.Text_IO.Put_Line ("             (dir)");
         else
            Put_Size (Dirs.Size (Ent));
            Ada.Text_IO.New_Line;
         end if;
      end loop;
      Dirs.End_Search (Search);
   exception
      when Dirs.Name_Error | Dirs.Use_Error =>
         CLI.Fail_With ("List: can't read " & Path, CLI.RC_Error);
   end;

   CLI.Exit_With (CLI.RC_Ok);
end List;
