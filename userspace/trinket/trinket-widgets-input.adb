with Trinket.Paint;
with Trinket.Fonts;

package body Trinket.Widgets.Input is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Input_Access is access Input;

   --  Input

   function New_Input return Any_Widget is
   begin
      return Any_Widget'(new Input);
   end New_Input;

   function Get_Text (W : Input) return String is
   begin
      return W.Buf (1 .. W.Len);
   end Get_Text;

   procedure Set_Text (W : in out Input; S : String) is
      N : constant Natural := Natural'Min (S'Length, Max_Input);
   begin
      W.Len := N;
      if N > 0 then
         W.Buf (1 .. N) := S (S'First .. S'First + N - 1);
      end if;
      W.Cur  := N;
      W.Dirty := True;
   end Set_Text;

   function Wants_Focus (W : Input) return Boolean is
      pragma Unreferenced (W);
   begin
      return True;
   end Wants_Focus;

   --  Keep the cursor inside the visible window by scrolling
   --  HOff (pixel granularity against the proportional font:
   --  drop leading chars until the cursor fits the inner width).
   procedure Ensure_Visible (W : in out Input) is
      Inner : constant U64 := (if W.W > 8 then W.W - 8 else 8);
   begin
      if W.Cur < W.HOff then
         W.HOff := W.Cur;
      else
         while W.HOff < W.Cur
           and then Fonts.Text_Width (W.Buf (W.HOff + 1 .. W.Cur))
                    > Inner
         loop
            W.HOff := W.HOff + 1;
         end loop;
      end if;
   end Ensure_Visible;

   procedure Draw (W : Input; C : Canvas) is
      C2 : Canvas := C;
      LH : constant U64 := Fonts.Line_Height;
      TY : constant U64 :=
        W.Y + (if W.H > LH then (W.H - LH) / 2 else 0);
      CX : constant U64 := W.X + 4 +
        Fonts.Text_Width (W.Buf (W.HOff + 1 .. W.Cur));
   begin
      if not Intersects (W, C) then
         return;
      end if;
      Set_Clip (C2, W.X, W.Y, W.X + W.W, W.Y + W.H);
      Paint.Fill_Rect (C2, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);
      Paint.Bevel2 (C2, W.X, W.Y, W.X + W.W, W.Y + W.H,
                    Raised => False);
      if W.Len > W.HOff then
         Fonts.Draw_Text
           (C2, W.X + 4, TY + 2,
            W.Buf (W.HOff + 1 .. W.Len), Text_Dark);
      end if;
      if W.Focused then
         Paint.Fill_Rect
           (C2, CX, TY + 2, CX + 1, TY + 2 + LH, Text_Dark);
      end if;
   end Draw;

   procedure Min_Size (W : Input; MW, MH : out U64) is
      pragma Unreferenced (W);
   begin
      --  Sunken field: 4px pad + bevel each side over ~5 cells;
      --  vertically the same LH + 8 as an inset label.
      MW := 48;
      MH := Fonts.Line_Height + 8;
   end Min_Size;

   function On_Key (W : access Input; Code : U64) return Boolean is
   begin
      if not W.Focused then
         return False;
      end if;

      if Code >= 32 and then Code <= 126 then
         if W.Len < Max_Input then
            --  Insert at cursor.
            for I in reverse W.Cur + 1 .. W.Len loop
               W.Buf (I + 1) := W.Buf (I);
            end loop;
            W.Buf (W.Cur + 1) := Character'Val (Natural (Code));
            W.Len := W.Len + 1;
            W.Cur := W.Cur + 1;
            Ensure_Visible (W.all);
            W.Dirty := True;
         end if;
         return True;
      elsif Code = 8 then               --  Backspace
         if W.Cur > 0 then
            for I in W.Cur .. W.Len - 1 loop
               W.Buf (I) := W.Buf (I + 1);
            end loop;
            W.Len := W.Len - 1;
            W.Cur := W.Cur - 1;
            Ensure_Visible (W.all);
            W.Dirty := True;
         end if;
         return True;
      elsif Code = 127 or else Code = Key_Delete then
         if W.Cur < W.Len then
            for I in W.Cur + 1 .. W.Len - 1 loop
               W.Buf (I) := W.Buf (I + 1);
            end loop;
            W.Len := W.Len - 1;
            W.Dirty := True;
         end if;
         return True;
      elsif Code = 13 or else Code = 10 then   --  Enter
         --  The input seat delivers Return as LF (10) — the
         --  keymap maps Linux KEY_ENTER there — so accept both.
         if W.On_Commit /= null then
            W.On_Commit.all;
         end if;
         return True;
      elsif Code = Key_Left then
         if W.Cur > 0 then
            W.Cur := W.Cur - 1;
            Ensure_Visible (W.all);
            W.Dirty := True;
         end if;
         return True;
      elsif Code = Key_Right then
         if W.Cur < W.Len then
            W.Cur := W.Cur + 1;
            Ensure_Visible (W.all);
            W.Dirty := True;
         end if;
         return True;
      elsif Code = Key_Home then
         W.Cur := 0;
         Ensure_Visible (W.all);
         W.Dirty := True;
         return True;
      elsif Code = Key_End then
         W.Cur := W.Len;
         Ensure_Visible (W.all);
         W.Dirty := True;
         return True;
      end if;

      --  Up/Down/PageUp/PageDown fall through: a focused input
      --  does not steal a sibling listview's navigation keys.
      return False;
   end On_Key;

   function On_Pointer
     (W : access Input; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
      T : U64;
      Acc : U64 := 0;
   begin
      if K /= Press or else not Inside (W.all, PX, PY) then
         return False;
      end if;
      W.Focused := True;
      --  Nearest cursor gap: walk the visible run until half of a
      --  glyph's advance crosses the click point.
      T := (if PX > W.X + 4 then PX - W.X - 4 else 0);
      W.Cur := W.Len;
      if W.Len > 0 then
         for P in W.HOff .. W.Len - 1 loop
            declare
               CW : constant U64 :=
                 Fonts.Text_Width (W.Buf (P + 1 .. P + 1));
            begin
               if Acc + CW / 2 >= T then
                  W.Cur := P;
                  exit;
               end if;
               Acc := Acc + CW;
            end;
         end loop;
      end if;
      Ensure_Visible (W.all);
      W.Dirty := True;
      return True;
   end On_Pointer;

end Trinket.Widgets.Input;
