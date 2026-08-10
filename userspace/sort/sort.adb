with Interfaces;
with System;
with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Sort: order a file's lines byte-wise (milestone 41c; the
--  Amiga C:Sort analog). "Sort <from> <to>"; ascending on the
--  whole line, LF delimiters, every written line terminated
--  (a trailing partial line gains its LF). The file is slurped
--  through the heap (2 MiB cap); insertion sort — data-command
--  inputs are small.
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send).

procedure Sort is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   subtype U64 is CLI.U64;
   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of Byte;
   type Buf_Access is access Byte_Array;

   LF : constant Byte := Byte (Character'Pos (ASCII.LF));
   Chunk : constant U64 := 32 * 1024;

   St   : U64;
   Size : U64;
   Buf  : Buf_Access;

   --  Line table: (start, length) pairs into Buf. Heap, NOT the
   --  main declarative part: 4096 x 16 bytes blows the 32 KiB
   --  process stack (the Sys:C/Type burn class — big tables are
   --  heap or library-level).
   Max_Lines : constant := 4096;
   type Line_Rec is record
      Start : U64;
      Len   : U64;
   end record;
   type Line_Array is array (Positive range <>) of Line_Rec;
   type Line_Access is access Line_Array;
   Lines  : Line_Access;
   NLines : Natural := 0;

   --  Lexicographic compare of two Buf ranges.
   function Less (A_Start, A_Len, B_Start, B_Len : U64)
                  return Boolean
   is
      use type Interfaces.Unsigned_8;
      N : constant U64 := U64'Min (A_Len, B_Len);
   begin
      for I in 0 .. N - 1 loop
         if Buf (A_Start + I) /= Buf (B_Start + I) then
            return Buf (A_Start + I) < Buf (B_Start + I);
         end if;
      end loop;
      return A_Len < B_Len;
   end Less;

begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count /= 2 then
      CLI.Fail_With ("usage: Sort <from> <to>", CLI.RC_Error);
   end if;

   --  Resolve after the fs bind: Resolve_Path reads ENV:CWD
   --  through the file server (milestone 42).
   declare
      Src : constant String := CLI.Resolve_Path (CLI.Argument (1));
      Dst : constant String := CLI.Resolve_Path (CLI.Argument (2));
   begin
   if Src = Dst then
      CLI.Fail_With
        ("Sort: source and destination are the same", CLI.RC_Error);
   end if;

   St := Files.Open (Src, Size);
   if St /= Files.Status_Ok then
      CLI.Fail_With
        ("Sort: can't open " & Src, CLI.RC_Error);
   end if;

   Buf := new Byte_Array (0 .. (if Size = 0 then 0 else Size - 1));
   Lines := new Line_Array (1 .. Max_Lines);
   declare
      Off   : U64 := 0;
      Count : U64;
   begin
      while Off < Size loop
         St := Files.Read
           (Src, Off, Buf.all'Address,
            U64'Min (Chunk, Size - Off), Count);
         if St /= Files.Status_Ok or else Count = 0 then
            CLI.Fail_With ("Sort: read failed", CLI.RC_Error);
         end if;
         Off := Off + Count;
      end loop;
   end;

   --  Split into lines. A trailing LF does not produce an empty
   --  final line (it is the last line's terminator).
   declare
      Lo : U64 := 0;
      Hi : U64;
      use type Interfaces.Unsigned_8;
   begin
      while Lo < Size loop
         Hi := Lo;
         while Hi < Size and then Buf (Hi) /= LF loop
            Hi := Hi + 1;
         end loop;
         if NLines = Max_Lines then
            CLI.Fail_With ("Sort: too many lines", CLI.RC_Error);
         end if;
         NLines := NLines + 1;
         Lines (NLines) := (Start => Lo, Len => Hi - Lo);
         Lo := Hi + 1;
      end loop;
   end;

   --  Insertion sort (stable).
   for I in 2 .. NLines loop
      declare
         Key : constant Line_Rec := Lines (I);
         J   : Natural := I;
      begin
         while J > 1
           and then Less (Key.Start, Key.Len,
                          Lines (J - 1).Start, Lines (J - 1).Len)
         loop
            Lines (J) := Lines (J - 1);
            J := J - 1;
         end loop;
         Lines (J) := Key;
      end;
   end loop;

   --  Write out: each line plus its LF.
   declare
      Out_Buf : Byte_Array renames Buf.all;
      NL      : array (0 .. 0) of Byte := (0 => LF);
      Dest    : U64 := 0;
      Wrote   : U64;
      DSize   : U64;
   begin
      St := Files.Stat (Dst, DSize);
      if St = Files.Status_Ok then
         St := Files.Truncate (Dst);
         if St /= Files.Status_Ok then
            CLI.Fail_With
              ("Sort: can't truncate " & Dst,
               CLI.RC_Error);
         end if;
      end if;
      for I in 1 .. NLines loop
         declare
            L    : Line_Rec renames Lines (I);
            Seg  : U64;
            Off  : U64 := 0;
         begin
            while Off < L.Len loop
               Seg := U64'Min (Chunk, L.Len - Off);
               St := Files.Write
                 (Dst, Dest,
                  Out_Buf (L.Start + Off)'Address, Seg, Wrote);
               if St /= Files.Status_Ok or else Wrote /= Seg then
                  CLI.Fail_With ("Sort: write failed", CLI.RC_Error);
               end if;
               Dest := Dest + Seg;
               Off := Off + Seg;
            end loop;
            St := Files.Write
              (Dst, Dest, NL (0)'Address, 1,
               Wrote);
            if St /= Files.Status_Ok or else Wrote /= 1 then
               CLI.Fail_With ("Sort: write failed", CLI.RC_Error);
            end if;
            Dest := Dest + 1;
         end;
      end loop;
   end;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Sort;
