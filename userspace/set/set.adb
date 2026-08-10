with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Set: set or list environment variables (milestone 41b; the
--  Amiga C:Set analog). Variables are files in ENV: (resolved to
--  Sys:Prefs/Env by the VFS assign table). "Set" lists all
--  NAME=value pairs; "Set NAME=VALUE" or "Set NAME VALUE" sets
--  one. The directory is created on demand.

procedure Set is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   Env_Dir : constant String := "ENV:";

   procedure Ensure is
      St1 : constant CLI.U64 := Files.Mkdir ("BD0:Prefs");
      St2 : constant CLI.U64 := Files.Mkdir ("BD0:Prefs/Env");
   begin
      Akernel_User.Console.Put_Line
        ("Set: ensure Prefs status " & CLI.U64'Image (St1));
      Akernel_User.Console.Put_Line
        ("Set: ensure Prefs/Env status " & CLI.U64'Image (St2));
   end Ensure;

   function Eq_Pos (S : String) return Natural is
   begin
      for I in S'Range loop
         if S (I) = '=' then
            return I;
         end if;
      end loop;
      return 0;
   end Eq_Pos;

   procedure List_All is
      Name     : String (1 .. 24);
      Name_Len : Natural;
      Is_Dir   : Boolean;
      Size     : CLI.U64;
      St       : CLI.U64;
      Idx      : CLI.U64 := 0;
      Value    : constant String := "";
   begin
      loop
         St := Files.Read_Dir (Env_Dir, Idx, Name, Name_Len, Is_Dir, Size);
         exit when St /= Files.Status_Ok;
         if not Is_Dir and then Name_Len > 0 then
            declare
               V : constant String := CLI.Get_Env (Name (1 .. Name_Len));
            begin
               Akernel_User.Console.Put_Line
                 (Name (1 .. Name_Len) & "=" & V);
            end;
         end if;
         Idx := Idx + 1;
      end loop;
   end List_All;

begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   if CLI.Arg_Count = 0 then
      List_All;
      CLI.Exit_With (CLI.RC_Ok);
   end if;

   if CLI.Arg_Count = 1 then
      declare
         Arg : constant String := CLI.Argument (1);
         Eq  : constant Natural := Eq_Pos (Arg);
      begin
         if Eq = 0 then
            CLI.Fail_With ("usage: Set NAME=VALUE or Set NAME VALUE",
                           CLI.RC_Error);
         end if;
         Ensure;
         declare
            St : constant CLI.U64 :=
              CLI.Set_Env (Arg (Arg'First .. Eq - 1),
                           Arg (Eq + 1 .. Arg'Last));
         begin
            if St /= Files.Status_Ok then
               CLI.Fail_With
                 ("Set: failed to write variable (status "
                  & CLI.U64'Image (St) & ")", CLI.RC_Error);
            end if;
         end;
      end;
   elsif CLI.Arg_Count = 2 then
      Ensure;
      declare
         St : constant CLI.U64 :=
           CLI.Set_Env (CLI.Argument (1), CLI.Argument (2));
      begin
         if St /= Files.Status_Ok then
            CLI.Fail_With
              ("Set: failed to write variable (status "
               & CLI.U64'Image (St) & ")", CLI.RC_Error);
         end if;
      end;
   else
      CLI.Fail_With ("usage: Set [NAME=VALUE | NAME VALUE]",
                     CLI.RC_Error);
   end if;

   CLI.Exit_With (CLI.RC_Ok);
end Set;
