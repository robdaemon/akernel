with Trinket.Paint;
with Trinket.Fonts;

package body Trinket.Text_Edit is
   use type Trinket.U64;

   Pad : constant U64 := 6;  --  text inset inside the frame

   function LH return U64 is (Fonts.Line_Height);

   --  Pixel offset of the gap before character Col+1 (0-based
   --  column) in S — prefix-sum against the proportional font.
   function Col_X (S : String; Col : Natural) return U64 is
     (if Col = 0 then 0
      else Fonts.Text_Width (S (S'First .. S'First + Col - 1)));

   function New_Text_Edit return Widgets.Any_Widget is
      TE : constant Any_Text_Edit := new Text_Edit;
   begin
      TE.Lines := new Lines_Array;
      TE.N := 1;
      TE.Lines (1).Len := 0;
      return Widgets.Any_Widget (TE);
   end New_Text_Edit;

   --  Content API

   procedure Clear (W : in out Text_Edit) is
   begin
      W.N := 0;  --  Ensure_Line recreates line 1 lazily, so a
                 --  load's first Append_Line doesn't leave a
                 --  phantom blank line at the top
      W.Cur_L := 1;
      W.Cur_C := 0;
      W.Top := 0;
      W.Sel := False;
      W.Dirty_F := False;
      W.Dirty := True;
   end Clear;

   procedure Append_Line (W : in out Text_Edit; S : String) is
   begin
      if W.N >= Max_Lines then
         return;
      end if;
      W.N := W.N + 1;
      W.Lines (W.N).Len := Natural'Min (S'Length, Max_Cols);
      W.Lines (W.N).Buf (1 .. W.Lines (W.N).Len) :=
        S (S'First .. S'First + W.Lines (W.N).Len - 1);
      W.Dirty := True;
   end Append_Line;

   function Line_Count (W : Text_Edit) return Natural is (W.N);

   function Get_Line (W : Text_Edit; I : Natural) return String is
     (if I >= 1 and then I <= W.N
      then W.Lines (I).Buf (1 .. W.Lines (I).Len)
      else "");

   function Modified (W : Text_Edit) return Boolean is (W.Dirty_F);

   procedure Clear_Modified (W : in out Text_Edit) is
   begin
      W.Dirty_F := False;
   end Clear_Modified;

   procedure Set_Top (W : in out Text_Edit; T : U64) is
      Max_Top : constant U64 :=
        (if U64 (W.N) > W.Visible_Rows
         then U64 (W.N) - W.Visible_Rows else 0);
   begin
      W.Top := U64'Min (T, Max_Top);
      W.Dirty := True;
   end Set_Top;

   function Top_Line (W : Text_Edit) return U64 is (W.Top);

   procedure Ensure_Line (W : in out Text_Edit) is
   begin
      if W.N = 0 then
         W.N := 1;
         W.Lines (1).Len := 0;
         W.Cur_L := 1;
         W.Cur_C := 0;
      end if;
   end Ensure_Line;

   function Visible_Rows (W : Text_Edit) return U64 is
     (if W.H > 2 * Pad + LH
      then (W.H - 2 * Pad) / LH else 1);

   --  Editing internals

   procedure Mark_Modified (W : in out Text_Edit) is
   begin
      W.Dirty_F := True;
      W.Dirty := True;
   end Mark_Modified;

   --  Selection ordering: (L1,C1) <= (L2,C2).
   procedure Sel_Bounds
     (W : Text_Edit; L1, C1, L2, C2 : out Natural) is
   begin
      if W.Anch_L < W.Cur_L
        or else (W.Anch_L = W.Cur_L and then W.Anch_C <= W.Cur_C)
      then
         L1 := W.Anch_L;  C1 := W.Anch_C;
         L2 := W.Cur_L;   C2 := W.Cur_C;
      else
         L1 := W.Cur_L;   C1 := W.Cur_C;
         L2 := W.Anch_L;  C2 := W.Anch_C;
      end if;
   end Sel_Bounds;

   procedure Delete_Selection (W : in out Text_Edit) is
      L1, C1, L2, C2 : Natural;
   begin
      if not W.Sel then
         return;
      end if;
      Sel_Bounds (W, L1, C1, L2, C2);
      if L1 = L2 then
         declare
            B : Line_String := W.Lines (L1).Buf;
            L : constant Natural := W.Lines (L1).Len;
         begin
            W.Lines (L1).Buf (1 .. L - (C2 - C1)) :=
              B (1 .. C1) & B (C2 + 1 .. L);
            W.Lines (L1).Len := L - (C2 - C1);
         end;
      else
         declare
            TL  : constant Natural :=
              Natural'Min (W.Lines (L2).Len - C2, Max_Cols - C1);
            Tail : constant String :=
              W.Lines (L2).Buf (C2 + 1 .. C2 + TL);
         begin
            W.Lines (L1).Buf (C1 + 1 .. C1 + Tail'Length) := Tail;
            W.Lines (L1).Len := C1 + Tail'Length;
            --  Remove lines L1+1 .. L2.
            for I in L1 + 1 .. W.N - (L2 - L1) loop
               W.Lines (I) := W.Lines (I + (L2 - L1));
            end loop;
            W.N := W.N - (L2 - L1);
         end;
      end if;
      W.Cur_L := L1;
      W.Cur_C := C1;
      W.Sel := False;
      Mark_Modified (W);
   end Delete_Selection;

   procedure Insert_Char (W : in out Text_Edit; Ch : Character) is
      L : Line_Rec renames W.Lines (W.Cur_L);
   begin
      if L.Len >= Max_Cols then
         return;
      end if;
      Delete_Selection (W);
      --  Recompute after a possible selection delete.
      declare
         LL : Line_Rec renames W.Lines (W.Cur_L);
      begin
         LL.Buf (W.Cur_C + 2 .. LL.Len + 1) :=
           LL.Buf (W.Cur_C + 1 .. LL.Len);
         LL.Buf (W.Cur_C + 1) := Ch;
         LL.Len := LL.Len + 1;
         W.Cur_C := W.Cur_C + 1;
      end;
      Mark_Modified (W);
   end Insert_Char;

   procedure Backspace (W : in out Text_Edit) is
   begin
      if W.Sel then
         Delete_Selection (W);
         return;
      end if;
      if W.Cur_C > 0 then
         declare
            L : Line_Rec renames W.Lines (W.Cur_L);
         begin
            L.Buf (W.Cur_C .. L.Len - 1) := L.Buf (W.Cur_C + 1 .. L.Len);
            L.Len := L.Len - 1;
            W.Cur_C := W.Cur_C - 1;
         end;
         Mark_Modified (W);
      elsif W.Cur_L > 1 then
         --  Join with the previous line.
         declare
            Prev : Line_Rec renames W.Lines (W.Cur_L - 1);
            Cur  : constant String :=
              W.Lines (W.Cur_L).Buf (1 .. W.Lines (W.Cur_L).Len);
         begin
            if Prev.Len + Cur'Length <= Max_Cols then
               W.Cur_C := Prev.Len;
               Prev.Buf (Prev.Len + 1 .. Prev.Len + Cur'Length) := Cur;
               Prev.Len := Prev.Len + Cur'Length;
               for I in W.Cur_L .. W.N - 1 loop
                  W.Lines (I) := W.Lines (I + 1);
               end loop;
               W.N := W.N - 1;
               W.Cur_L := W.Cur_L - 1;
               Mark_Modified (W);
            end if;
         end;
      end if;
   end Backspace;

   procedure Split_Line (W : in out Text_Edit) is
   begin
      if W.N >= Max_Lines then
         return;
      end if;
      Delete_Selection (W);
      declare
         Rest : constant String :=
           W.Lines (W.Cur_L).Buf (W.Cur_C + 1 .. W.Lines (W.Cur_L).Len);
      begin
         for I in reverse W.Cur_L + 1 .. W.N + 1 loop
            W.Lines (I) := W.Lines (I - 1);
         end loop;
         W.Lines (W.Cur_L).Len := W.Cur_C;
         W.N := W.N + 1;
         W.Lines (W.Cur_L + 1).Len := Rest'Length;
         W.Lines (W.Cur_L + 1).Buf (1 .. Rest'Length) := Rest;
         W.Cur_L := W.Cur_L + 1;
         W.Cur_C := 0;
      end;
      Mark_Modified (W);
   end Split_Line;

   procedure Forward_Delete (W : in out Text_Edit) is
   begin
      if W.Sel then
         Delete_Selection (W);
         return;
      end if;
      if W.Cur_C < W.Lines (W.Cur_L).Len then
         W.Cur_C := W.Cur_C + 1;
         Backspace (W);
      elsif W.Cur_L < W.N then
         --  Pull the next line up.
         W.Cur_L := W.Cur_L + 1;
         W.Cur_C := 0;
         Backspace (W);
      end if;
   end Forward_Delete;

   procedure Ensure_Cursor_Visible (W : in out Text_Edit) is
   begin
      if U64 (W.Cur_L - 1) < W.Top then
         W.Top := U64 (W.Cur_L - 1);
         W.Dirty := True;
      elsif U64 (W.Cur_L - 1) >= W.Top + W.Visible_Rows then
         W.Top := U64 (W.Cur_L - 1) - W.Visible_Rows + 1;
         W.Dirty := True;
      end if;
   end Ensure_Cursor_Visible;

   procedure Clamp_Cursor (W : in out Text_Edit) is
   begin
      if W.Cur_L > W.N then
         W.Cur_L := W.N;
      end if;
      if W.Cur_C > W.Lines (W.Cur_L).Len then
         W.Cur_C := W.Lines (W.Cur_L).Len;
      end if;
   end Clamp_Cursor;

   procedure Collapse (W : in out Text_Edit) is
   begin
      W.Sel := False;
      W.Dirty := True;
   end Collapse;

   function On_Key (W : access Text_Edit; Code : U64) return Boolean is
   begin
      Ensure_Line (W.all);
      if Code in 32 .. 126 then
         Insert_Char (W.all, Character'Val (Natural (Code)));
      elsif Code = 8 then
         Backspace (W.all);
      elsif Code = 10 then
         Split_Line (W.all);
      elsif Code = Key_Delete then
         Forward_Delete (W.all);
      elsif Code = Key_Up then
         Collapse (W.all);
         if W.Cur_L > 1 then
            W.Cur_L := W.Cur_L - 1;
         end if;
         Clamp_Cursor (W.all);
      elsif Code = Key_Down then
         Collapse (W.all);
         if W.Cur_L < W.N then
            W.Cur_L := W.Cur_L + 1;
         end if;
         Clamp_Cursor (W.all);
      elsif Code = Key_Left then
         Collapse (W.all);
         if W.Cur_C > 0 then
            W.Cur_C := W.Cur_C - 1;
         elsif W.Cur_L > 1 then
            W.Cur_L := W.Cur_L - 1;
            W.Cur_C := W.Lines (W.Cur_L).Len;
         end if;
      elsif Code = Key_Right then
         Collapse (W.all);
         if W.Cur_C < W.Lines (W.Cur_L).Len then
            W.Cur_C := W.Cur_C + 1;
         elsif W.Cur_L < W.N then
            W.Cur_L := W.Cur_L + 1;
            W.Cur_C := 0;
         end if;
      elsif Code = Key_Home then
         Collapse (W.all);
         W.Cur_C := 0;
      elsif Code = Key_End then
         Collapse (W.all);
         W.Cur_C := W.Lines (W.Cur_L).Len;
      elsif Code = Key_Pageup then
         Collapse (W.all);
         W.Top := (if W.Top > W.Visible_Rows
                   then W.Top - W.Visible_Rows else 0);
         W.Cur_L := Natural (W.Top) + 1;
         Clamp_Cursor (W.all);
      elsif Code = Key_Pagedown then
         Collapse (W.all);
         W.Set_Top (W.Top + W.Visible_Rows);
         W.Cur_L := Natural (W.Top) + 1;
         Clamp_Cursor (W.all);
      else
         return False;  --  ESC, tab, unknown: not consumed
      end if;
      Ensure_Cursor_Visible (W.all);
      W.Dirty := True;
      return True;
   end On_Key;

   --  Coordinates -> (line, col); clamps into the document.
   --  Column is the nearest cursor gap in the proportional run.
   procedure Locate
     (W : Text_Edit; PX, PY : U64; L, Col : out Natural)
   is
      Row : constant U64 :=
        (if PY > W.Y + Pad then (PY - W.Y - Pad) / LH else 0);
      T   : U64;
      Acc : U64 := 0;
   begin
      L := Natural'Min
        (Natural (W.Top) + Natural (Row) + 1, W.N);
      Col := W.Lines (L).Len;
      T := (if PX > W.X + Pad then PX - W.X - Pad else 0);
      if Col > 0 then
         for P in 1 .. Col loop
            declare
               GW : constant U64 :=
                 Fonts.Text_Width (W.Lines (L).Buf (P .. P));
            begin
               if Acc + GW / 2 >= T then
                  Col := P - 1;
                  exit;
               end if;
               Acc := Acc + GW;
            end;
         end loop;
      end if;
   end Locate;

   function On_Pointer
     (W : access Text_Edit; K : Widgets.Pointer_Kind; PX, PY : U64)
      return Boolean
   is
      L, Col : Natural;
   begin
      Ensure_Line (W.all);
      case K is
         when Widgets.Press =>
            if not Inside (W.all, PX, PY) then
               return False;
            end if;
            Locate (W.all, PX, PY, L, Col);
            W.Cur_L := L;
            W.Cur_C := Col;
            W.Anch_L := L;
            W.Anch_C := Col;
            W.Sel := False;
            W.Dragging := True;
            W.Dirty := True;
            return True;
         when Widgets.Move =>
            if W.Dragging then
               Locate (W.all, PX, PY, L, Col);
               if L /= W.Cur_L or else Col /= W.Cur_C then
                  W.Cur_L := L;
                  W.Cur_C := Col;
                  W.Sel := True;
                  W.Dirty := True;
                  Ensure_Cursor_Visible (W.all);
               end if;
               return True;
            end if;
         when Widgets.Release =>
            if W.Dragging then
               W.Dragging := False;
               --  Anchor == cursor means a click, not a selection.
               if W.Anch_L = W.Cur_L
                 and then W.Anch_C = W.Cur_C
               then
                  W.Sel := False;
               end if;
               return True;
            end if;
      end case;
      return False;
   end On_Pointer;

   procedure Draw (W : Text_Edit; C : Canvas) is
      TX0 : constant U64 := W.X + Pad;
      TY0 : constant U64 := W.Y + Pad;
      L1, C1, L2, C2 : Natural;
      Rows : constant U64 := W.Visible_Rows;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);
      Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                    Raised => False);
      if W.Sel then
         Sel_Bounds (W, L1, C1, L2, C2);
      end if;
      for R in 0 .. Rows - 1 loop
         declare
            LN : constant Natural := Natural (W.Top + R) + 1;
            LY : constant U64 := TY0 + R * LH;
         begin
            exit when LN > W.N or else LY + LH > W.Y + W.H - Pad;
            declare
               S   : constant String :=
                 W.Lines (LN).Buf (1 .. W.Lines (LN).Len);
               SL  : constant Integer :=
                 (if W.Sel and then LN >= L1 and then LN <= L2
                  then (if LN = L1 then C1 else 0) else -1);
               EL  : constant Integer :=
                 (if W.Sel and then LN >= L1 and then LN <= L2
                  then (if LN = L2 then C2 else W.Lines (LN).Len)
                  else -1);
            begin
               if SL >= 0 and then EL > SL then
                  --  Selection band + white text on it.
                  Paint.Fill_Rect
                    (C, TX0 + Col_X (S, SL), LY,
                     TX0 + Col_X (S, EL), LY + LH, Sel_Blue);
                  if SL > 0 then
                     Fonts.Draw_Text
                       (C, TX0, LY, S (1 .. SL), Text_Dark);
                  end if;
                  Fonts.Draw_Text
                    (C, TX0 + Col_X (S, SL), LY,
                     S (SL + 1 .. EL), Pane);
                  if EL < S'Length then
                     Fonts.Draw_Text
                       (C, TX0 + Col_X (S, EL), LY,
                        S (EL + 1 .. S'Length), Text_Dark);
                  end if;
               else
                  Fonts.Draw_Text (C, TX0, LY, S, Text_Dark);
               end if;
               --  Cursor bar.
               if LN = W.Cur_L then
                  Paint.Fill_Rect
                    (C, TX0 + Col_X (S, W.Cur_C), LY,
                     TX0 + Col_X (S, W.Cur_C) + 1, LY + LH,
                     Text_Dark);
               end if;
            end;
         end;
      end loop;
   end Draw;

end Trinket.Text_Edit;
