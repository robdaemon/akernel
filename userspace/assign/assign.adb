with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Assign: set, remove, or list path assigns (milestone 41b; the
--  Amiga C:Assign analog). "Assign" lists all assigns; "Assign
--  NAME: TARGET" creates or replaces one; "Assign NAME: REMOVE"
--  drops one.

procedure Assign is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   function Colon_Pos (S : String) return Natural is
   begin
      for I in S'Range loop
         if S (I) = ':' then
            return I;
         end if;
      end loop;
      return 0;
   end Colon_Pos;

begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);
   Files.Set_Default_Volume ("BD0");

   if CLI.Arg_Count = 0 then
      declare
         Text     : String (1 .. 40);
         Text_Len : Natural;
         St       : CLI.U64;
         Idx      : CLI.U64 := 0;
      begin
         loop
            St := Files.Assign_List (Idx, Text, Text_Len);
            exit when St /= Files.Status_Ok;
            Akernel_User.Console.Put_Line (Text (1 .. Text_Len));
            Idx := Idx + 1;
         end loop;
      end;
      CLI.Exit_With (CLI.RC_Ok);
   end if;

   if CLI.Arg_Count /= 2 then
      CLI.Fail_With
        ("usage: Assign NAME: TARGET  or  Assign NAME: REMOVE",
         CLI.RC_Error);
   end if;

   declare
      Name : constant String := CLI.Argument (1);
      Col  : constant Natural := Colon_Pos (Name);
      Tgt  : constant String := CLI.Argument (2);
   begin
      if Col = 0 or else Col /= Name'Last then
         CLI.Fail_With
           ("usage: Assign NAME: TARGET  or  Assign NAME: REMOVE",
            CLI.RC_Error);
      end if;

      if Tgt = "REMOVE" then
         if Files.Assign_Set (Name (Name'First .. Col - 1), "") /=
              Files.Status_Ok
         then
            CLI.Fail_With
              ("Assign: can't remove " & Name, CLI.RC_Error);
         end if;
      else
         if Files.Assign_Set (Name (Name'First .. Col - 1), Tgt) /=
              Files.Status_Ok
         then
            CLI.Fail_With ("Assign: failed", CLI.RC_Error);
         end if;
      end if;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Assign;
