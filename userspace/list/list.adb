with Interfaces;
with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  List: detailed directory listing (milestone 41c; the Amiga
--  C:List analog). "List [<dir>]"; no argument lists the root of
--  the default volume BD0:. One line per entry: name, then the
--  byte size right-aligned, directories tagged "(dir)". The
--  file protocol carries no timestamps (FAT dirents stamp the
--  fixed 2025-01-01), so no date column yet.
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send).

procedure List is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   subtype U64 is CLI.U64;

   Name     : String (1 .. 24);
   Name_Len : Natural;
   Is_Dir   : Boolean;
   Size     : U64;
   St       : U64;
   Index    : U64 := 0;

   procedure Put_Size (S : U64) is
      Img   : constant String := S'Image;  --  leading space
      Field : constant := 10;
      Pad   : constant Natural :=
        (if Img'Length - 1 >= Field then 1
         else Field - (Img'Length - 1));
   begin
      Akernel_User.Console.Put (String'(1 .. Pad => ' '));
      Akernel_User.Console.Put (Img (2 .. Img'Last));
   end Put_Size;

begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);
   Files.Set_Default_Volume ("BD0");

   declare
      Path : constant String :=
        (if CLI.Arg_Count = 0 then "BD0:" else CLI.Argument (1));
      Probe_Size : U64;
   begin
      --  Read_Dir answers Not_Found both for a missing path and
      --  for an exhausted enumeration, so probe first: a missing
      --  directory must exit RC_Error, not list empty.
      St := Files.Stat (Path, Probe_Size);
      if St = Files.Status_Not_Found then
         CLI.Fail_With ("List: can't read " & Path, CLI.RC_Error);
      end if;
      Akernel_User.Console.Put_Line ("Directory """ & Path & """:");
      loop
         St := Files.Read_Dir
           (Path, Index, Name, Name_Len, Is_Dir, Size);
         exit when St = Files.Status_Not_Found;
         if St /= Files.Status_Ok then
            CLI.Fail_With ("List: can't read " & Path,
                           CLI.RC_Error);
         end if;
         Akernel_User.Console.Put (Name (1 .. Name_Len));
         if Is_Dir then
            Akernel_User.Console.Put_Line ("             (dir)");
         else
            Put_Size (Size);
            Akernel_User.Console.Put_Line ("");
         end if;
         Index := Index + 1;
      end loop;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end List;
