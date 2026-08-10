with Interfaces;
with System;
with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Copy: duplicate a file (milestone 41; the Amiga C:Copy
--  analog). "Copy <from> <to>"; an existing destination is
--  truncated first (overwrite semantics). Chunked through the
--  shared 32 KiB client buffer; the heap copy buffer keeps the
--  32 KiB process stack clear (the Sys:C/Type burn).
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send).

procedure Copy is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   subtype U64 is CLI.U64;
   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of Byte;
   type Buf_Access is access Byte_Array;

   Chunk : constant U64 := 32 * 1024;

   St     : U64;
   Size   : U64;
   TSize  : U64;
   Count  : U64;
   Off    : U64 := 0;
   Buf    : Buf_Access;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count /= 2 then
      CLI.Fail_With ("usage: Copy <from> <to>", CLI.RC_Error);
   end if;

   --  Paths resolve AFTER the fs bind: Resolve_Path reads the
   --  ENV:CWD variable through the file server (milestone 42).
   declare
      From : constant String := CLI.Resolve_Path (CLI.Argument (1));
      To   : constant String := CLI.Resolve_Path (CLI.Argument (2));
   begin   if From = To then
      CLI.Fail_With
        ("Copy: source and destination are the same", CLI.RC_Error);
   end if;

   St := Files.Open (From, Size);
   if St /= Files.Status_Ok then
      CLI.Fail_With ("Copy: can't open " & From, CLI.RC_Error);
   end if;

   St := Files.Stat (To, TSize);
   if St = Files.Status_Ok then
      St := Files.Truncate (To);
      if St /= Files.Status_Ok then
         CLI.Fail_With ("Copy: can't truncate " & To, CLI.RC_Error);
      end if;
   end if;

   Buf := new Byte_Array (0 .. Chunk - 1);

   while Off < Size loop
      St := Files.Read
        (From, Off, Buf.all'Address,
         U64'Min (Chunk, Size - Off), Count);
      if St /= Files.Status_Ok or else Count = 0 then
         CLI.Fail_With ("Copy: read failed on " & From, CLI.RC_Error);
      end if;

      declare
         Written : U64;
      begin
         St := Files.Write (To, Off, Buf.all'Address, Count, Written);
         if St /= Files.Status_Ok or else Written /= Count then
            CLI.Fail_With
              ("Copy: write failed on " & To, CLI.RC_Error);
         end if;
      end;

      Off := Off + Count;
   end loop;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Copy;
