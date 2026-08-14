with Interfaces;
with System;
with Ada.Text_IO;
with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Sort: order a file's lines byte-wise (milestone 41c; the
--  Amiga C:Sort analog). "Sort <from> <to>"; ascending on the
--  whole line, LF delimiters, every written line terminated
--  (a trailing partial line gains its LF). With NO arguments
--  (milestone 46b) Sort reads stdin and writes stdout — the
--  pipeline filter mode: "producer | Sort" and "Sort < in >
--  out" both ride the args-page redirection trailer.
--  Milestone 54: filter-mode stdout is Ada.Text_IO (rides the
--  console, redirect composes); stdin stays CLI.Get_Line (the
--  redirect-in trailer lives in CLI, gloss can't see it). The
--  input is slurped through the heap (1 MiB cap — the RTS
--  heap total is 2 MiB); insertion
--  sort — data-command inputs are small.
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
   --  The RTS heap caps at 2 MiB TOTAL (8 x 256 KiB chunks):
   --  the stdin slurp buffer must leave room for the 64 KiB
   --  line table + RTS slack (a 2 MiB buffer Storage_Error'd
   --  the process — m46b burn).
   Max_Input : constant U64 := 1024 * 1024;

   --  Line table: (start, length) pairs into the slurp buffer.
   --  Heap, NOT the main declarative part: 4096 x 16 bytes
   --  blows the 32 KiB process stack (the Sys:C/Type burn
   --  class — big tables are heap or library-level).
   Max_Lines : constant := 4096;
   type Line_Rec is record
      Start : U64;
      Len   : U64;
   end record;
   type Line_Array is array (Positive range <>) of Line_Rec;
   type Line_Access is access Line_Array;

   --  Lexicographic compare of two Buf ranges.
   function Less
     (Buf : Buf_Access; A_Start, A_Len, B_Start, B_Len : U64)
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

   --  Split Buf into lines, sort, write. Dst = "" writes to
   --  the console (stdout — redirected by the RTS trailer
   --  under a pipeline); otherwise Dst is a resolved fs path
   --  created/truncated by us.
   procedure Sort_And_Print
     (Buf    : Buf_Access;
      Size   : U64;
      Lines  : Line_Access;
      Dst    : String)
   is
      use type Interfaces.Unsigned_8;
      NLines : Natural := 0;
      St     : U64;
   begin
      --  Split into lines. A trailing LF does not produce an
      --  empty final line (it is the last line's terminator).
      declare
         Lo : U64 := 0;
         Hi : U64;
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
              and then Less (Buf, Key.Start, Key.Len,
                             Lines (J - 1).Start, Lines (J - 1).Len)
            loop
               Lines (J) := Lines (J - 1);
               J := J - 1;
            end loop;
            Lines (J) := Key;
         end;
      end loop;

      if Dst'Length = 0 then
         --  Stdout: convert each line to String chunks (pipe
         --  lines are short; chunk anyway) and let the RTS
         --  console layer route them.
         for I in 1 .. NLines loop
            declare
               L   : Line_Rec renames Lines (I);
               Off : U64 := 0;
               Seg : U64;
               S   : String (1 .. 512);
            begin
               while Off < L.Len loop
                  Seg := U64'Min (U64 (S'Length), L.Len - Off);
                  for K in 0 .. Seg - 1 loop
                     S (Natural (K) + 1) :=
                       Character'Val (Natural (Buf (L.Start + Off + K)));
                  end loop;
                  Ada.Text_IO.Put (S (1 .. Natural (Seg)));
                  Off := Off + Seg;
               end loop;
               Ada.Text_IO.New_Line;
            end;
         end loop;
         return;
      end if;

      --  File output: truncate an existing target, write each
      --  line plus its LF.
      declare
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
                 ("Sort: can't truncate " & Dst, CLI.RC_Error);
            end if;
         end if;
         for I in 1 .. NLines loop
            declare
               L   : Line_Rec renames Lines (I);
               Seg : U64;
               Off : U64 := 0;
            begin
               while Off < L.Len loop
                  Seg := U64'Min (Chunk, L.Len - Off);
                  St := Files.Write
                    (Dst, Dest,
                     Buf (L.Start + Off)'Address, Seg, Wrote);
                  if St /= Files.Status_Ok or else Wrote /= Seg then
                     CLI.Fail_With ("Sort: write failed",
                                    CLI.RC_Error);
                  end if;
                  Dest := Dest + Seg;
                  Off := Off + Seg;
               end loop;
               St := Files.Write
                 (Dst, Dest, NL (0)'Address, 1, Wrote);
               if St /= Files.Status_Ok or else Wrote /= 1 then
                  CLI.Fail_With ("Sort: write failed", CLI.RC_Error);
               end if;
               Dest := Dest + 1;
            end;
         end loop;
      end;
   end Sort_And_Print;

   St    : U64;
   Size  : U64;
   Buf   : Buf_Access;
   Lines : Line_Access;

begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count /= 0 and then CLI.Arg_Count /= 2 then
      CLI.Fail_With ("usage: Sort [<from> <to>]", CLI.RC_Error);
   end if;

   if CLI.Arg_Count = 0 then
      --  Filter mode (m46b): slurp stdin (the redirection
      --  trailer's in_path) into the heap buffer, LF-
      --  terminating every line so the split sees uniform
      --  records. Stdout rides the console layer.
      Buf := new Byte_Array (0 .. Max_Input - 1);
      Lines := new Line_Array (1 .. Max_Lines);
      Size := 0;
      declare
         L   : String (1 .. 512);
         Len : Natural;
         EOF : Boolean;
      begin
         loop
            CLI.Get_Line (L, Len, EOF);
            exit when EOF;
            if Size + U64 (Len) + 1 > Max_Input then
               CLI.Fail_With ("Sort: too much input", CLI.RC_Error);
            end if;
            for I in 1 .. Len loop
               Buf (Size + U64 (I) - 1) :=
                 Byte (Character'Pos (L (I)));
            end loop;
            Size := Size + U64 (Len);
            Buf (Size) := LF;
            Size := Size + 1;
         end loop;
      end;
      Sort_And_Print (Buf, Size, Lines, "");
      CLI.Exit_With (CLI.RC_Ok);
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

   Sort_And_Print (Buf, Size, Lines, Dst);
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Sort;
