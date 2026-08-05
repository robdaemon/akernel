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
--  No argument lists the root of the default volume BD0:;
--  "Dir <path>" (argument page, handle 4) lists that directory.
--  Directories print with a "(dir)"
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
   Arg_Buf  : String (1 .. 240);
   Arg_Len  : Natural;
   Path     : String (1 .. 256);
   Path_Len : Natural;
begin
   Akernel_User.Console.Set_Endpoint (Console_EP);
   Akernel_User.Files.Bind (FS_EP);
   Akernel_User.Files.Set_Default_Volume ("BD0");

   Read_Args (Arg_Buf, Arg_Len);
   if Arg_Len = 0 then
      Path_Len := 4;
      Path (1 .. 4) := "BD0:";
   elsif Arg_Len >= 4 and then Arg_Buf (1) = 'B'
     and then Arg_Buf (2) = 'D'
     and then Arg_Buf (3) = '0' and then Arg_Buf (4) = ':'
   then
      Path_Len := Arg_Len;
      Path (1 .. Arg_Len) := Arg_Buf (1 .. Arg_Len);
   else
      Path_Len := 4 + Arg_Len;
      Path (1 .. 4) := "BD0:";
      Path (5 .. Path_Len) := Arg_Buf (1 .. Arg_Len);
   end if;

   loop
      St := Akernel_User.Files.Read_Dir
        (Path (1 .. Path_Len), Index, Name, Name_Len, Is_Dir, Size);
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
