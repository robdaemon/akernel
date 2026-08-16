with Ada.Calendar;
with Ada.Calendar.Formatting;
with Akernel_User.CLI;
with Akernel_User.Console;

--  Date: print the wall clock (milestone 59; the Amiga C:Date
--  analog, read-only — the goldfish RTC cannot be set, so the
--  Amiga set form is rejected). Output is the Amiga style:
--  "Sat 15-Aug-2026 19:12:33" (4-digit year — 2026, not 26).

procedure Date is
   package CLI renames Akernel_User.CLI;
   package Cal renames Ada.Calendar;
   package CalF renames Ada.Calendar.Formatting;

   Months : constant array (1 .. 12) of String (1 .. 3) :=
     ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec");
   Days   : constant array (CalF.Day_Name) of String (1 .. 3) :=
     ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun");

   function Two (N : Natural) return String is
     (Character'Val (Character'Pos ('0') + N / 10)
      & Character'Val (Character'Pos ('0') + N mod 10));

   function Four (N : Natural) return String is
     (Two (N / 100) & Two (N mod 100));
begin
   CLI.Init;

   if CLI.Arg_Count /= 0 then
      Akernel_User.Console.Put_Line
        ("Date: the RTC is read-only; cannot set the clock");
      CLI.Exit_With (CLI.RC_Error);
   end if;

   declare
      Now   : constant Cal.Time := Cal.Clock;
      Year  : Cal.Year_Number;
      Month : Cal.Month_Number;
      Day   : Cal.Day_Number;
      Secs  : Cal.Day_Duration;
      H, M, S : Natural;
   begin
      Cal.Split (Now, Year, Month, Day, Secs);
      H := Natural (Secs) / 3_600;
      M := (Natural (Secs) / 60) mod 60;
      S := Natural (Secs) mod 60;
      Akernel_User.Console.Put_Line
        (Days (CalF.Day_Of_Week (Now)) & " "
         & Two (Day) & "-" & Months (Month) & "-" & Four (Year)
         & " " & Two (H) & ":" & Two (M) & ":" & Two (S));
   end;

   CLI.Exit_With (CLI.RC_Ok);
end Date;
