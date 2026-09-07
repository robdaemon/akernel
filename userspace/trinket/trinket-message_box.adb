with Trinket.Fonts;
with Trinket.Widgets;
with Trinket.Widgets.Button;
with Trinket.Widgets.Label;
with Trinket.Window;

package body Trinket.Message_Box is

   use type Trinket.U64;
   package Widgets renames Trinket.Widgets;

   --  Prompt wrapping bound: a Label cell holds 48 characters, so
   --  lines are cut at word breaks before 46 (an editor path like
   --  "BD0:System/.../file.txt" wraps across several lines).
   Max_Line_Chars : constant := 46;
   Max_Lines      : constant := 8;

   --  Per-request state (one dialog at a time, like the requester).
   Cb   : Choice_Callback := null;
   type Win_Acc is access all Trinket.Window.Window;
   Host : Win_Acc := null;

   --  Exit the dialog FIRST, then deliver: a handler that chains a
   --  successor Request (Save prompt -> next dirty doc) must find
   --  the current modal already exiting so Start_Modal_Overlay can
   --  queue it (one dialog at a time otherwise).
   procedure Finish (Choice : Natural) is
   begin
      if Host /= null then
         Trinket.Window.Request_Modal_Exit (Host.all);
         Host := null;
      end if;
      if Cb /= null then
         Cb (Choice);
      end if;
   end Finish;

   procedure B1_Click is
   begin
      Finish (1);
   end B1_Click;
   procedure B2_Click is
   begin
      Finish (2);
   end B2_Click;
   procedure B3_Click is
   begin
      Finish (3);
   end B3_Click;
   procedure B4_Click is
   begin
      Finish (4);
   end B4_Click;

   --  Add the prompt as wrapped Label lines to column Col; returns
   --  the line count (a too-long prompt is truncated at Max_Lines).
   procedure Add_Wrapped (Col : Widgets.Any_Widget; Prompt : String) is
      Line   : String (1 .. Max_Line_Chars);
      L      : Natural := 0;
      N      : Natural := 0;
      From   : Positive := Prompt'First;
   begin
      while From <= Prompt'Last and then N < Max_Lines loop
         L := 0;
         --  Take words up to the line bound.
         while From <= Prompt'Last and then L < Max_Line_Chars loop
            declare
               To : Natural := From;
            begin
               while To < Prompt'Last
                 and then Prompt (To + 1) /= ' '
               loop
                  To := To + 1;
               end loop;
               --  Word is From..To; a space follows (or line end).
               if L > 0 and then L + (To - From + 1) + 1 > Max_Line_Chars
               then
                  exit;   --  word does not fit: wrap before it
               end if;
               if L > 0 then
                  L := L + 1;
                  Line (L) := ' ';
               end if;
               for I in From .. To loop
                  L := L + 1;
                  Line (L) := Prompt (I);
               end loop;
               if To = Prompt'Last then
                  From := To + 1;
                  exit;
               end if;
               From := To + 2;   --  skip the space
            end;
         end loop;
         if L > 0 then
            N := N + 1;
            Widgets.Group (Col.all).Add
              (Widgets.Label.New_Label (Line (1 .. L)));
         end if;
      end loop;
   end Add_Wrapped;

   procedure Request
     (Win       : in out Trinket.Window.Window;
      Title     : String;
      Prompt    : String;
      Buttons   : String;
      On_Choice : Choice_Callback)
   is
      Root  : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical, Title => Title);
      Face  : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical, Inset => True);
      Col   : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical);
      RowB  : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
      LH    : constant Natural :=
        Natural (Trinket.Fonts.Line_Height);
      Lines : Natural := 0;
      DW    : constant U64 := 440;
      DH    : U64;
   begin
      if On_Choice = null then
         return;
      end if;
      Cb := On_Choice;
      Host := Win'Unrestricted_Access;

      Widgets.Group (Root.all).Add (Face);
      Widgets.Group (Face.all).Add (Col);

      --  Count wrapped lines for the dialog height (re-run the
      --  wrap into real labels at the same time).
      Add_Wrapped (Col, Prompt);
      Lines := Widgets.Group (Col.all).N;
      if Lines = 0 then
         Widgets.Group (Col.all).Add (Widgets.Label.New_Label (" "));
         Lines := 1;
      end if;

      --  Buttons: '|'-separated labels, 1 .. Max_Buttons, wired
      --  left to right. Add_Row of buttons via a dispatch.
      declare
         From : Natural := Buttons'First;
      begin
         for K in 1 .. Max_Buttons loop
            exit when From > Buttons'Last;
            declare
               To : Natural := From;
            begin
               while To < Buttons'Last and then Buttons (To + 1) /= '|'
               loop
                  To := To + 1;
               end loop;
               if K = 1 then
                  Widgets.Group (RowB.all).Add
                    (Widgets.Button.New_Button
                       (Buttons (From .. To), B1_Click'Access),
                     Weight => 1);
               elsif K = 2 then
                  Widgets.Group (RowB.all).Add
                    (Widgets.Button.New_Button
                       (Buttons (From .. To), B2_Click'Access),
                     Weight => 1);
               elsif K = 3 then
                  Widgets.Group (RowB.all).Add
                    (Widgets.Button.New_Button
                       (Buttons (From .. To), B3_Click'Access),
                     Weight => 1);
               else
                  Widgets.Group (RowB.all).Add
                    (Widgets.Button.New_Button
                       (Buttons (From .. To), B4_Click'Access),
                     Weight => 1);
               end if;
               From := To + 2;   --  skip the '|'
            end;
         end loop;
      end;
      Widgets.Group (Face.all).Add (RowB);

      --  Title + frame + insets + one label row per prompt line +
      --  the button row; generous so nothing clips.
      DH := U64 (3) * Trinket.U64 (LH) + 70
        + Trinket.U64 (Lines) * Trinket.U64 (LH);
      Trinket.Window.Start_Modal_Overlay (Win, Root, DW, DH);
   end Request;

end Trinket.Message_Box;
