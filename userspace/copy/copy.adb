with Ada.Command_Line;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Akernel_User.CLI;

--  Copy: duplicate a file (milestone 41; the Amiga C:Copy
--  analog). "Copy <from> <to>"; an existing destination is
--  truncated first (overwrite semantics — Stream_IO Create
--  truncates).
--
--  Milestone 54: standard library — bytes move through
--  Ada.Streams.Stream_IO in 32 KiB chunks (the heap buffer keeps
--  the 12-page process stack clear), args from Ada.Command_Line.

procedure Copy is
   package CLI renames Akernel_User.CLI;
   package SIO renames Ada.Streams.Stream_IO;
   use type Ada.Streams.Stream_Element_Offset;

   In_F  : SIO.File_Type;
   Out_F : SIO.File_Type;
begin
   CLI.Init;

   if Ada.Command_Line.Argument_Count /= 2 then
      CLI.Fail_With ("usage: Copy <from> <to>", CLI.RC_Error);
   end if;

   declare
      From : constant String :=
        CLI.Resolve_Path (Ada.Command_Line.Argument (1));
      To   : constant String :=
        CLI.Resolve_Path (Ada.Command_Line.Argument (2));
   begin
      if From = To then
         CLI.Fail_With
           ("Copy: source and destination are the same",
            CLI.RC_Error);
      end if;

      SIO.Open (In_F, SIO.In_File, From);
      SIO.Create (Out_F, SIO.Out_File, To);

      declare
         --  Heap, not the 12-page stack (the Sys:C/Type burn).
         type Buf_Access is access Ada.Streams.Stream_Element_Array;
         Buf  : constant Buf_Access :=
           new Ada.Streams.Stream_Element_Array (1 .. 32 * 1024);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         while not SIO.End_Of_File (In_F) loop
            SIO.Read (In_F, Buf.all, Last);
            exit when Last = 0;
            SIO.Write (Out_F, Buf.all (1 .. Last));
         end loop;
      end;

      SIO.Close (In_F);
      SIO.Close (Out_F);
   exception
      when SIO.Name_Error =>
         CLI.Fail_With ("Copy: can't open " & From, CLI.RC_Error);
      when others =>
         CLI.Fail_With
           ("Copy: can't copy " & From & " to " & To, CLI.RC_Error);
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Copy;
