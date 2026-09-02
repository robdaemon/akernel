with Ada.Text_IO;
with Akernel_User.CLI;
with Akernel_User.Files;
with Interfaces;

--  Query: one-shot BeFS query (milestone 82f — the Amiga C:
--  analog would be a find; BeOS calls this `query`). Usage:
--
--    query <volume> <predicate...>
--
--  e.g.  query BD1: name=="*.TXT" && size>0
--
--  The predicate is all arguments from the second on, joined
--  with spaces (the shell has no quoting; literal '"' pass
--  through and are required around string values). Grammar:
--  term with == != < <= > >= over "name" (*/? globs), "size",
--  "last_modified" (seconds since epoch) or any small_data
--  attribute, combined with && || ! and parens. One matching
--  volume-relative path per line; directories print with a
--  trailing slash.

procedure Query is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type Interfaces.Unsigned_64;
   use type Files.U64;

   Vol  : String (1 .. 33);
   VLen : Natural;
   Pred : String (1 .. 255);
   PLen : Natural := 0;
   Path : String (1 .. 24);
   PL   : Natural;
   Size : Files.U64;
   Is_D : Boolean;
   St   : Files.U64;
   Idx  : Files.U64 := 0;
begin
   CLI.Init;
   if CLI.Arg_Count < 2 then
      Ada.Text_IO.Put_Line ("usage: Query <volume> <predicate...>");
      CLI.Exit_With (CLI.RC_Error);
   end if;

   --  Volume: accept "BD1" or "BD1:".
   declare
      V : constant String := CLI.Argument (1);
   begin
      if V'Length = 0 or else V'Length > 32 then
         Ada.Text_IO.Put_Line ("Query: bad volume");
         CLI.Exit_With (CLI.RC_Error);
      end if;
      Vol (1 .. V'Length) := V;
      VLen := V'Length;
   end;
   if Vol (VLen) /= ':' then
      VLen := VLen + 1;
      Vol (VLen) := ':';
   end if;

   --  Predicate: join the remaining arguments.
   for A in 2 .. CLI.Arg_Count loop
      declare
         T : constant String := CLI.Argument (A);
      begin
         if PLen + T'Length + 1 > Pred'Last then
            Ada.Text_IO.Put_Line ("Query: predicate too long");
            CLI.Exit_With (CLI.RC_Error);
         end if;
         if PLen > 0 then
            PLen := PLen + 1;
            Pred (PLen) := ' ';
         end if;
         Pred (PLen + 1 .. PLen + T'Length) := T;
         PLen := PLen + T'Length;
      end;
   end loop;

   loop
      St := Files.Query (Vol (1 .. VLen), Pred (1 .. PLen), Idx,
                         Path, PL, Size, Is_D);
      exit when St /= Files.Status_Ok;
      Ada.Text_IO.Put_Line
        (Path (1 .. PL) & (if Is_D then "/" else ""));
      Idx := Idx + 1;
   end loop;

   if St = Files.Status_Bad_Args then
      Ada.Text_IO.Put_Line ("Query: bad predicate (or volume has no query support)");
      CLI.Exit_With (CLI.RC_Error);
   end if;
   --  Not_Found just ends the list (possibly empty).
   CLI.Exit_With (CLI.RC_Ok);
end Query;
