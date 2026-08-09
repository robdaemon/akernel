with Interfaces;
with System;
with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Join: concatenate files (milestone 41c; the Amiga C:Join
--  analog). "Join <f1> <f2> [...] TO <out>"; the TO keyword is
--  case-insensitive and required. An existing output file is
--  truncated first (overwrite semantics). Chunked through the
--  shared 32 KiB client buffer; the heap copy buffer keeps the
--  process stack clear (the Sys:C/Type burn).
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send).

procedure Join is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   subtype U64 is CLI.U64;
   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of Byte;
   type Buf_Access is access Byte_Array;

   Chunk : constant U64 := 32 * 1024;

   Buf     : Buf_Access;
   To_Idx  : Natural := 0;  --  arg index of the TO keyword
   Inputs  : Natural;
   Dest    : U64 := 0;      --  write offset in the output file
   St      : U64;
   DSize   : U64;

   function Is_To (S : String) return Boolean is
     (S'Length = 2
      and then (S (S'First) = 'T' or else S (S'First) = 't')
      and then (S (S'Last) = 'O' or else S (S'Last) = 'o'));

   procedure Append (From : String) is
      Size  : U64;
      Count : U64;
      Wrote : U64;
      Off   : U64 := 0;
   begin
      St := Files.Open (From, Size);
      if St /= Files.Status_Ok then
         CLI.Fail_With ("Join: can't open " & From, CLI.RC_Error);
      end if;
      while Off < Size loop
         St := Files.Read
           (From, Off, Buf.all'Address,
            U64'Min (Chunk, Size - Off), Count);
         if St /= Files.Status_Ok or else Count = 0 then
            CLI.Fail_With ("Join: read failed on " & From,
                           CLI.RC_Error);
         end if;
         St := Files.Write
           (CLI.Argument (To_Idx + 1), Dest, Buf.all'Address,
            Count, Wrote);
         if St /= Files.Status_Ok or else Wrote /= Count then
            CLI.Fail_With ("Join: write failed", CLI.RC_Error);
         end if;
         Dest := Dest + Count;
         Off := Off + Count;
      end loop;
   end Append;

begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);
   Files.Set_Default_Volume ("BD0");

   for I in 1 .. CLI.Arg_Count loop
      if Is_To (CLI.Argument (I)) then
         To_Idx := I;
         exit;
      end if;
   end loop;

   if To_Idx < 2 or else To_Idx = CLI.Arg_Count then
      CLI.Fail_With ("usage: Join <f1> <f2> [...] TO <out>",
                     CLI.RC_Error);
   end if;
   Inputs := To_Idx - 1;

   for I in 1 .. Inputs loop
      if CLI.Argument (I) = CLI.Argument (To_Idx + 1) then
         CLI.Fail_With
           ("Join: input and output are the same", CLI.RC_Error);
      end if;
   end loop;

   --  Overwrite semantics: truncate an existing output first.
   St := Files.Stat (CLI.Argument (To_Idx + 1), DSize);
   if St = Files.Status_Ok then
      St := Files.Truncate (CLI.Argument (To_Idx + 1));
      if St /= Files.Status_Ok then
         CLI.Fail_With
           ("Join: can't truncate " & CLI.Argument (To_Idx + 1),
            CLI.RC_Error);
      end if;
   end if;

   Buf := new Byte_Array (0 .. Chunk - 1);
   for I in 1 .. Inputs loop
      Append (CLI.Argument (I));
   end loop;

   CLI.Exit_With (CLI.RC_Ok);
end Join;
