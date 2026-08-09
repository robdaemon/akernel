with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Info: volume capacity (milestone 41; the Amiga C:Info
--  analog). "Info [<volume>]"; no argument reports the system
--  volume Sys:. Prints total / free / used bytes and the
--  cluster size; free reads the FAT FSInfo count maintained by
--  the fs driver.
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send).

procedure Info is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   procedure Report (Volume : String) is
      Total   : CLI.U64;
      Free    : CLI.U64;
      Cluster : CLI.U64;
      St      : constant CLI.U64 :=
        Files.Volume_Info (Volume, Total, Free, Cluster);
   begin
      if St /= Files.Status_Ok then
         Akernel_User.Console.Put_Line
           ("Info: can't query " & Volume);
         return;
      end if;
      Akernel_User.Console.Put_Line ("volume " & Volume);
      Akernel_User.Console.Put_Line ("  total  " & Total'Image & " bytes");
      if Free = CLI.U64'Last then
         Akernel_User.Console.Put_Line ("  free   unknown");
      else
         Akernel_User.Console.Put_Line
           ("  free   " & Free'Image & " bytes");
         Akernel_User.Console.Put_Line
           ("  used   " & CLI.U64'Image (Total - Free) & " bytes");
      end if;
      Akernel_User.Console.Put_Line
        ("  cluster" & Cluster'Image & " bytes");
   end Report;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);
   Files.Set_Default_Volume ("BD0");

   if CLI.Arg_Count = 0 then
      Report ("Sys:");
   else
      for I in 1 .. CLI.Arg_Count loop
         Report (CLI.Argument (I));
      end loop;
   end if;

   CLI.Exit_With (CLI.RC_Ok);
end Info;
