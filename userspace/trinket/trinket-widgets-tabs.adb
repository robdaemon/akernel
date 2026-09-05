with Trinket.Paint;
with Trinket.Fonts;
with Akernel_User.Theme;

package body Trinket.Widgets.Tabs is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Tabs_Access is access Tabs;

   --  Tabs (M87e)

   function Strip_H return U64 is (Fonts.Line_Height + 8);

   Tab_Gap : constant U64 := 3;  --  breathing room between tabs

   function Tab_W (W : Tabs; I : Positive) return U64 is
     (Fonts.Text_Width (W.Labels (I).Buf (1 .. W.Labels (I).Len))
      + 16);

   --  Left edge of tab I (from X + 2, Tab_Gap between tabs).
   function Tab_X0 (W : Tabs; I : Positive) return U64 is
      X : U64 := W.X + 2;
   begin
      for J in 1 .. I - 1 loop
         X := X + Tab_W (W, J) + Tab_Gap;
      end loop;
      return X;
   end Tab_X0;

   --  Tab under PX, 0 when in a gap or past the last one.
   function Tab_At (W : Tabs; PX : U64) return Natural is
      X : U64 := W.X + 2;
   begin
      for I in 1 .. W.N loop
         if PX >= X and then PX < X + Tab_W (W, I) then
            return I;
         end if;
         X := X + Tab_W (W, I) + Tab_Gap;
      end loop;
      return 0;
   end Tab_At;

   function New_Tabs
     (On_Change : Tab_Callback := null) return Any_Widget
   is
      T : constant Tabs_Access := new Tabs;
   begin
      T.On_Change := On_Change;
      return Any_Widget (T);
   end New_Tabs;

   procedure Add_Tab
     (W : in out Tabs; Label : String; Page : Any_Widget) is
   begin
      if W.N < Max_Children then
         Add (Group (W), Page);  --  Group.Add: the page is kid N
         Set_Text (W.Labels (W.N).Buf, W.Labels (W.N).Len, Label);
         if W.Sel = 0 then
            W.Sel := 1;
         end if;
         W.Dirty := True;
      end if;
   end Add_Tab;

   procedure Set_Selected (W : in out Tabs; I : Natural) is
   begin
      if I >= 1 and then I <= W.N and then I /= W.Sel then
         W.Sel := I;
         Layout (W);       --  the new page needs its rect NOW
         W.Dirty := True;  --  full strip + page repaint
         if W.On_Change /= null then
            W.On_Change (I);
         end if;
      end if;
   end Set_Selected;

   function Selected (W : Tabs) return Natural is (W.Sel);

   procedure Layout (W : in out Tabs) is
      PY : constant U64 := W.Y + Strip_H;
   begin
      for I in 1 .. W.N loop
         if I = W.Sel then
            W.Kids (I).X := W.X + 2;
            W.Kids (I).Y := PY + 2;
            W.Kids (I).W := (if W.W > 4 then W.W - 4 else 0);
            W.Kids (I).H :=
              (if W.H > Strip_H + 2 then W.H - Strip_H - 2 else 0);
            W.Kids (I).Layout;
         else
            --  Hidden page: no rect, no damage, no events.
            W.Kids (I).X := 0;
            W.Kids (I).Y := 0;
            W.Kids (I).W := 0;
            W.Kids (I).H := 0;
            W.Kids (I).Dirty := False;
         end if;
      end loop;
   end Layout;

   procedure Min_Size (W : Tabs; MW, MH : out U64) is
      KW, KH : U64;
      PW : U64 := 0;   --  widest page
      PH : U64 := 0;   --  tallest page
      TW : U64 := 2;   --  whole strip (starts at X + 2)
   begin
      for I in 1 .. W.N loop
         W.Kids (I).Min_Size (KW, KH);
         PW := Max (PW, KW);
         PH := Max (PH, KH);
         TW := TW + Tab_W (W, I)
           + (if I < W.N then Tab_Gap else 0);
      end loop;
      MW := Max (PW + 4, TW + 2);
      MH := Strip_H + PH + 4;
   end Min_Size;

   --  Rounded-top tab (M87e restyle): 2px-chamfered top corners,
   --  NO bottom edge of its own — the page frame's top line is
   --  the shared boundary; the active tab runs 2px lower, its
   --  Face fill covering the frame bevel in its span (merged).
   procedure Draw_Tab
     (W : Tabs; C : Canvas; I : Positive; Active : Boolean)
   is
      TX  : constant U64 := Tab_X0 (W, I);
      TW  : constant U64 := Tab_W (W, I);
      X1  : constant U64 := TX + TW;
      Bot : constant U64 :=
        W.Y + Strip_H + (if Active then 2 else 0);
      F   : constant Pixel :=
        (if Active then Face
         elsif I = W.Hover_Tab and then I /= W.Press_Tab
         then Akernel_User.Theme.Face_Hi
         else Win_Face);
      LW  : constant U64 :=
        Fonts.Text_Width (W.Labels (I).Buf (1 .. W.Labels (I).Len));
      Shift : constant U64 := (if I = W.Press_Tab then 1 else 0);
   begin
      --  Outline (black): chamfered top, verticals to Bot.
      Paint.Fill_Rect (C, TX + 2, W.Y, X1 - 2, W.Y + 1, Border);
      Paint.Fill_Rect (C, TX + 1, W.Y + 1, TX + 2, W.Y + 2, Border);
      Paint.Fill_Rect (C, X1 - 2, W.Y + 1, X1 - 1, W.Y + 2, Border);
      Paint.Fill_Rect (C, TX, W.Y + 2, TX + 1, Bot, Border);
      Paint.Fill_Rect (C, X1 - 1, W.Y + 2, X1, Bot, Border);
      --  Face fill (the Y+1 row is the white inner top edge).
      Paint.Fill_Rect (C, TX + 2, W.Y + 1, X1 - 2, W.Y + 2,
                       Bevel_Hi);
      Paint.Fill_Rect (C, TX + 1, W.Y + 2, X1 - 1, Bot, F);
      --  3D: white inner left, dark inner right.
      Paint.Fill_Rect (C, TX + 1, W.Y + 2, TX + 2, Bot, Bevel_Hi);
      Paint.Fill_Rect (C, X1 - 2, W.Y + 2, X1 - 1, Bot, Bevel_Lo);
      --  Label, centered; shifts one pixel while held.
      Fonts.Draw_Text
        (C, TX + (if TW > LW then (TW - LW) / 2 else 1) + Shift,
         W.Y + 4 + Shift,
         W.Labels (I).Buf (1 .. W.Labels (I).Len), Text_Dark);
   end Draw_Tab;

   procedure Draw (W : Tabs; C : Canvas) is
      PY : constant U64 := W.Y + Strip_H;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      --  Page: Face interior + raised frame whose top line is
      --  the strip's shared bottom boundary.
      Paint.Fill_Rect (C, W.X, PY, W.X + W.W, W.Y + W.H, Face);
      Paint.Bevel2 (C, W.X, PY, W.X + W.W, W.Y + W.H);
      --  Inactive tabs first; the active one LAST so its fill
      --  overdraws the frame's top bevel (merged into the page).
      for I in 1 .. W.N loop
         if I /= W.Sel then
            Draw_Tab (W, C, I, False);
         end if;
      end loop;
      if W.Sel >= 1 and then W.Sel <= W.N then
         Draw_Tab (W, C, W.Sel, True);
         W.Kids (W.Sel).Draw (C);
      end if;
      if W.Focused then
         --  M87h: ring hugs the strip, not the page frame.
         Paint.Focus_Ring (C, W.X + 2, W.Y + 2,
                           W.X + W.W - 2, W.Y + Strip_H - 2,
                           Text_Dark);
      end if;
   end Draw;

   function On_Pointer
     (W : access Tabs; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
      In_Strip : constant Boolean :=
        PX >= W.X and then PX < W.X + W.W
        and then PY >= W.Y and then PY < W.Y + Strip_H;
      Hov : Natural;
      Has_Page : constant Boolean := W.Sel >= 1 and then W.Sel <= W.N;
   begin
      if K = Move then
         --  M86c hover tracks the tab under the pointer (0 over
         --  the page or outside).
         Hov := (if In_Strip then Tab_At (W.all, PX) else 0);
         if Hov /= W.Hover_Tab then
            W.Hover_Tab := Hov;
            W.Dirty := True;
         end if;
         --  A page child mid-drag still gets its moves.
         if Has_Page
           and then W.Kids (W.Sel).On_Pointer (K, PX, PY)
         then
            return True;
         end if;
         return In_Strip;
      elsif K = Press then
         if In_Strip then
            W.Press_Tab := Tab_At (W.all, PX);
            W.Focused := True;   --  M87h: click takes focus
            W.Dirty := True;
            return True;  --  dead strip pixels included
         end if;
         return Has_Page
           and then Inside (W.Kids (W.Sel).all, PX, PY)
           and then W.Kids (W.Sel).On_Pointer (K, PX, PY);
      else  --  Release: a held tab commits only on release-over
         if W.Press_Tab /= 0 then
            if In_Strip and then Tab_At (W.all, PX) = W.Press_Tab
            then
               Set_Selected (W.all, W.Press_Tab);
            end if;
            W.Press_Tab := 0;
            W.Dirty := True;
            return True;
         end if;
         --  Release must reach a pressed page child even when
         --  the pointer has slid off it (Group semantics).
         return Has_Page
           and then W.Kids (W.Sel).On_Pointer (K, PX, PY);
      end if;
   end On_Pointer;

   function Wants_Focus (W : Tabs) return Boolean is
      pragma Unreferenced (W);
   begin
      return True;
   end Wants_Focus;

   function On_Key (W : access Tabs; Code : U64) return Boolean is
   begin
      --  M87h: a focused strip's Left/Right switch pages (wrap);
      --  everything else goes to the active page as before.
      if W.Focused and then W.N > 0 and then W.Sel >= 1 then
         if Code = Key_Left then
            Set_Selected
              (W.all, (if W.Sel = 1 then W.N else W.Sel - 1));
            return True;
         elsif Code = Key_Right then
            Set_Selected
              (W.all, (if W.Sel = W.N then 1 else W.Sel + 1));
            return True;
         end if;
      end if;
      return W.Sel >= 1 and then W.Sel <= W.N
        and then W.Kids (W.Sel).On_Key (Code);
   end On_Key;

   procedure Dirty_List
      (W        : Tabs;
       Rects    : in out Rect_Array;
       N        : in out Natural;
       Overflow : in out Boolean) is
   begin
      if W.Dirty then
         Add_Rect (Rects, N, Overflow, W.X, W.Y, W.X + W.W,
                   W.Y + W.H);
         return;
      end if;
      --  Only the active page can contribute bands; hidden
      --  pages' stale flags would union as zero rects.
      if W.Sel >= 1 and then W.Sel <= W.N then
         W.Kids (W.Sel).Dirty_List (Rects, N, Overflow);
      end if;
   end Dirty_List;

end Trinket.Widgets.Tabs;
