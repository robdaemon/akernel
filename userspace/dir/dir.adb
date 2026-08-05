with Interfaces;
with Akernel_User.Syscalls;
with Akernel_User.Console;
with Akernel_User.Files;

--  Dir: list a directory (milestone 32; the Amiga C:Dir analog —
--  lives in Sys:C/Dir, the shell resolves bare command names
--  against C/). Spawned by the shell under the uniform program
--  ABI: 1 = console stream (Send), 2 = file server (Send),
--  3 = Bureau svc (unused; Dir opens no window).
--
--  No arguments yet (the shell passes none): lists the root of
--  the default volume BD0:. Directories print with a "(dir)"
--  tag; files with their byte size. Enumeration is stateless:
--  entry index 0.. until the file protocol says Not_Found.

procedure Dir is
   use Akernel_User.Syscalls;
   use type U64;

   Console_EP : constant U64 := 1;
   FS_EP      : constant U64 := 2;

   Name     : String (1 .. 24);
   Name_Len : Natural;
   Is_Dir   : Boolean;
   Size     : U64;
   St       : U64;
   Index    : U64 := 0;
begin
   Akernel_User.Console.Set_Endpoint (Console_EP);
   Akernel_User.Files.Bind (FS_EP);
   Akernel_User.Files.Set_Default_Volume ("BD0");

   loop
      St := Akernel_User.Files.Read_Dir
        ("BD0:", Index, Name, Name_Len, Is_Dir, Size);
      exit when St /= Akernel_User.Files.Status_Ok;
      if Is_Dir then
         Akernel_User.Console.Put_Line
           ("  " & Name (1 .. Name_Len) & "  (dir)");
      else
         Akernel_User.Console.Put_Line
           ("  " & Name (1 .. Name_Len) & " " & Size'Image);
      end if;
      Index := Index + 1;
   end loop;

   Process_Exit;
end Dir;
