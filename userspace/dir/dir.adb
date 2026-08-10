with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Dir: list a directory (milestone 32; the Amiga C:Dir analog —
--  lives in Sys:C/Dir). Spawned by the shell under the uniform
--  program ABI: 1 = console stream (Send), 2 = file server
--  (Send), 3 = Bureau svc (unused; Dir opens no window).
--
--  No argument lists the CURRENT DIRECTORY (milestone 44 — the
--  Amiga semantic; pre-cwd this listed the default volume
--  root); "Dir <path>" lists that directory, resolved against
--  the cwd. Directories print with a "(dir)" tag; files with
--  their byte size. Enumeration is stateless: entry index 0..
--  until the file protocol says Not_Found.

procedure Dir is
   package CLI renames Akernel_User.CLI;
   use type CLI.U64;

   Name     : String (1 .. 24);
   Name_Len : Natural;
   Is_Dir   : Boolean;
   Size     : CLI.U64;
   St       : CLI.U64;
   Index    : CLI.U64 := 0;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Akernel_User.Files.Bind (2);

   declare
      Path : constant String :=
        (if CLI.Arg_Count = 0 then CLI.Get_Cwd
         else CLI.Resolve_Path (CLI.Argument (1)));
   begin
      loop
         St := Akernel_User.Files.Read_Dir
           (Path, Index, Name, Name_Len, Is_Dir, Size);
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

      if Index = 0 then
         CLI.Fail_With ("Dir: can't open " & Path, CLI.RC_Error);
      end if;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Dir;
