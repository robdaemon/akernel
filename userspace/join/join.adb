with Ada.Command_Line;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Akernel_User.CLI;

--  Join: concatenate files (milestone 41c; the Amiga C:Join
--  analog). "Join <f1> <f2> [...] TO <out>"; the TO keyword is
--  case-insensitive and required. An existing output file is
--  truncated first (overwrite semantics — Stream_IO Create
--  truncates).
--
--  Milestone 54: standard library — bytes move through
--  Ada.Streams.Stream_IO in 32 KiB heap chunks, args from
--  Ada.Command_Line.

procedure Join is
   package CLI renames Akernel_User.CLI;
   package SIO renames Ada.Streams.Stream_IO;
   use type Ada.Streams.Stream_Element_Offset;

   --  Heap, not the 12-page stack (the Sys:C/Type burn).
   type Buf_Access is access Ada.Streams.Stream_Element_Array;
   Buf : constant Buf_Access :=
     new Ada.Streams.Stream_Element_Array (1 .. 32 * 1024);

   Out_F  : SIO.File_Type;
   To_Idx : Natural := 0;  --  arg index of the TO keyword

   function Is_To (S : String) return Boolean is
     (S'Length = 2
      and then (S (S'First) = 'T' or else S (S'First) = 't')
      and then (S (S'Last) = 'O' or else S (S'Last) = 'o'));

   procedure Append (From : String) is
      In_F : SIO.File_Type;
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      SIO.Open (In_F, SIO.In_File, From);
      while not SIO.End_Of_File (In_F) loop
         SIO.Read (In_F, Buf.all, Last);
         exit when Last = 0;
         SIO.Write (Out_F, Buf.all (1 .. Last));
      end loop;
      SIO.Close (In_F);
   end Append;

begin
   CLI.Init;

   for I in 1 .. Ada.Command_Line.Argument_Count loop
      if Is_To (Ada.Command_Line.Argument (I)) then
         To_Idx := I;
         exit;
      end if;
   end loop;

   if To_Idx < 2 or else To_Idx = Ada.Command_Line.Argument_Count
   then
      CLI.Fail_With ("usage: Join <f1> <f2> [...] TO <out>",
                     CLI.RC_Error);
   end if;

   declare
      Out_Path : constant String :=
        CLI.Resolve_Path (Ada.Command_Line.Argument (To_Idx + 1));
   begin
      for I in 1 .. To_Idx - 1 loop
         if CLI.Resolve_Path (Ada.Command_Line.Argument (I)) =
              Out_Path
         then
            CLI.Fail_With
              ("Join: input and output are the same", CLI.RC_Error);
         end if;
      end loop;

      begin
         SIO.Create (Out_F, SIO.Out_File, Out_Path);
      exception
         when others =>
            CLI.Fail_With
              ("Join: can't create " & Out_Path, CLI.RC_Error);
      end;

      for I in 1 .. To_Idx - 1 loop
         declare
            From : constant String :=
              CLI.Resolve_Path (Ada.Command_Line.Argument (I));
         begin
            Append (From);
         exception
            when SIO.Name_Error =>
               SIO.Close (Out_F);
               CLI.Fail_With
                 ("Join: can't open " & From, CLI.RC_Error);
         end;
      end loop;

      SIO.Close (Out_F);
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Join;
