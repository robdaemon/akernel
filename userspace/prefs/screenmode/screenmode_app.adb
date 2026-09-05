with Akernel_User.CLI;
with Akernel_User.Syscalls;
with Akernel_User.Window;
with Trinket.Fonts;
with Trinket.Listview;
with Trinket.Widgets;
with Trinket.Widgets.Button;
with Trinket.Window;

package body Screenmode_App is
   use Akernel_User.Syscalls;
   use type Akernel_User.Syscalls.U64;
   package Widgets renames Trinket.Widgets;
   package LV renames Trinket.Listview;
   package CLI renames Akernel_User.CLI;
   package Win renames Akernel_User.Window;

   Bureau_EP : constant U64 := 3;  --  uniform ABI handle

   Win_H : Trinket.Window.Window;

   --  Static mode list (the driver's clamp is 640x480 ..
   --  1920x1080). Modes must be page-clean: W * H * 4 a multiple
   --  of 4096 — every entry here qualifies.
   type Mode_Rec is record
      W, H : Natural;
   end record;
   Modes : constant array (Positive range <>) of Mode_Rec :=
     ((640, 480), (800, 600), (1024, 768), (1280, 720),
      (1280, 800), (1280, 1024), (1600, 900), (1920, 1080));

   Cur_W : U64 := 0;   --  mode in effect, from the query
   Cur_H : U64 := 0;
   Sel   : Natural := 0;   --  1-based Modes row, 0 = none

   Mode_Lv : LV.Any_Listview;

   function Mode_Label (M : Mode_Rec) return String is
      WI : constant String := Natural'Image (M.W);
      HI : constant String := Natural'Image (M.H);
   begin
      --  Natural'Image carries a leading space; strip it.
      return WI (WI'First + 1 .. WI'Last) & " x "
        & HI (HI'First + 1 .. HI'Last);
   end Mode_Label;

   procedure Mode_Picked (Index : Natural) is
   begin
      Sel := Index;
   end Mode_Picked;

   procedure Okay_Clicked is
      Now_W, Now_H : U64;
      St : U64;
   begin
      if Sel = 0 then
         Trinket.Window.Request_Quit (Win_H);
         return;
      end if;
      St := Win.Set_Screen_Mode
        (Bureau_EP, U64 (Modes (Sel).W), U64 (Modes (Sel).H),
         Now_W, Now_H);
      if St /= Win.Status_Ok then
         Debug_Put_Line
           ("prefs/screenmode: set mode" & Natural'Image (Modes (Sel).W)
            & " x" & Natural'Image (Modes (Sel).H)
            & " rejected:" & U64'Image (St));
         return;  --  stay open so the rejection is visible
      end if;
      declare
         SW : constant String := Natural'Image (Natural (Now_W));
         SH : constant String := Natural'Image (Natural (Now_H));
         S1 : U64;
         S2 : U64;
      begin
         S1 := CLI.Set_Env
           ("Screen.Width", SW (SW'First + 1 .. SW'Last));
         S2 := CLI.Set_Env
           ("Screen.Height", SH (SH'First + 1 .. SH'Last));
         if S1 /= 0 or else S2 /= 0 then
            Debug_Put_Line ("prefs/screenmode: env save failed");
         end if;
      end;
      Debug_Put_Line
        ("prefs/screenmode: mode" & Natural'Image (Natural (Now_W))
         & " x" & Natural'Image (Natural (Now_H)) & " saved");
      Trinket.Window.Request_Quit (Win_H);
   end Okay_Clicked;

   procedure Cancel_Clicked is
   begin
      Trinket.Window.Request_Quit (Win_H);
   end Cancel_Clicked;

   procedure Main is
      Root    : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical);
      Btn_Row : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
      St      : U64;
   begin
      Trinket.Fonts.Init;
      St := Win.Set_Screen_Mode (Bureau_EP, 0, 0, Cur_W, Cur_H);
      if St /= Win.Status_Ok then
         Debug_Put_Line ("prefs/screenmode: mode query failed");
         return;
      end if;

      Mode_Lv := LV.New_Listview (Mode_Picked'Access);
      for I in Modes'Range loop
         LV.Add_Item (Mode_Lv.all, Mode_Label (Modes (I)));
         if U64 (Modes (I).W) = Cur_W and then U64 (Modes (I).H) = Cur_H
         then
            Sel := I;
         end if;
      end loop;

      Widgets.Group (Root.all).Add (Widgets.Any_Widget (Mode_Lv), 1);
      Widgets.Group (Btn_Row.all).Add
        (Widgets.Button.New_Button ("Okay", Okay_Clicked'Access));
      Widgets.Group (Btn_Row.all).Add
        (Widgets.Button.New_Button ("Cancel", Cancel_Clicked'Access));
      Widgets.Group (Root.all).Add (Btn_Row, 0);

      if Trinket.Window.Open (Win_H, 3, 200, 190, "ScreenMode", Root) then
         --  Preselect AFTER layout: Set_Selected scrolls to make
         --  the row visible, and a zero-height listview (pre-open)
         --  parks Top at row 1 (the M89 font-picker burn).
         if Sel /= 0 then
            LV.Set_Selected (Mode_Lv.all, Sel);
         end if;
         Debug_Put_Line ("prefs/screenmode online");
         Trinket.Window.Run (Win_H);
         Trinket.Window.Close (Win_H);
      else
         Debug_Put_Line ("prefs/screenmode: window open failed");
      end if;
   end Main;

end Screenmode_App;
