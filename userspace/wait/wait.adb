with Ada.Calendar;
with Akernel_User.CLI;
with Akernel_User.Console;

--  Wait: pause the shell (milestone 59; the Amiga C:Wait analog).
--  "Wait" or "Wait N"      — N seconds (default 1)
--  "Wait M:S"              — M minutes, S seconds
--  "Wait UNTIL HH:MM[:SS]" — wall-clock time (tomorrow when the
--                            time has already passed today)
--  Sleeps ride the vendored nanosleep (rdtime + yield); UNTIL
--  polls the RTC half-secondly via Ada.Calendar.

procedure Wait is
   package CLI renames Akernel_User.CLI;
   package Cal renames Ada.Calendar;

   --  Parse "N" or "N:M[:S]" into total seconds. Ok False on
   --  any non-digit, empty field, or more than two colons.
   function Parse_Clock (S : String; Total : out Natural)
                         return Boolean is
      Fields : array (1 .. 3) of Natural := (others => 0);
      NF     : Natural := 0;
      NDig : Natural := 0;
   begin
      for C of S loop
         if C = ':' then
            if NDig = 0 or else NF = 3 then
               return False;
            end if;
            NF := NF + 1;
            NDig := 0;
         elsif C in '0' .. '9' then
            if NF = 3 then
               return False;
            end if;
            Fields (NF + 1) := Fields (NF + 1) * 10
              + (Character'Pos (C) - Character'Pos ('0'));
            NDig := NDig + 1;
         else
            return False;
         end if;
      end loop;
      if NDig = 0 then
         return False;
      end if;
      NF := NF + 1;
      case NF is
         when 1 => Total := Fields (1);
         when 2 => Total := Fields (1) * 60 + Fields (2);
         when 3 => Total := Fields (1) * 3_600 + Fields (2) * 60
                            + Fields (3);
         when others => return False;
      end case;
      return True;
   end Parse_Clock;

   --  Keyword match, case-insensitive (Amiga keywords fold).
   function Same (A, B : String) return Boolean is
      function Up (C : Character) return Character is
        (if C in 'a' .. 'z'
         then Character'Val (Character'Pos (C) - 32) else C);
   begin
      return A'Length = B'Length
        and then (for all I in A'Range =>
                    Up (A (I)) = Up (B (I - B'First + A'First)));
   end Same;
begin
   CLI.Init;

   if CLI.Arg_Count = 0 then
      delay 1.0;
      CLI.Exit_With (CLI.RC_Ok);
   end if;

   if CLI.Arg_Count = 1
     and then Same (CLI.Argument (1), "UNTIL")
   then
      Akernel_User.Console.Put_Line ("Wait: UNTIL what? (HH:MM)");
      CLI.Exit_With (CLI.RC_Error);
   end if;

   if Same (CLI.Argument (1), "UNTIL") then
      declare
         Target : Natural;
      begin
         if CLI.Arg_Count /= 2
           or else not Parse_Clock (CLI.Argument (2), Target)
           or else Target >= 86_400
         then
            CLI.Fail_With ("usage: Wait [N | M:S | UNTIL HH:MM[:SS]]",
                           CLI.RC_Error);
         end if;
         --  Poll half-secondly; the RTC ticks at second
         --  resolution. A target already passed today is
         --  tomorrow's (Amiga semantics): wait for the day
         --  to roll over first.
         declare
            T0 : constant Cal.Time := Cal.Clock;
            Y0 : Cal.Year_Number;
            M0 : Cal.Month_Number;
            D0 : Cal.Day_Number;
            S0 : Cal.Day_Duration;
         begin
            Cal.Split (T0, Y0, M0, D0, S0);
            declare
               Passed : constant Boolean :=
                 Natural (S0) >= Target;
               Y1 : Cal.Year_Number;
               M1 : Cal.Month_Number;
               D1 : Cal.Day_Number;
               S1 : Cal.Day_Duration;
            begin
               loop
                  declare
                     Now : constant Cal.Time := Cal.Clock;
                  begin
                     Cal.Split (Now, Y1, M1, D1, S1);
                     exit when Natural (S1) >= Target
                       and then (not Passed
                                 or else Y1 /= Y0
                                 or else M1 /= M0
                                 or else D1 /= D0);
                  end;
                  delay 0.5;
               end loop;
            end;
         end;
      end;
      CLI.Exit_With (CLI.RC_Ok);
   end if;

   declare
      Total : Natural;
   begin
      if CLI.Arg_Count /= 1
        or else not Parse_Clock (CLI.Argument (1), Total)
      then
         CLI.Fail_With ("usage: Wait [N | M:S | UNTIL HH:MM[:SS]]",
                        CLI.RC_Error);
      end if;
      delay Duration (Total);
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Wait;
