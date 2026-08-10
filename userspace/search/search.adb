with Interfaces;
with System;
with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Search: print the lines of a file containing a string
--  (milestone 41c; the Amiga C:Search analog, grep-lite).
--  "Search <file> <string>"; case-sensitive substring match,
--  matching lines print verbatim. The whole file is slurped
--  through the heap (the 2 MiB heap cap is the file size limit;
--  the process stack stays clear).
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send).

procedure Search is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   subtype U64 is CLI.U64;
   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of Byte;
   type Buf_Access is access Byte_Array;

   Chunk : constant U64 := 32 * 1024;

   function Contains
     (Buf : Byte_Array; Lo, Hi : U64; Pat : String) return Boolean
   is
      use type Interfaces.Unsigned_8;
   begin
      if Pat'Length = 0 or else Hi - Lo + 1 < U64 (Pat'Length) then
         return Pat'Length = 0;
      end if;
      for I in Lo .. Hi - U64 (Pat'Length) + 1 loop
         declare
            Hit : Boolean := True;
         begin
            for J in Pat'Range loop
               if Buf (I + U64 (J - Pat'First)) /=
                 Byte (Character'Pos (Pat (J)))
               then
                  Hit := False;
                  exit;
               end if;
            end loop;
            if Hit then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Contains;

   St   : U64;
   Size : U64;
   Buf  : Buf_Access;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count /= 2 then
      CLI.Fail_With ("usage: Search <file> <string>", CLI.RC_Error);
   end if;

   declare
      Src : constant String := CLI.Resolve_Path (CLI.Argument (1));
   begin
   St := Files.Open (Src, Size);
   if St /= Files.Status_Ok then
      CLI.Fail_With
        ("Search: can't open " & Src, CLI.RC_Error);
   end if;

   Buf := new Byte_Array (0 .. (if Size = 0 then 0 else Size - 1));
   declare
      Off   : U64 := 0;
      Count : U64;
   begin
      while Off < Size loop
         St := Files.Read
           (Src, Off, Buf.all'Address,
            U64'Min (Chunk, Size - Off), Count);
         if St /= Files.Status_Ok or else Count = 0 then
            CLI.Fail_With ("Search: read failed", CLI.RC_Error);
         end if;
         Off := Off + Count;
      end loop;
   end;
   end;

   --  Walk LF-delimited lines; print the ones containing the
   --  string.
   declare
      Pat  : constant String := CLI.Argument (2);
      Lo   : U64 := 0;
      Hits : Natural := 0;
      Line : String (1 .. 1024);
      LLen : Natural;
      use type Interfaces.Unsigned_8;
   begin
      while Lo < Size loop
         declare
            Hi : U64 := Lo;
         begin
            while Hi < Size
              and then Buf (Hi) /= 10  --  ASCII.LF
            loop
               Hi := Hi + 1;
            end loop;
            if Hi - Lo <= U64 (Line'Length)
              and then Contains (Buf.all, Lo,
                                 (if Hi = Lo then Lo else Hi - 1),
                                 Pat)
            then
               LLen := Natural (Hi - Lo);
               for I in 0 .. LLen - 1 loop
                  Line (I + 1) :=
                    Character'Val (Natural (Buf (Lo + U64 (I))));
               end loop;
               Akernel_User.Console.Put_Line (Line (1 .. LLen));
               Hits := Hits + 1;
            end if;
            Lo := Hi + 1;
         end;
      end loop;
      if Hits = 0 then
         Akernel_User.Console.Put_Line ("Search: no match");
      end if;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Search;
