with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  Path: the command search list (milestone 43; the Amiga
--  C:Path analog). "Path" lists the entries, one per line;
--  "Path <dir> ADD" appends; "Path <dir> REMOVE" drops;
--  "Path RESET" unsets the variable (back to the built-in
--  default search: current dir, volume root, C:). The current
--  directory is always searched first regardless — the list
--  replaces only the built-in root+C: tail.
--
--  The list is the ENV:Path variable (';'-separated prefixes),
--  GLOBAL like every variable — the Amiga keeps the list
--  per-process, which needs session identity we do not have
--  (same ruling as ENV:CWD, milestone 42). Entries canonicalize
--  at ADD time: resolved against the cwd, made fully qualified
--  with a trailing separator, deduped case-insensitively.
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send).

procedure Path is
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   use type CLI.U64;

   Max_List : constant := 240;  --  ENV values cap at 255 chars

   function Same (A, B : String) return Boolean is
      function Low (C : Character) return Character is
        (if C in 'A' .. 'Z'
         then Character'Val (Character'Pos (C) + 32) else C);
   begin
      if A'Length /= B'Length then
         return False;
      end if;
      for I in A'Range loop
         if Low (A (I)) /= Low (B (I - A'First + B'First)) then
            return False;
         end if;
      end loop;
      return True;
   end Same;

   --  Resolve against the cwd and force a trailing separator:
   --  Resolve_Command concatenates prefix & name directly.
   function Canonical (Dir : String) return String is
      R : constant String := CLI.Resolve_Path (Dir);
   begin
      if R'Length > 0
        and then (R (R'Last) = ':' or else R (R'Last) = '/')
      then
         return R;
      end if;
      return R & "/";
   end Canonical;

   --  Print the list, one entry per line.
   procedure Show (List : String) is
      P0 : Natural := List'First;
   begin
      if List'Length = 0 then
         Akernel_User.Console.Put_Line
           ("(default search: current dir, volume root, C:)");
         return;
      end if;
      for I in List'Range loop
         if List (I) = ';' or else I = List'Last then
            declare
               Last : constant Natural :=
                 (if List (I) = ';' then I - 1 else I);
            begin
               if Last >= P0 then
                  Akernel_User.Console.Put_Line (List (P0 .. Last));
               end if;
            end;
            P0 := I + 1;
         end if;
      end loop;
   end Show;

   St : CLI.U64;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Files.Bind (2);

   --  The list read must follow the fs bind (Get_Env is an fs
   --  call — the milestone-42 elaboration burn).
   declare
      List : constant String := CLI.Get_Env ("Path");
   begin
      if CLI.Arg_Count = 0 then
         Show (List);
         CLI.Exit_With (CLI.RC_Ok);
      end if;

      if CLI.Arg_Count = 1
        and then Same (CLI.Argument (1), "RESET")
      then
         St := Files.Delete ("ENV:Path");
         if St /= Files.Status_Ok
           and then St /= Files.Status_Not_Found
         then
            CLI.Fail_With ("Path: can't reset", CLI.RC_Error);
         end if;
         CLI.Exit_With (CLI.RC_Ok);
      end if;

      if CLI.Arg_Count /= 2 then
         CLI.Fail_With
           ("usage: Path [<dir> ADD | <dir> REMOVE | RESET]",
            CLI.RC_Error);
      end if;

      declare
         E_Name    : constant String := Canonical (CLI.Argument (1));
         New_List : String (1 .. Max_List + 1);
         NLen     : Natural := 0;
         Found    : Boolean := False;

         --  Rebuild the list without the target entry (ADD and
         --  REMOVE share the walk; ADD re-appends below).
         procedure Rebuild is
            P0 : Natural := List'First;
         begin
            if List'Length = 0 then
               return;
            end if;
            for I in List'Range loop
               if List (I) = ';' or else I = List'Last then
                  declare
                     Last : constant Natural :=
                       (if List (I) = ';' then I - 1 else I);
                  begin
                     if Last >= P0 then
                        if Same (List (P0 .. Last), E_Name) then
                           Found := True;  --  dropped
                        else
                           if NLen > 0 then
                              NLen := NLen + 1;
                              New_List (NLen) := ';';
                           end if;
                           for C of List (P0 .. Last) loop
                              NLen := NLen + 1;
                              New_List (NLen) := C;
                           end loop;
                        end if;
                     end if;
                  end;
                  P0 := I + 1;
               end if;
            end loop;
         end Rebuild;
      begin
         if Same (CLI.Argument (2), "ADD") then
            Rebuild;
            if Found then
               Akernel_User.Console.Put_Line
                 (E_Name & " is already in the path");
               CLI.Exit_With (CLI.RC_Warn);
            end if;
            if NLen + E_Name'Length + 1 > Max_List then
               CLI.Fail_With ("Path: list full", CLI.RC_Error);
            end if;
            if NLen > 0 then
               NLen := NLen + 1;
               New_List (NLen) := ';';
            end if;
            for C of E_Name loop
               NLen := NLen + 1;
               New_List (NLen) := C;
            end loop;
         elsif Same (CLI.Argument (2), "REMOVE") then
            Rebuild;
            if not Found then
               Akernel_User.Console.Put_Line
                 (E_Name & " is not in the path");
               CLI.Exit_With (CLI.RC_Warn);
            end if;
         else
            CLI.Fail_With
              ("usage: Path [<dir> ADD | <dir> REMOVE | RESET]",
               CLI.RC_Error);
         end if;

         St := CLI.Set_Env ("Path", New_List (1 .. NLen));
         if St /= Files.Status_Ok then
            CLI.Fail_With ("Path: can't write ENV:Path",
                           CLI.RC_Error);
         end if;
      end;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Path;
