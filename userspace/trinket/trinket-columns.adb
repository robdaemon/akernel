with Trinket.Paint;
with Trinket.Widgets.Scrollbar;
with Trinket.Fonts;
with Akernel_User.Syscalls;
with Akernel_User.Theme;

package body Trinket.Columns is

   use type Trinket.U64;
   use Trinket.Widgets;

   function Min (A, B : U64) return U64 is (if A < B then A else B);
   function Max (A, B : U64) return U64 is (if A > B then A else B);

   type Columns_Access is access Columns;

   LH : constant U64 := Trinket.Fonts.Line_Height;
   RH : constant U64 := LH + 2;    --  row pitch
   HH : constant U64 := LH + 2;    --  header band

   procedure Copy_Cell
     (Buf : out Cell; Len : out Natural; S : String) is
      N : constant Natural := Natural'Min (S'Length, Buf'Length);
   begin
      Len := N;
      if N > 0 then
         Buf (1 .. N) := S (S'First .. S'First + N - 1);
      end if;
   end Copy_Cell;

   function New_Columns
     (On_Change : Selected_Callback := null;
      On_Open   : Row_Callback := null) return Any_Columns
   is
      CW : constant Columns_Access := new Columns;
   begin
      CW.On_Change := On_Change;
      CW.On_Open := On_Open;
      return Any_Columns (CW);
   end New_Columns;

   procedure Clear (W : in out Columns) is
   begin
      W.N := 0;
      W.Sel := 0;
      W.Top := 0;
      W.Dirty := True;
   end Clear;

   procedure Add_Row
     (W : in out Columns; Name, Size, Date : String;
      Is_Dir : Boolean := False)
   is
   begin
      if W.N < Max_Rows then
         W.N := W.N + 1;
         Copy_Cell (W.Rows (W.N).Name, W.Rows (W.N).Name_Len, Name);
         Copy_Cell (W.Rows (W.N).Size, W.Rows (W.N).Size_Len, Size);
         Copy_Cell (W.Rows (W.N).Date, W.Rows (W.N).Date_Len, Date);
         W.Rows (W.N).Is_Dir := Is_Dir;
         W.Dirty := True;
      end if;
   end Add_Row;

   function Item_Count (W : Columns) return Natural is (W.N);

   --  Column x spans for the current width (name column flexes).
   procedure Column_Xs
     (W        : Columns;
      Date_X1  : out U64; Date_X0 : out U64;
      Size_X1  : out U64; Size_X0 : out U64;
      Name_X1  : out U64)
   is
      Right : constant U64 := W.X + W.W - 4;
   begin
      Date_X1 := Right;
      Date_X0 := Date_X1 - Min (Date_W, W.W);
      Size_X1 := Date_X0 - Col_Gap;
      Size_X0 := Size_X1 - Min (Size_W, W.W);
      Name_X1 := Size_X0 - Col_Gap;
      if Name_X1 < W.X + Name_X0 then
         Name_X1 := W.X + Name_X0;   --  clamp: name column may vanish
      end if;
   end Column_Xs;

   function Visible_Rows (W : Columns) return U64 is
   begin
      if W.H <= HH then
         return 1;
      end if;
      return U64'Max (1, (W.H - HH) / RH);
   end Visible_Rows;

   function Max_Top (W : Columns) return U64 is
      Vis : constant U64 := Visible_Rows (W);
   begin
      if W.N > Natural (Vis) then
         return U64 (W.N - Natural (Vis));
      end if;
      return 0;
   end Max_Top;

   procedure Clamp_Top (W : in out Columns) is
      M : constant U64 := Max_Top (W);
   begin
      if W.Top > M then
         W.Top := M;
      end if;
   end Clamp_Top;

   procedure Fire_On_Change (W : in out Columns) is
   begin
      if W.On_Change /= null then
         W.On_Change (W.Sel);
      end if;
   end Fire_On_Change;

   procedure Set_Selected (W : in out Columns; I : Natural) is
      Vis : constant U64 := Visible_Rows (W);
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
            if W.Sel > 0 then
               if U64 (W.Sel - 1) < W.Top then
                  W.Top := U64 (W.Sel - 1);
               elsif U64 (W.Sel - 1) >= W.Top + Vis then
                  W.Top := U64 (W.Sel - 1) - (Vis - 1);
               end if;
            end if;
            Clamp_Top (W);
            Fire_On_Change (W);
         end if;
      end;
   end Set_Selected;

   function Selected (W : Columns) return Natural is (W.Sel);

   procedure Set_On_Open (W : in out Columns; Cb : Row_Callback) is
   begin
      W.On_Open := Cb;
   end Set_On_Open;

   --  Right-aligned mono text inside [X0, X1).
   procedure Draw_Right
     (C : Canvas; X0, X1, Y : U64; S : String; FG : Pixel)
   is
      --  Mono advance is 8 px per glyph regardless of the loaded
      --  face (Draw_Text_Mono's contract), so width is length*8.
      TW : constant U64 := U64 (S'Length) * 8;
   begin
      if TW <= X1 - X0 then
         Trinket.Fonts.Draw_Text_Mono
           (C, X1 - TW, Y, S, FG);
      else
         Trinket.Fonts.Draw_Text_Mono
           (C, X0, Y, S, FG);
      end if;
   end Draw_Right;

   overriding procedure Draw (W : Columns; C : Canvas) is
      C2      : Canvas := C;
      Vis     : constant U64 := Visible_Rows (W);
      Sel_C   : constant Pixel := Akernel_User.Theme.Sel_Blue;
      Txt_C   : constant Pixel := Akernel_User.Theme.Text_Dark;
      Hi_C    : constant Pixel := Akernel_User.Theme.Title_Text;
      Date_X1, Date_X0, Size_X1, Size_X0, Name_X1 : U64;
      Y       : U64;
   begin
      Set_Clip (C2, W.X, W.Y, W.X + W.W, W.Y + W.H);
      if C2.CX1 <= C2.CX0 or else C2.CY1 <= C2.CY0 then
         return;
      end if;
      Trinket.Paint.Fill_Rect
        (C2, W.X, W.Y, W.X + W.W, W.Y + W.H, Akernel_User.Theme.Pane);
      Column_Xs (W, Date_X1, Date_X0, Size_X1, Size_X0, Name_X1);

      --  Header band: recessed fill + a bottom rule.
      Trinket.Paint.Fill_Rect
        (C2, W.X, W.Y, W.X + W.W, W.Y + HH, Akernel_User.Theme.Face);
      Trinket.Paint.Fill_Rect
        (C2, W.X, W.Y + HH - 1, W.X + W.W, W.Y + HH,
         Akernel_User.Theme.Bevel_Lo);
      Trinket.Fonts.Draw_Text_Mono
        (C2, W.X + Name_X0, W.Y + 1, "Name", Txt_C);
      Draw_Right (C2, Size_X0, Size_X1, W.Y + 1, "Size", Txt_C);
      Draw_Right (C2, Date_X0, Date_X1, W.Y + 1, "Date", Txt_C);

      for R in 0 .. Vis - 1 loop
         declare
            Idx : constant U64 := W.Top + R;
         begin
            exit when Idx >= U64 (W.N);
            Y := W.Y + HH + R * RH;
            exit when Y + RH > W.Y + W.H;
            declare
               Sel : constant Boolean := Natural (Idx + 1) = W.Sel;
               Row : Row_Rec renames W.Rows (Natural (Idx + 1));
               TY  : constant U64 := Y + (RH - LH) / 2;
               FG  : constant Pixel := (if Sel then Hi_C else Txt_C);
               BG  : constant Pixel := (if Sel then Sel_C
                                        else Akernel_User.Theme.Pane);
            begin
               if Sel then
                  Trinket.Paint.Fill_Rect
                    (C2, W.X, Y, W.X + W.W, Y + RH, Sel_C);
               end if;
               Trinket.Fonts.Draw_Text_Mono
                 (C2, W.X + Name_X0, TY,
                  Row.Name (1 .. Row.Name_Len), FG);
               if not Row.Is_Dir and then Row.Size_Len > 0 then
                  Draw_Right
                    (C2, Size_X0, Size_X1, TY,
                     Row.Size (1 .. Row.Size_Len), FG);
               end if;
               if Row.Date_Len > 0 then
                  Draw_Right
                    (C2, Date_X0, Date_X1, TY,
                     Row.Date (1 .. Row.Date_Len), FG);
               end if;
               --  Dotted focus ring when focused (M87h).
               if W.Focused then
                  Trinket.Paint.Focus_Ring
                    (C2, W.X + 1, W.Y + 1,
                     W.X + W.W - 1, W.Y + W.H - 1,
                     (if Sel then Hi_C else Txt_C));
               end if;
               pragma Unreferenced (BG);
            end;
         end;
      end loop;
   end Draw;

   overriding procedure Min_Size (W : Columns; MW, MH : out U64) is
   begin
      MW := Name_X0 + 6 * 8 + Col_Gap + Size_W + Col_Gap + Date_W + 4;
      MH := HH + 2 * RH + 2;
   end Min_Size;

   overriding function On_Key
     (W : access Columns; Code : U64) return Boolean
   is
      Vis : constant U64 := Visible_Rows (W.all);
   begin
      if W.N = 0 then
         return False;
      end if;
      if Code = Key_Up then
         if W.Sel > 1 then
            Set_Selected (W.all, W.Sel - 1);
         end if;
         return True;
      elsif Code = Key_Down then
         if W.Sel < W.N then
            Set_Selected (W.all, W.Sel + 1);
         end if;
         return True;
      elsif Code = Key_Pageup then
         if W.Sel > Natural (Vis) then
            Set_Selected (W.all, W.Sel - Natural (Vis));
         else
            Set_Selected (W.all, 1);
         end if;
         return True;
      elsif Code = Key_Pagedown then
         if W.Sel + Natural (Vis) <= W.N then
            Set_Selected (W.all, W.Sel + Natural (Vis));
         else
            Set_Selected (W.all, W.N);
         end if;
         return True;
      elsif Code = Key_Home then
         Set_Selected (W.all, 1);
         return True;
      elsif Code = Key_End then
         Set_Selected (W.all, W.N);
         return True;
      elsif Code = Key_Return then
         if W.Sel > 0 and then W.On_Open /= null then
            W.On_Open (W.Sel);
         end if;
         return True;
      end if;
      return False;
   end On_Key;

   overriding function On_Pointer
     (W : access Columns; K : Widgets.Pointer_Kind; PX, PY : U64)
      return Boolean
   is
      R   : U64;
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
      if PY < W.Y + HH then
         return True;   --  header: consume, no hit
      end if;
      R := (PY - W.Y - HH) / RH;
      Idx := Natural (W.Top + R) + 1;
      if Idx <= W.N then
         declare
            Now    : constant U64 := Akernel_User.Syscalls.Read_Time;
            Double : constant Boolean :=
              Idx = W.Last_Press_Row
              and then Now - W.Last_Press_Time < Double_Click_Ticks;
         begin
            W.Last_Press_Row  := Idx;
            W.Last_Press_Time := Now;
            Set_Selected (W.all, Idx);
            if Double and then W.On_Open /= null then
               W.On_Open (Idx);
            end if;
         end;
      else
         W.Last_Press_Row := 0;
      end if;
      return True;
   end On_Pointer;

   --  Scrolled composite: columns + flush v-bar, self-wired.

   procedure Bar_Moved (Bar : Widgets.Any_Widget; Pos : U64) is
      CW : constant Any_Columns :=
        Any_Columns (Widgets.Scrollbar.Scrollbar (Bar.all).Ctx);
   begin
      CW.Top := Pos;
      CW.Dirty := True;
   end Bar_Moved;

   procedure Layout (W : in out Scrolled_Columns) is
      A  : constant U64 := Widgets.Arrow;
      CW : constant U64 := (if W.W > A then W.W - A else 0);
   begin
      W.CW.X := W.X;
      W.CW.Y := W.Y;
      W.CW.W := CW;
      W.CW.H := W.H;
      W.VBar.X := W.X + CW;
      W.VBar.Y := W.Y;
      W.VBar.W := A;
      W.VBar.H := W.H;
      for I in 1 .. Group (W).N loop
         Group (W).Kids (I).Layout;
      end loop;
   end Layout;

   procedure Min_Size (W : Scrolled_Columns; MW, MH : out U64) is
      A  : constant U64 := Widgets.Arrow;
      CW, CH : U64;
   begin
      W.CW.Min_Size (CW, CH);
      MW := CW + A;
      MH := Max (CH, 3 * A);
   end Min_Size;

   procedure Draw (W : Scrolled_Columns; C : Canvas) is
   begin
      Widgets.Scrollbar.Set_Range
        (Widgets.Scrollbar.Scrollbar (W.VBar.all), 0,
         Max_Top (W.CW.all), Visible_Rows (W.CW.all));
      Widgets.Scrollbar.Set_Pos
        (Widgets.Scrollbar.Scrollbar (W.VBar.all), W.CW.Top);
      Group (W).Draw (C);
   end Draw;

   function New_Scrolled_Columns
     (CW        : out Any_Columns;
      On_Change : Selected_Callback := null;
      On_Open   : Row_Callback := null) return Widgets.Any_Widget
   is
      type SC_Access is access Scrolled_Columns;
      SC : constant SC_Access := new Scrolled_Columns;
   begin
      CW := New_Columns (On_Change, On_Open);
      SC.CW := CW;
      SC.VBar := Widgets.Scrollbar.New_Scrollbar
        (Bar_Moved'Access, Vertical, Widgets.Any_Widget (CW));
      Group (SC.all).Add (Widgets.Any_Widget (CW));
      Group (SC.all).Add (SC.VBar);
      return Widgets.Any_Widget (SC);
   end New_Scrolled_Columns;

end Trinket.Columns;
