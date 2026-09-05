with Trinket.Paint;
with Trinket.Widgets.Scrollbar;
with Trinket.Fonts;
with Akernel_User.Syscalls;
with Akernel_User.Theme;

package body Trinket.Iconview is

   use type Trinket.U64;
   use Trinket.Widgets;

   function Max (A, B : U64) return U64 is (if A > B then A else B);

   type Iconview_Access is access Iconview;

   procedure Set_Text
     (Buf : out Label_String; Len : out Natural; S : String)
   is
      N : constant Natural := Natural'Min (S'Length, Buf'Length);
   begin
      Len := N;
      if N > 0 then
         Buf (1 .. N) := S (S'First .. S'First + N - 1);
      end if;
   end Set_Text;

   function New_Iconview
     (On_Change : Selected_Callback := null) return Any_Iconview
   is
      L : constant Iconview_Access := new Iconview;
   begin
      L.On_Change := On_Change;
      return Any_Iconview (L);
   end New_Iconview;

   procedure Set_On_Double_Click
     (W : in out Iconview; Cb : Selected_Callback) is
   begin
      W.On_Double_Click := Cb;
   end Set_On_Double_Click;

   procedure Clear (W : in out Iconview) is
   begin
      W.N := 0;
      W.Sel := 0;
      W.Top := 0;
      W.Last_Press_Cell := 0;
      W.Dirty := True;
   end Clear;

   procedure Add_Item
     (W     : in out Iconview;
      Label : String;
      Icon  : access constant Trinket.Images.Image)
   is
   begin
      if W.N < Max_Items then
         W.N := W.N + 1;
         Set_Text (W.Items (W.N).Text, W.Items (W.N).Len, Label);
         W.Items (W.N).Icon := Icon;
         W.Dirty := True;
      end if;
   end Add_Item;

   function Item_Count (W : Iconview) return Natural is (W.N);

   function Get_Label (W : Iconview; I : Positive) return String is
   begin
      if I > W.N then
         return "";
      end if;
      return W.Items (I).Text (1 .. W.Items (I).Len);
   end Get_Label;

   --  The grid geometry is ALWAYS derived from the current
   --  widget width — a resize reflows every consumer (draw,
   --  hit-test, scrollbar range) with no stored state to sync.
   function Columns (W : Iconview) return U64 is
   begin
      if W.W < Cell_W then
         return 1;
      end if;
      return W.W / Cell_W;
   end Columns;

   function Rows (W : Iconview) return U64 is
      C : constant U64 := Columns (W);
   begin
      if W.N = 0 then
         return 0;
      end if;
      return (U64 (W.N) + C - 1) / C;
   end Rows;

   function Content_Height (W : Iconview) return U64 is
     (Rows (W) * Cell_H);

   function Max_Top (W : Iconview) return U64 is
      CH : constant U64 := Content_Height (W);
   begin
      if CH > W.H then
         return CH - W.H;
      end if;
      return 0;
   end Max_Top;

   procedure Clamp_Top (W : in out Iconview) is
      M : constant U64 := Max_Top (W);
   begin
      if W.Top > M then
         W.Top := M;
      end if;
   end Clamp_Top;

   procedure Fire_On_Change (W : in out Iconview) is
   begin
      if W.On_Change /= null then
         W.On_Change (W.Sel);
      end if;
   end Fire_On_Change;

   procedure Set_Selected (W : in out Iconview; I : Natural) is
   begin
      if W.N = 0 then
         if W.Sel /= 0 then
            W.Sel := 0;
            W.Dirty := True;
            Fire_On_Change (W);
         end if;
         return;
      end if;

      declare
         New_Sel : constant Natural := Natural'Min (I, W.N);
      begin
         if New_Sel /= W.Sel then
            W.Sel := New_Sel;
            W.Dirty := True;

            --  Keep the selected cell visible (pixel scroll).
            if W.Sel > 0 then
               declare
                  Row : constant U64 :=
                    U64 (W.Sel - 1) / Columns (W);
               begin
                  if Row * Cell_H < W.Top then
                     W.Top := Row * Cell_H;
                  elsif (Row + 1) * Cell_H > W.Top + W.H then
                     W.Top := (Row + 1) * Cell_H - W.H;
                  end if;
               end;
            end if;
            Clamp_Top (W);
            Fire_On_Change (W);
         end if;
      end;
   end Set_Selected;

   function Selected (W : Iconview) return Natural is (W.Sel);

   procedure Set_Top (W : in out Iconview; T : U64) is
      M : constant U64 := Max_Top (W);
      N : constant U64 := U64'Min (T, M);
   begin
      if N /= W.Top then
         W.Top := N;
         W.Dirty := True;
      end if;
   end Set_Top;

   function Top (W : Iconview) return U64 is (W.Top);

   overriding procedure Draw (W : Iconview; C : Canvas) is
      C2  : Canvas := C;
      Cols : constant U64 := Columns (W);
   begin
      Set_Clip (C2, W.X, W.Y, W.X + W.W, W.Y + W.H);
      if C2.CX1 <= C2.CX0 or else C2.CY1 <= C2.CY0 then
         return;
      end if;

      Paint.Fill_Rect (C2, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);

      for I in 1 .. W.N loop
         declare
            Row  : constant U64 := U64 (I - 1) / Cols;
            Col  : constant U64 := U64 (I - 1) mod Cols;
            CX   : constant U64 := W.X + Col * Cell_W;
            CY   : constant U64 := W.Y + Row * Cell_H - W.Top;
            Item : Item_Rec renames W.Items (I);
            --  Label truncates to what fits the cell.
            Max_Ch : constant Natural := Natural ((Cell_W - 8) / 8);
            Shown  : constant Natural := Natural'Min (Item.Len, Max_Ch);
            TW     : constant U64 :=
              Fonts.Text_Width (Item.Text (1 .. Shown));
         begin
            if CY + Cell_H >= W.Y and then CY < W.Y + W.H then
               if I = W.Sel then
                  Paint.Fill_Rect
                    (C2, CX + 2, CY + 2,
                     CX + Cell_W - 2, CY + Cell_H - 2, Sel_Blue);
               end if;
               if Item.Icon /= null then
                  Trinket.Images.Blit
                    (C2, Item.Icon.all,
                     CX + (Cell_W - Icon_Px) / 2, CY + 4);
               end if;
               if Shown > 0 then
                  Fonts.Draw_Text
                    (C2,
                     CX + (if TW >= Cell_W then 4
                           else (Cell_W - TW) / 2),
                     CY + 6 + Icon_Px,
                     Item.Text (1 .. Shown),
                     (if I = W.Sel then Akernel_User.Theme.Title_Text
                      else Text_Dark));
               end if;
            end if;
         end;
      end loop;
   end Draw;

   overriding procedure Min_Size (W : Iconview; MW, MH : out U64) is
      pragma Unreferenced (W);
   begin
      MW := Cell_W;
      MH := Cell_H;
   end Min_Size;

   overriding function On_Key
     (W : access Iconview; Code : U64) return Boolean
   is
      Cols : constant Natural := Natural (Columns (W.all));
   begin
      if W.N = 0 then
         return False;
      end if;

      if Code = Key_Left then
         if W.Sel > 1 then
            Set_Selected (W.all, W.Sel - 1);
         end if;
         return True;
      elsif Code = Key_Right then
         if W.Sel < W.N then
            Set_Selected (W.all, W.Sel + 1);
         end if;
         return True;
      elsif Code = Key_Up then
         if W.Sel > Cols then
            Set_Selected (W.all, W.Sel - Cols);
         end if;
         return True;
      elsif Code = Key_Down then
         if W.Sel + Cols <= W.N then
            Set_Selected (W.all, W.Sel + Cols);
         end if;
         return True;
      elsif Code = Key_Home then
         Set_Selected (W.all, 1);
         return True;
      elsif Code = Key_End then
         Set_Selected (W.all, W.N);
         return True;
      end if;

      return False;
   end On_Key;

   --  Cell index under a pane-relative point (0 = outside any
   --  live cell).
   function Cell_At (W : Iconview; PX, PY : U64) return Natural is
      Cols : constant U64 := Columns (W);
      Col  : constant U64 := PX / Cell_W;
      Row  : constant U64 := (PY + W.Top) / Cell_H;
      Idx  : constant U64 := Row * Cols + Col + 1;
   begin
      if Col >= Cols or else Idx > U64 (W.N) then
         return 0;
      end if;
      return Natural (Idx);
   end Cell_At;

   overriding function On_Pointer
     (W : access Iconview; K : Widgets.Pointer_Kind; PX, PY : U64)
      return Boolean
   is
      Idx : Natural;
   begin
      if K /= Press then
         return False;
      end if;
      if not Inside (W.all, PX, PY) then
         return False;
      end if;
      if W.N = 0 then
         return True;
      end if;

      Idx := Cell_At (W.all, PX - W.X, PY - W.Y);
      if Idx > 0 then
         --  Same cell again within the threshold = double click
         --  (Listview's M84c pattern). Selection first, callback
         --  after.
         declare
            Now    : constant U64 := Akernel_User.Syscalls.Read_Time;
            Double : constant Boolean :=
              Idx = W.Last_Press_Cell
              and then Now - W.Last_Press_Time < Double_Click_Ticks;
         begin
            W.Last_Press_Cell := Idx;
            W.Last_Press_Time := Now;
            Set_Selected (W.all, Idx);
            if Double and then W.On_Double_Click /= null then
               W.On_Double_Click (Idx);
            end if;
         end;
      else
         W.Last_Press_Cell := 0;
         Set_Selected (W.all, 0);
      end if;
      return True;
   end On_Pointer;

   --  Scrolled composite: icons + flush v-bar, self-wired.

   --  One handler serves every instance: the bar's Ctx is the
   --  iconview.
   procedure Bar_Moved (Bar : Widgets.Any_Widget; Pos : U64) is
      L : constant Any_Iconview :=
        Any_Iconview (Widgets.Scrollbar.Scrollbar (Bar.all).Ctx);
   begin
      Set_Top (L.all, Pos);
   end Bar_Moved;

   procedure Layout (W : in out Scrolled_Icons) is
      A  : constant U64 := Widgets.Arrow;
      CW : constant U64 := (if W.W > A then W.W - A else 0);
   begin
      W.IV.X := W.X;
      W.IV.Y := W.Y;
      W.IV.W := CW;
      W.IV.H := W.H;
      W.VBar.X := W.X + CW;
      W.VBar.Y := W.Y;
      W.VBar.W := A;
      W.VBar.H := W.H;
      for I in 1 .. Group (W).N loop
         Group (W).Kids (I).Layout;
      end loop;
   end Layout;

   procedure Min_Size (W : Scrolled_Icons; MW, MH : out U64) is
      A  : constant U64 := Widgets.Arrow;
      LW, LH2 : U64;
   begin
      W.IV.Min_Size (LW, LH2);
      MW := LW + A;
      MH := Max (LH2, 3 * A);  --  arrow pair + a knob
   end Min_Size;

   procedure Draw (W : Scrolled_Icons; C : Canvas) is
   begin
      --  Content -> bar. Scrollbar Set_Range/Set_Pos no-op when
      --  unchanged. Range/visible are pixels here.
      Widgets.Scrollbar.Set_Range
        (Widgets.Scrollbar.Scrollbar (W.VBar.all), 0,
         Max_Top (W.IV.all), W.IV.H);
      Widgets.Scrollbar.Set_Pos
        (Widgets.Scrollbar.Scrollbar (W.VBar.all), Top (W.IV.all));
      Group (W).Draw (C);
   end Draw;

   function New_Scrolled_Icons
     (IV        : out Any_Iconview;
      On_Change : Selected_Callback := null) return Widgets.Any_Widget
   is
      type SI_Access is access Scrolled_Icons;
      SI : constant SI_Access := new Scrolled_Icons;
   begin
      IV := New_Iconview (On_Change);
      SI.IV := IV;
      SI.VBar := Widgets.Scrollbar.New_Scrollbar
        (Bar_Moved'Access, Vertical, Widgets.Any_Widget (IV));
      --  The range is pixels: arrow clicks step a cell row, not
      --  a single pixel.
      Widgets.Scrollbar.Set_Step
        (Widgets.Scrollbar.Scrollbar (SI.VBar.all), Cell_H);
      Group (SI.all).Add (Widgets.Any_Widget (IV));
      Group (SI.all).Add (SI.VBar);
      return Widgets.Any_Widget (SI);
   end New_Scrolled_Icons;

end Trinket.Iconview;
