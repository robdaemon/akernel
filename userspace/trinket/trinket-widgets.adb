with Trinket.Paint;
with Trinket.Fonts;
with Akernel_User.Theme;

package body Trinket.Widgets is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
    type Label_Access is access Label;
    type Button_Access is access Button;
    type Gauge_Access is access Gauge;
    type Separator_Access is access Separator;
    type Checkbox_Access is access Checkbox;
    type Radio_Access is access Radio;
    type Group_Access is access Group;
   type Scrollbar_Access is access Scrollbar;
   type Slider_Access is access Slider;
   type Image_Access is access Image_Widget;
   type Tabs_Access is access Tabs;

   --  Image widget: centered 1:1 blit, color-key honored.
   function New_Image (Img : Trinket.Images.Image) return Any_Widget is
      I : constant Image_Access := new Image_Widget;
   begin
      I.Img := Img;
      return Any_Widget (I);
   end New_Image;

    overriding procedure Draw (W : Image_Widget; C : Canvas) is
       DX : U64 := W.X;
       DY : U64 := W.Y;
       C2 : Canvas := C;
    begin
       if not Trinket.Images.Loaded (W.Img) then
          return;
       end if;
       if W.W > W.Img.W then
          DX := W.X + (W.W - W.Img.W) / 2;
       end if;
       if W.H > W.Img.H then
          DY := W.Y + (W.H - W.Img.H) / 2;
       end if;
       --  Clip to our own rect: a slice thinner than the image
       --  must not spill over the group frame (M86e overflow).
       Set_Clip (C2, W.X, W.Y, W.X + W.W, W.Y + W.H);
       Trinket.Images.Blit (C2, W.Img, DX, DY);
    end Draw;

   procedure Set_Image
     (W : in out Image_Widget; Img : Trinket.Images.Image) is
   begin
      W.Img := Img;
      W.Dirty := True;
   end Set_Image;

   overriding procedure Min_Size (W : Image_Widget; MW, MH : out U64) is
   begin
      MW := W.Img.W;
      MH := W.Img.H;
   end Min_Size;

    function Max (A, B : U64) return U64 is (if A > B then A else B);
    function Min (A, B : U64) return U64 is (if A < B then A else B);

    --  Damage-list append with in-place merge: a rect that
    --  intersects an existing entry unions into it (single pass —
    --  a merge that bridges a THIRD entry is left as-is; the
    --  overlap repaints identically, just twice). A full list
    --  sets Overflow; the caller degrades to Dirty_Union.
    procedure Add_Rect
      (Rects    : in out Rect_Array;
       N        : in out Natural;
       Overflow : in out Boolean;
       X0, Y0, X1, Y1 : U64) is
    begin
       if Overflow then
          return;
       end if;
       for I in 1 .. N loop
          if X0 < Rects (I).X1 and then X1 > Rects (I).X0
            and then Y0 < Rects (I).Y1 and then Y1 > Rects (I).Y0
          then
             Rects (I).X0 := Min (Rects (I).X0, X0);
             Rects (I).Y0 := Min (Rects (I).Y0, Y0);
             Rects (I).X1 := Max (Rects (I).X1, X1);
             Rects (I).Y1 := Max (Rects (I).Y1, Y1);
             return;
          end if;
       end loop;
       if N = Max_Damage then
          Overflow := True;
          return;
       end if;
       N := N + 1;
       Rects (N) := (X0, Y0, X1, Y1);
    end Add_Rect;


   procedure Layout (W : in out Widget) is
      pragma Unreferenced (W);
   begin
      null;
   end Layout;

   procedure Min_Size (W : Widget; MW, MH : out U64) is
      pragma Unreferenced (W);
   begin
      MW := 0;
      MH := 0;
   end Min_Size;

   function On_Pointer
     (W : access Widget; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
      pragma Unreferenced (W, K, PX, PY);
   begin
      return False;
   end On_Pointer;

   function On_Key (W : access Widget; Code : U64) return Boolean is
      pragma Unreferenced (W, Code);
   begin
      return False;
   end On_Key;

   function Inside (W : Widget; PX, PY : U64) return Boolean is
     (PX >= W.X and then PX < W.X + W.W
      and then PY >= W.Y and then PY < W.Y + W.H);

    function Dirty_Union
      (W : Widget; X0, Y0, X1, Y1 : out U64) return Boolean
    is
    begin
       if W.Dirty then
          X0 := W.X;  Y0 := W.Y;  X1 := W.X + W.W;  Y1 := W.Y + W.H;
          return True;
       end if;
       return False;
    end Dirty_Union;

    procedure Dirty_List
      (W        : Widget;
       Rects    : in out Rect_Array;
       N        : in out Natural;
       Overflow : in out Boolean) is
    begin
       if W.Dirty then
          Add_Rect (Rects, N, Overflow, W.X, W.Y, W.X + W.W,
                    W.Y + W.H);
       end if;
    end Dirty_List;

   procedure Clear_Dirty (W : in out Widget) is
   begin
      W.Dirty := False;
   end Clear_Dirty;

   function Intersects (W : Widget; C : Canvas) return Boolean is
     (W.X < C.CX1 and then W.X + W.W > C.CX0
      and then W.Y < C.CY1 and then W.Y + W.H > C.CY0);

   procedure Set_Text
     (Buf : out String; Len : out Text_Len; S : String) is
   begin
      Len := Text_Len'Min (S'Length, Buf'Length);
      Buf (Buf'First .. Buf'First + Len - 1) :=
        S (S'First .. S'First + Len - 1);
   end Set_Text;

   --  Label

   function New_Label
     (S : String; Align : Alignment := Left; Inset : Boolean := False)
      return Any_Widget
   is
      L : constant Label_Access := new Label;
   begin
      Set_Text (L.Txt, L.Len, S);
      L.Align := Align;
      L.Inset := Inset;
      return Any_Widget (L);
   end New_Label;

   procedure Draw (W : Label; C : Canvas) is
      LH : constant U64 := Fonts.Line_Height;
      TY : constant U64 :=
        W.Y + (if W.H > LH then (W.H - LH) / 2 else 0);
      TX : U64;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      if W.Inset then
         Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);
         Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                      Raised => False);
      end if;
      TX := (if W.Align = Center
             then W.X + (W.W - Min (W.W, Fonts.Text_Width
                                      (W.Txt (1 .. W.Len)))) / 2
             else W.X + (if W.Inset then 6 else 2));
      Fonts.Draw_Text
        (C, TX, TY + (if W.Inset then 2 else 0),
         W.Txt (1 .. W.Len), Text_Dark);
   end Draw;

   procedure Set_Text (W : in out Label; S : String) is
   begin
      Set_Text (W.Txt, W.Len, S);
      W.Dirty := True;
   end Set_Text;

   procedure Min_Size (W : Label; MW, MH : out U64) is
      LH : constant U64 := Fonts.Line_Height;
   begin
      --  Inset: 6px text pad + 2px bevel each way, and the same
      --  vertical slack Input needs (text draws at TY+2).
      MW := Fonts.Text_Width (W.Txt (1 .. W.Len))
        + (if W.Inset then 8 else 4);
      MH := LH + (if W.Inset then 8 else 0);
   end Min_Size;

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

   procedure Set_Focused (W : in out Input; F : Boolean) is
   begin
      if W.Focused /= F then
         W.Focused := F;
         W.Dirty := True;   --  cursor bar appears/disappears
      end if;
   end Set_Focused;

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

   --  Button

   function New_Button
     (S        : String;
      On_Click : Click_Callback := null;
      Disabled : Boolean        := False) return Any_Widget
   is
      B : constant Button_Access := new Button;
   begin
      Set_Text (B.Txt, B.Len, S);
      B.On_Click := On_Click;
      B.Disabled := Disabled;
      return Any_Widget (B);
   end New_Button;

   procedure Draw (W : Button; C : Canvas) is
      LH : constant U64 := Fonts.Line_Height;
      TW : constant U64 := Fonts.Text_Width (W.Txt (1 .. W.Len));
      Shift : constant U64 := (if W.Pressed then 1 else 0);
      TX : constant U64 :=
        W.X + (if W.W > TW then (W.W - TW) / 2 else 0) + Shift;
      TY : constant U64 :=
        W.Y + (if W.H > LH then (W.H - LH) / 2 else 0) + Shift;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      --  M86c: hover brightens the face; disabled stays flat.
      Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                       (if W.Hover and then not W.Disabled
                          and then not W.Pressed
                        then Akernel_User.Theme.Face_Hi
                        else Face));
      Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                   Raised => not W.Pressed);
      if W.Disabled then
         --  Ghosted: embossed label, light copy under dark.
         Fonts.Draw_Text (C, TX + 1, TY + 1, W.Txt (1 .. W.Len),
                          Bevel_Hi);
         Fonts.Draw_Text (C, TX, TY, W.Txt (1 .. W.Len),
                          Bevel_Lo);
      else
         Fonts.Draw_Text (C, TX, TY, W.Txt (1 .. W.Len),
                          Text_Dark);
      end if;
   end Draw;

   procedure Min_Size (W : Button; MW, MH : out U64) is
   begin
      --  Centered label: 2px bevel + 2px breathing room per side
      --  (LH + 8 vertically — the +4 floor left the glyph cell
      --  touching the bottom bevel, descenders included).
      MW := Fonts.Text_Width (W.Txt (1 .. W.Len)) + 8;
      MH := Fonts.Line_Height + 8;
   end Min_Size;

   --  Gauge

   function New_Gauge (Show_Pct : Boolean := True) return Any_Widget is
      G : constant Gauge_Access := new Gauge;
   begin
      G.Show_Pct := Show_Pct;
      return Any_Widget (G);
   end New_Gauge;

   procedure Set_Fraction (W : in out Gauge; Num, Den : U64) is
      Old_Num : constant U64 := W.Num;
      Old_Den : constant U64 := W.Den;
   begin
      W.Den := (if Den = 0 then 1 else Den);
      W.Num := (if Num > W.Den then W.Den else Num);
      if W.Num /= Old_Num or else W.Den /= Old_Den then
         W.Dirty := True;
      end if;
   end Set_Fraction;

   procedure Draw (W : Gauge; C : Canvas) is
      LH  : constant U64 := Fonts.Line_Height;
      Den : constant U64 := (if W.Den = 0 then 1 else W.Den);
      FW  : U64;  --  fill run inside the 2px bevel
      Pct : String (1 .. 4);
      PL  : Natural := 0;
      N   : U64;
      TW  : U64;
      TX  : U64;
      TY  : U64;
      C2  : Canvas;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);
      Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                    Raised => False);
      FW := (if W.W > 4 then (W.W - 4) * W.Num / Den else 0);
      if FW > 0 then
         Paint.Fill_Rect
           (C, W.X + 2, W.Y + 2, W.X + 2 + FW, W.Y + W.H - 2,
            Sel_Blue);
      end if;
      if W.Show_Pct then
         --  "NN%": N <= 100 (Set_Fraction clamps Num <= Den).
         N := W.Num * 100 / Den;
         if N >= 100 then
            PL := PL + 1;
            Pct (PL) := Character'Val (48 + Natural (N / 100));
         end if;
         if N >= 10 then
            PL := PL + 1;
            Pct (PL) := Character'Val (48 + Natural (N / 10 mod 10));
         end if;
         PL := PL + 1;
         Pct (PL) := Character'Val (48 + Natural (N mod 10));
         PL := PL + 1;
         Pct (PL) := '%';
         TW := Fonts.Text_Width (Pct (1 .. PL));
         TX := W.X + (if W.W > TW then (W.W - TW) / 2 else 0);
         TY := W.Y + (if W.H > LH then (W.H - LH) / 2 else 0);
         --  Dark on the empty half, light on the fill.
         C2 := C;
         Set_Clip (C2, W.X + 2 + FW, W.Y + 2,
                   W.X + W.W - 2, W.Y + W.H - 2);
         Fonts.Draw_Text (C2, TX, TY, Pct (1 .. PL), Text_Dark);
         if FW > 0 then
            C2 := C;
            Set_Clip (C2, W.X + 2, W.Y + 2,
                      W.X + 2 + FW, W.Y + W.H - 2);
            Fonts.Draw_Text
              (C2, TX, TY, Pct (1 .. PL),
               Akernel_User.Theme.Title_Text);
         end if;
      end if;
   end Draw;

   procedure Min_Size (W : Gauge; MW, MH : out U64) is
   begin
      --  Bar plus the "100%" label; vertically the Input floor.
      MW := (if W.Show_Pct
             then Fonts.Text_Width ("100%") + 16 else 48);
      MH := Fonts.Line_Height + 8;
   end Min_Size;

   --  Separator

   function New_Separator return Any_Widget is
      S : constant Separator_Access := new Separator;
   begin
      return Any_Widget (S);
   end New_Separator;

   procedure Draw (W : Separator; C : Canvas) is
      Y : constant U64 := W.Y + W.H / 2;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      --  Groove: dark line, light line directly under it.
      Paint.Fill_Rect (C, W.X, Y - 1, W.X + W.W, Y, Bevel_Lo);
      Paint.Fill_Rect (C, W.X, Y, W.X + W.W, Y + 1, Bevel_Hi);
   end Draw;

   procedure Min_Size (W : Separator; MW, MH : out U64) is
      pragma Unreferenced (W);
   begin
      MW := 0;
      MH := 2;
   end Min_Size;

   function On_Pointer
     (W : access Button; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
   begin
      if W.Disabled then
         return False;
      end if;
      case K is
         when Press =>
            if Inside (W.all, PX, PY) then
               W.Pressed := True;
               W.Dirty := True;
               return True;
            end if;
         when Release =>
            if W.Pressed then
               W.Pressed := False;
               W.Dirty := True;
               if Inside (W.all, PX, PY)
                 and then W.On_Click /= null
               then
                  W.On_Click.all;
               end if;
               return True;
            end if;
         when Move =>
            --  Hover tracking: never consume an unpressed move,
            --  so sibling widgets clear/set their own hover.
            declare
               Now_In : constant Boolean := Inside (W.all, PX, PY);
            begin
               if Now_In /= W.Hover then
                  W.Hover := Now_In;
                  W.Dirty := True;
               end if;
            end;
            return W.Pressed;
      end case;
      return False;
   end On_Pointer;

   --  Checkbox / Radio

   Toggle_Box : constant U64 := 14;  --  square box / disc size
   Toggle_Gap : constant U64 := 6;   --  box-to-label spacing

   function New_Checkbox
     (S         : String;
      Checked   : Boolean := False;
      On_Change : Toggle_Callback := null;
      Disabled  : Boolean := False) return Any_Widget
   is
      B : constant Checkbox_Access := new Checkbox;
   begin
      Set_Text (B.Txt, B.Len, S);
      B.Checked := Checked;
      B.On_Change := On_Change;
      B.Disabled := Disabled;
      return Any_Widget (B);
   end New_Checkbox;

   procedure Set_Checked (W : in out Checkbox; On : Boolean) is
   begin
      if W.Checked /= On then
         W.Checked := On;
         W.Dirty := True;
      end if;
   end Set_Checked;

   --  Box geometry shared by both toggles: at the left edge,
   --  vertically centered; the label sits Toggle_Gap right of it.
   procedure Toggle_Metrics
     (W : Widget'Class; BX, BY, TX, TY : out U64)
   is
      LH : constant U64 := Fonts.Line_Height;
   begin
      BX := W.X + 2;
      BY := W.Y + (if W.H > Toggle_Box then (W.H - Toggle_Box) / 2
                   else 0);
      TX := BX + Toggle_Box + Toggle_Gap;
      TY := W.Y + (if W.H > LH then (W.H - LH) / 2 else 0);
   end Toggle_Metrics;

   procedure Toggle_Label
     (W : Widget'Class; C : Canvas; Txt : String; Len : Text_Len;
      Disabled : Boolean; Shift : U64)
   is
      BX, BY, TX, TY : U64;
   begin
      Toggle_Metrics (W, BX, BY, TX, TY);
      if Disabled then
         Fonts.Draw_Text (C, TX + 1, TY + 1,
                          Txt (Txt'First .. Txt'First + Len - 1),
                          Bevel_Hi);
         Fonts.Draw_Text (C, TX, TY,
                          Txt (Txt'First .. Txt'First + Len - 1),
                          Bevel_Lo);
      else
         Fonts.Draw_Text (C, TX + Shift, TY + Shift,
                          Txt (Txt'First .. Txt'First + Len - 1),
                          Text_Dark);
      end if;
   end Toggle_Label;

   procedure Draw (W : Checkbox; C : Canvas) is
      BX, BY, TX, TY : U64;
      Sh : constant U64 := (if W.Pressed then 1 else 0);
   begin
      if not Intersects (W, C) then
         return;
      end if;
      Toggle_Metrics (W, BX, BY, TX, TY);
      Paint.Fill_Rect (C, BX, BY, BX + Toggle_Box, BY + Toggle_Box,
                       (if W.Hover and then not W.Disabled
                          and then not W.Pressed
                        then Akernel_User.Theme.Face_Hi
                        else Face));
      Paint.Bevel2 (C, BX, BY, BX + Toggle_Box, BY + Toggle_Box,
                    Raised => not W.Pressed);
      if W.Checked then
         --  Embossed check (MUI "shadow" style): white copy one
         --  pixel down-right, dark stroke on top; the pair shifts
         --  together while pressed.
         for Pass in U64'(0) .. 1 loop
            declare
               Col : constant Pixel :=
                 (if Pass = 0 then Bevel_Hi else Text_Dark);
               DX  : constant U64 := Pass + Sh;  --  shadow = +1,+1
               DY  : constant U64 := Pass + Sh;
            begin
               --  Short leg down-right (3px), long leg up-right
               --  (6px); both 2px thick.
               for I in U64'(0) .. 2 loop
                  Paint.Fill_Rect
                    (C, BX + 3 + I + DX, BY + 6 + I + DY,
                     BX + 5 + I + DX, BY + 7 + I + DY, Col);
               end loop;
               for I in U64'(0) .. 5 loop
                  Paint.Fill_Rect
                    (C, BX + 6 + I + DX, BY + 7 - I + DY,
                     BX + 8 + I + DX, BY + 8 - I + DY, Col);
               end loop;
            end;
         end loop;
      end if;
      Toggle_Label (W, C, W.Txt, W.Len, W.Disabled, Sh);
   end Draw;

   --  Shared floor: box at X+2, label Toggle_Gap right of it,
   --  2px slack on the right; the taller of box/text plus 4.
   procedure Toggle_Min (Txt : String; MW, MH : out U64) is
   begin
      MW := 2 + Toggle_Box + Toggle_Gap
        + Fonts.Text_Width (Txt) + 2;
      MH := Max (Toggle_Box, Fonts.Line_Height) + 4;
   end Toggle_Min;

   procedure Min_Size (W : Checkbox; MW, MH : out U64) is
   begin
      Toggle_Min (W.Txt (1 .. W.Len), MW, MH);
   end Min_Size;

   function On_Pointer
     (W : access Checkbox; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
   begin
      if W.Disabled then
         return False;
      end if;
      case K is
         when Press =>
            if Inside (W.all, PX, PY) then
               W.Pressed := True;
               W.Dirty := True;
               return True;
            end if;
         when Release =>
            if W.Pressed then
               W.Pressed := False;
               W.Dirty := True;
               if Inside (W.all, PX, PY) then
                  W.Checked := not W.Checked;
                  if W.On_Change /= null then
                     W.On_Change (W.Checked);
                  end if;
               end if;
               return True;
            end if;
         when Move =>
            declare
               Now_In : constant Boolean := Inside (W.all, PX, PY);
            begin
               if Now_In /= W.Hover then
                  W.Hover := Now_In;
                  W.Dirty := True;
               end if;
            end;
            return W.Pressed;
      end case;
      return False;
   end On_Pointer;

   function New_Radio
     (S         : String;
      Peers     : Radio_Set_Access := null;
      Selected  : Boolean := False;
      On_Change : Toggle_Callback := null;
      Disabled  : Boolean := False) return Any_Widget
   is
      R : constant Radio_Access := new Radio;
   begin
      Set_Text (R.Txt, R.Len, S);
      R.Selected := Selected;
      R.On_Change := On_Change;
      R.Disabled := Disabled;
      if Peers /= null and then Peers.N < Max_Radio then
         Peers.N := Peers.N + 1;
         Peers.Members (Peers.N) := Any_Widget (R);
         R.Peers := Peers;
      end if;
      return Any_Widget (R);
   end New_Radio;

   procedure Set_Selected (W : in out Radio; On : Boolean) is
      Self_R : constant access Radio := W'Unchecked_Access;
      Self   : constant Any_Widget := Any_Widget (Self_R);
   begin
      if On then
         if not W.Selected then
            W.Selected := True;
            W.Dirty := True;
         end if;
         if W.Peers /= null then
            for I in 1 .. W.Peers.N loop
               declare
                  M : constant Any_Widget := W.Peers.Members (I);
               begin
                  if M /= null
                    and then M /= Self
                    and then Radio (M.all).Selected
                  then
                     Radio (M.all).Selected := False;
                     Radio (M.all).Dirty := True;
                  end if;
               end;
            end loop;
         end if;
      elsif W.Selected then
         W.Selected := False;
         W.Dirty := True;
      end if;
   end Set_Selected;

   procedure Draw (W : Radio; C : Canvas) is
      BX, BY, TX, TY : U64;
      Sh : constant U64 := (if W.Pressed then 1 else 0);
      Face_C : constant Pixel :=
        (if W.Hover and then not W.Disabled and then not W.Pressed
         then Akernel_User.Theme.Face_Hi
         else Face);
      --  Disc test on doubled coordinates: inside when
      --  (2x-13)^2 + (2y-13)^2 <= 13^2 (r = 6.5).
      DX2, DY2 : Integer;
      R2       : Integer;
      Outline  : constant Pixel :=
        (if W.Pressed then Bevel_Lo else Border);
   begin
      if not Intersects (W, C) then
         return;
      end if;
      Toggle_Metrics (W, BX, BY, TX, TY);
      for PY in U64'(0) .. Toggle_Box - 1 loop
         for PX in U64'(0) .. Toggle_Box - 1 loop
            DX2 := Integer (PX) * 2 - 13;
            DY2 := Integer (PY) * 2 - 13;
            R2  := DX2 * DX2 + DY2 * DY2;
            if R2 <= 169 then
               Paint.Fill_Rect
                 (C, BX + PX, BY + PY, BX + PX + 1, BY + PY + 1,
                  (if R2 >= 120 then Outline else Face_C));
            end if;
         end loop;
      end loop;
      if W.Selected then
         --  Solid dot, r = 2.5 on doubled coordinates (<= 5^2),
         --  shifted while pressed like the checkbox glyph.
         for PY in U64'(0) .. 5 loop
            for PX in U64'(0) .. 5 loop
               DX2 := Integer (PX) * 2 - 5;
               DY2 := Integer (PY) * 2 - 5;
               if DX2 * DX2 + DY2 * DY2 <= 25 then
                  Paint.Fill_Rect
                    (C, BX + 4 + PX + Sh, BY + 4 + PY + Sh,
                     BX + 5 + PX + Sh, BY + 5 + PY + Sh,
                     Text_Dark);
               end if;
            end loop;
         end loop;
      end if;
      Toggle_Label (W, C, W.Txt, W.Len, W.Disabled, Sh);
   end Draw;

   procedure Min_Size (W : Radio; MW, MH : out U64) is
   begin
      Toggle_Min (W.Txt (1 .. W.Len), MW, MH);
   end Min_Size;

   function On_Pointer
     (W : access Radio; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
   begin
      if W.Disabled then
         return False;
      end if;
      case K is
         when Press =>
            if Inside (W.all, PX, PY) then
               W.Pressed := True;
               W.Dirty := True;
               return True;
            end if;
         when Release =>
            if W.Pressed then
               W.Pressed := False;
               W.Dirty := True;
               if Inside (W.all, PX, PY) and then not W.Selected then
                  Set_Selected (W.all, True);
                  if W.On_Change /= null then
                     W.On_Change (True);
                  end if;
               end if;
               return True;
            end if;
         when Move =>
            declare
               Now_In : constant Boolean := Inside (W.all, PX, PY);
            begin
               if Now_In /= W.Hover then
                  W.Hover := Now_In;
                  W.Dirty := True;
               end if;
            end;
            return W.Pressed;
      end case;
      return False;
   end On_Pointer;

   --  Scrollbar

   --  M86d (Xen): BOTH arrow boxes stack at the bottom of the
   --  bar (up over down), the MUI signature layout.

   function Track_B (W : Scrollbar) return U64 is
     --  Bottom of the knob travel region, with an underflow
     --  guard for degenerate bars shorter than the arrow pair.
     (if W.H > 2 * Arrow + 2
      then W.Y + W.H - 2 * Arrow
      else W.Y + 2);

   --  M87c: horizontal twins — the arrow cluster sits at the
   --  RIGHT (left-arrow box over... beside the right one).
   function Track_R (W : Scrollbar) return U64 is
     (if W.W > 2 * Arrow + 2
      then W.X + W.W - 2 * Arrow
      else W.X + 2);

   function New_Scrollbar
     (On_Change : Bar_Callback := null;
      Dir       : Direction := Vertical;
      Ctx       : Any_Widget := null) return Any_Widget
   is
      S : constant Scrollbar_Access := new Scrollbar;
   begin
      S.On_Change := On_Change;
      S.Dir := Dir;
      S.Ctx := Ctx;
      return Any_Widget (S);
   end New_Scrollbar;

   procedure Clamp_Pos (W : in out Scrollbar) is
   begin
      if W.Pos < W.Min then
         W.Pos := W.Min;
      elsif W.Pos > W.Max then
         W.Pos := W.Max;
      end if;
   end Clamp_Pos;

   procedure Set_Range
     (W : in out Scrollbar; Min, Max, Visible : U64)
   is
   begin
      --  No-op when nothing changed: apps re-sync on every
      --  content change (M87c Text_Edit hook) and an
      --  unconditional Dirty would redraw the bar per key.
      if Min = W.Min and then Max = W.Max
        and then U64'Max (Visible, 1) = W.Visible
      then
         return;
      end if;
      W.Min := Min;
      W.Max := Max;
      W.Visible := U64'Max (Visible, 1);
      Clamp_Pos (W);
      W.Dirty := True;
   end Set_Range;

   procedure Set_Step (W : in out Scrollbar; S : U64) is
   begin
      W.Step := U64'Max (S, 1);
   end Set_Step;

   procedure Set_Pos (W : in out Scrollbar; P : U64) is
   begin
      if P /= W.Pos then
         W.Pos := P;
         Clamp_Pos (W);
         W.Dirty := True;
      end if;
   end Set_Pos;

   procedure User_Move (W : access Scrollbar; P : U64) is
   begin
      if P /= W.Pos then
         W.Pos := P;
         Clamp_Pos (W.all);
         W.Dirty := True;
         if W.On_Change /= null then
            W.On_Change (Any_Widget (W), W.Pos);
         end if;
      end if;
   end User_Move;

   --  Down-step with a pre-clamp: Pos - By is U64 and wraps past
   --  Min, and Clamp_Pos would read the wrap as "past Max" (the
   --  up arrow at the top jumped to the BOTTOM).
   procedure Step_Down (W : access Scrollbar; By : U64) is
   begin
      User_Move
        (W, (if W.Pos > W.Min + By then W.Pos - By else W.Min));
   end Step_Down;

   --  Knob geometry: track between the arrow boxes; knob height
   --  proportional to Visible / (Max - Min + Visible); knob top
   --  linear in Pos.
   procedure Knob_Rect
     (W : Scrollbar; Top, Bottom : out U64)
   is
      Track_T : constant U64 := W.Y + 2;
      Track_Bn : constant U64 := Track_B (W);
      Track_H : constant U64 := Track_Bn - Track_T;
      Total   : constant U64 := W.Max - W.Min + W.Visible;
      Knob_H  : constant U64 :=
        U64'Max (12, Track_H * W.Visible / U64'Max (Total, 1));
      Travel  : constant U64 := Track_H - U64'Min (Knob_H, Track_H);
   begin
      if Track_H <= 12 then
         Top := Track_T;
         Bottom := Track_T;
         return;
      end if;
      Top := Track_T +
        (if W.Max > W.Min
         then Travel * (W.Pos - W.Min) / (W.Max - W.Min)
         else 0);
      Bottom := Top + U64'Min (Knob_H, Track_H);
   end Knob_Rect;

   --  Horizontal knob geometry, mirrored across the diagonal.
   procedure Knob_Rect_H
     (W : Scrollbar; Left, Right : out U64)
   is
      Track_L : constant U64 := W.X + 2;
      Track_Rn : constant U64 := Track_R (W);
      Track_W : constant U64 := Track_Rn - Track_L;
      Total   : constant U64 := W.Max - W.Min + W.Visible;
      Knob_W  : constant U64 :=
        U64'Max (12, Track_W * W.Visible / U64'Max (Total, 1));
      Travel  : constant U64 := Track_W - U64'Min (Knob_W, Track_W);
   begin
      if Track_W <= 12 then
         Left := Track_L;
         Right := Track_L;
         return;
      end if;
      Left := Track_L +
        (if W.Max > W.Min
         then Travel * (W.Pos - W.Min) / (W.Max - W.Min)
         else 0);
      Right := Left + U64'Min (Knob_W, Track_W);
   end Knob_Rect_H;

   procedure Draw (W : Scrollbar; C : Canvas) is
      KT, KB : U64;

      procedure Frame_Flat (X0, Y0, X1, Y1 : U64) is
      begin
         --  Xen's flat frame: black outline + white inner line.
         Paint.Fill_Rect (C, X0, Y0, X1, Y0 + 1, Border);
         Paint.Fill_Rect (C, X0, Y1 - 1, X1, Y1, Border);
         Paint.Fill_Rect (C, X0, Y0, X0 + 1, Y1, Border);
         Paint.Fill_Rect (C, X1 - 1, Y0, X1, Y1, Border);
         Paint.Fill_Rect (C, X0 + 1, Y0 + 1, X1 - 1, Y0 + 2,
                          Bevel_Hi);
         Paint.Fill_Rect (C, X0 + 1, Y1 - 2, X1 - 1, Y1 - 1,
                          Bevel_Hi);
         Paint.Fill_Rect (C, X0 + 1, Y0 + 1, X0 + 2, Y1 - 1,
                          Bevel_Hi);
         Paint.Fill_Rect (C, X1 - 2, Y0 + 1, X1 - 1, Y1 - 1,
                          Bevel_Hi);
      end Frame_Flat;

      procedure Fill_Stripes (X0, Y0, X1, Y1 : U64) is
         --  The xenbar look: vertical 1px stripes alternating
         --  window gray / gadget gray.
         X : U64 := X0;
      begin
         while X < X1 loop
            Paint.Fill_Rect (C, X, Y0, X + 1, Y1,
                             (if (X - X0) mod 2 = 0
                              then Win_Face else Face));
            X := X + 1;
         end loop;
      end Fill_Stripes;

      procedure Fill_HStripes (X0, Y0, X1, Y1 : U64) is
         --  Horizontal-bar version: 1px stripes by row.
         Y : U64 := Y0;
      begin
         while Y < Y1 loop
            Paint.Fill_Rect (C, X0, Y, X1, Y + 1,
                             (if (Y - Y0) mod 2 = 0
                              then Win_Face else Face));
            Y := Y + 1;
         end loop;
      end Fill_HStripes;

      procedure Chevron_LR (X0, CY : U64; Left : Boolean; Sh : U64) is
         --  Horizontal mirror of Chevron: < or > pointing glyph,
         --  white shadow ABOVE (mirrored from "to the left").
         P : U64;
      begin
         for I in U64'(0) .. 3 loop
            P := (if Left then X0 + I else X0 + 3 - I);
            Paint.Fill_Rect (C, P + Sh, CY - I - 1 + Sh,
                             P + 1 + Sh, CY - I + Sh, Bevel_Hi);
            Paint.Fill_Rect (C, P + Sh, CY + I - 1 + Sh,
                             P + 1 + Sh, CY + I + Sh, Bevel_Hi);
            Paint.Fill_Rect (C, P + Sh, CY - I + Sh,
                             P + 1 + Sh, CY - I + 1 + Sh,
                             Text_Dark);
            Paint.Fill_Rect (C, P + Sh, CY + I + Sh,
                             P + 1 + Sh, CY + I + 1 + Sh,
                             Text_Dark);
         end loop;
      end Chevron_LR;

      procedure Chevron (CX, Y0 : U64; Up : Boolean; Sh : U64) is
         --  Thin single-pixel chevron, white shadow to the left
         --  (MUI "shadow" style); Sh shifts when pressed.
         P : U64;
      begin
         for I in U64'(0) .. 3 loop
            P := (if Up then Y0 + I else Y0 + 3 - I);
            Paint.Fill_Rect (C, CX - I - 1 + Sh, P + Sh,
                             CX - I + Sh, P + 1 + Sh, Bevel_Hi);
            Paint.Fill_Rect (C, CX + I - 1 + Sh, P + Sh,
                             CX + I + Sh, P + 1 + Sh, Bevel_Hi);
            Paint.Fill_Rect (C, CX - I + Sh, P + Sh,
                             CX - I + 1 + Sh, P + 1 + Sh,
                             Text_Dark);
            Paint.Fill_Rect (C, CX + I + Sh, P + Sh,
                             CX + I + 1 + Sh, P + 1 + Sh,
                             Text_Dark);
         end loop;
      end Chevron;

      CX : constant U64 := W.X + W.W / 2;
      SU : constant U64 := (if W.Arrow_Dn = -1 then 1 else 0);
      SD : constant U64 := (if W.Arrow_Dn = 1 then 1 else 0);
   begin
      if not Intersects (W, C) then
         return;
      end if;
      if W.Dir = Vertical
        and then (W.H <= 2 * Arrow + 2 or else W.W <= 6)
      then
         --  Degenerate bar: plain face, nothing fits.
         Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Face);
         return;
      end if;
      if W.Dir = Horizontal
        and then (W.W <= 2 * Arrow + 2 or else W.H <= 6)
      then
         Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Face);
         return;
      end if;

      if W.Dir = Horizontal then
         --  M87c: mirrored across the diagonal — cluster at the
         --  RIGHT, stripes by row, < > chevrons.
         Fill_HStripes (W.X + 2, W.Y + 2, Track_R (W),
                        W.Y + W.H - 2);
         Paint.Fill_Rect (C, Track_R (W), W.Y + 2,
                          W.X + W.W - 2, W.Y + W.H - 2, Face);
         Frame_Flat (W.X, W.Y, W.X + W.W, W.Y + W.H);

         Knob_Rect_H (W, KT, KB);  --  KT/KB are LEFT/RIGHT here
         if KB > KT then
            Fill_HStripes (KT + 2, W.Y + 2, KB - 2, W.Y + W.H - 2);
            Frame_Flat (KT, W.Y + 1, KB, W.Y + W.H - 1);
         end if;

         Paint.Fill_Rect
           (C, W.X + W.W - 2 * Arrow + 1, W.Y + 2,
            W.X + W.W - Arrow - 1, W.Y + W.H - 2, Face);
         Frame_Flat (W.X + W.W - 2 * Arrow, W.Y + 1,
                     W.X + W.W - Arrow, W.Y + W.H - 1);
         if W.Arrow_Dn = -1 then
            Paint.Bevel2
              (C, W.X + W.W - 2 * Arrow + 1, W.Y + 2,
               W.X + W.W - Arrow - 1, W.Y + W.H - 2,
               Raised => False);
         end if;
         Paint.Fill_Rect
           (C, W.X + W.W - Arrow + 1, W.Y + 2,
            W.X + W.W - 2, W.Y + W.H - 2, Face);
         Frame_Flat (W.X + W.W - Arrow, W.Y + 1,
                     W.X + W.W - 1, W.Y + W.H - 1);
         if W.Arrow_Dn = 1 then
            Paint.Bevel2
              (C, W.X + W.W - Arrow + 1, W.Y + 2,
               W.X + W.W - 2, W.Y + W.H - 2,
               Raised => False);
         end if;
         Chevron_LR (W.X + W.W - 2 * Arrow + 6, W.Y + W.H / 2,
                     True, SU);
         Chevron_LR (W.X + W.W - Arrow + 6, W.Y + W.H / 2,
                     False, SD);
         return;
      end if;

      --  Track: stripes over the knob travel region; flat frame
      --  around the whole bar.
      Fill_Stripes (W.X + 2, W.Y + 2, W.X + W.W - 2,
                    Track_B (W));
      Paint.Fill_Rect (C, W.X + 2, Track_B (W), W.X + W.W - 2,
                       W.Y + W.H - 2, Face);
      Frame_Flat (W.X, W.Y, W.X + W.W, W.Y + W.H);

      --  Knob: framed striped box; sunken frame while dragged.
      Knob_Rect (W, KT, KB);
      if KB > KT then
         Fill_Stripes (W.X + 2, KT + 2, W.X + W.W - 2, KB - 2);
         Frame_Flat (W.X + 1, KT, W.X + W.W - 1, KB);
      end if;

      --  Arrow boxes, both at the bottom: up over down.  Held
      --  arrow draws sunken with the glyph shifted (M86c).
      Paint.Fill_Rect (C, W.X + 2, W.Y + W.H - 2 * Arrow + 1,
                       W.X + W.W - 2, W.Y + W.H - Arrow - 1, Face);
      Frame_Flat (W.X + 1, W.Y + W.H - 2 * Arrow,
                  W.X + W.W - 1, W.Y + W.H - Arrow);
      if W.Arrow_Dn = -1 then
         Paint.Bevel2 (C, W.X + 2, W.Y + W.H - 2 * Arrow + 1,
                       W.X + W.W - 2, W.Y + W.H - Arrow - 1,
                       Raised => False);
      end if;
      Paint.Fill_Rect (C, W.X + 2, W.Y + W.H - Arrow + 1,
                       W.X + W.W - 2, W.Y + W.H - 2, Face);
      Frame_Flat (W.X + 1, W.Y + W.H - Arrow,
                  W.X + W.W - 1, W.Y + W.H);
      if W.Arrow_Dn = 1 then
         Paint.Bevel2 (C, W.X + 2, W.Y + W.H - Arrow + 1,
                       W.X + W.W - 2, W.Y + W.H - 2,
                       Raised => False);
      end if;
      Chevron (CX, W.Y + W.H - 2 * Arrow + 6, True, SU);
      Chevron (CX, W.Y + W.H - Arrow + 6, False, SD);
   end Draw;

   procedure Min_Size (W : Scrollbar; MW, MH : out U64) is
   begin
      --  Arrow in the cross axis; the arrow cluster (two boxes)
      --  plus a minimal knob track in the layout axis.
      if W.Dir = Vertical then
         MW := Arrow;
         MH := 3 * Arrow;
      else
         MW := 3 * Arrow;
         MH := Arrow;
      end if;
   end Min_Size;

   function On_Pointer
     (W : access Scrollbar; K : Pointer_Kind; PX, PY : U64)
      return Boolean
    is
       KT, KB : U64;
       Track_T  : constant U64 := W.Y + 2;
       Track_Bt : constant U64 := Track_B (W.all);
       Track_L  : constant U64 := W.X + 2;
       Track_Rt : constant U64 := Track_R (W.all);
    begin
       if W.Dir = Horizontal then
          --  M87c mirror: cluster at the right, PX-driven.
          if W.W <= 2 * Arrow + 2 then
             return False;
          end if;
          case K is
             when Press =>
                if not Inside (W.all, PX, PY) then
                   return False;
                end if;
                Knob_Rect_H (W.all, KT, KB);  --  LEFT/RIGHT here
                if PX >= W.X + W.W - Arrow then
                   W.Arrow_Dn := 1;
                   W.Dirty := True;
                   User_Move (W, W.Pos + W.Step);
                elsif PX >= W.X + W.W - 2 * Arrow then
                   W.Arrow_Dn := -1;
                   W.Dirty := True;
                   Step_Down (W, W.Step);
                elsif PX >= KT and then PX < KB then
                   W.Dragging := True;
                   W.Dirty := True;
                   W.Grab_DY := PX - KT;  --  grab offset in X
                elsif PX < KT then
                   Step_Down (W, W.Visible);
                else
                   User_Move (W, W.Pos + W.Visible);
                end if;
                return True;
             when Move =>
                if W.Dragging then
                   Knob_Rect_H (W.all, KT, KB);
                   declare
                      Knob_W : constant U64 := KB - KT;
                      Travel : constant U64 :=
                        Track_Rt - Track_L - Knob_W;
                      Rel : constant U64 :=
                        (if PX > Track_L + W.Grab_DY
                         then PX - Track_L - W.Grab_DY else 0);
                   begin
                      User_Move (W, W.Min +
                        (if Travel > 0
                         then (W.Max - W.Min) * Rel / Travel
                         else 0));
                   end;
                   return True;
                end if;
             when Release =>
                if W.Arrow_Dn /= 0 then
                   W.Arrow_Dn := 0;
                   W.Dirty := True;
                   return True;
                end if;
                if W.Dragging then
                   W.Dragging := False;
                   W.Dirty := True;
                   return True;
                end if;
          end case;
          return False;
       end if;
       if W.H <= 2 * Arrow + 2 then
          return False;  --  degenerate bar, nothing to hit
       end if;
       case K is
          when Press =>
             if not Inside (W.all, PX, PY) then
                return False;
             end if;
             Knob_Rect (W.all, KT, KB);
             --  MUI layout: both arrow boxes at the bottom —
             --  up above down; track press pages (M86d).
             if PY >= W.Y + W.H - Arrow then
                W.Arrow_Dn := 1;
                W.Dirty := True;
                User_Move (W, W.Pos + W.Step);
             elsif PY >= W.Y + W.H - 2 * Arrow then
                W.Arrow_Dn := -1;
                W.Dirty := True;
                Step_Down (W, W.Step);
             elsif PY >= KT and then PY < KB then
               W.Dragging := True;
               W.Dirty := True;
               W.Grab_DY := PY - KT;
            elsif PY < KT then
               Step_Down (W, W.Visible);
            else
               User_Move (W, W.Pos + W.Visible);
            end if;
            return True;
         when Move =>
            if W.Dragging then
               Knob_Rect (W.all, KT, KB);
               declare
                  Knob_H : constant U64 := KB - KT;
                   Travel : constant U64 :=
                     Track_Bt - Track_T - Knob_H;
                  Rel : constant U64 :=
                    (if PY > Track_T + W.Grab_DY
                     then PY - Track_T - W.Grab_DY else 0);
               begin
                  User_Move (W, W.Min +
                    (if Travel > 0
                     then (W.Max - W.Min) * Rel / Travel
                     else 0));
               end;
               return True;
            end if;
         when Release =>
            if W.Arrow_Dn /= 0 then
               W.Arrow_Dn := 0;
               W.Dirty := True;
               return True;
            end if;
            if W.Dragging then
               W.Dragging := False;
               W.Dirty := True;
               return True;
            end if;
      end case;
      return False;
   end On_Pointer;

   --  Slider

   Slider_Knob : constant U64 := 12;  --  knob width

   function New_Slider
     (Min       : U64 := 0;
      Max       : U64 := 100;
      On_Change : Change_Callback := null) return Any_Widget
   is
      S : constant Slider_Access := new Slider;
   begin
      S.Min := Min;
      S.Max := Max;
      S.Pos := Min;
      S.On_Change := On_Change;
      return Any_Widget (S);
   end New_Slider;

   procedure Clamp_Pos (W : in out Slider) is
   begin
      if W.Pos < W.Min then
         W.Pos := W.Min;
      elsif W.Pos > W.Max then
         W.Pos := W.Max;
      end if;
   end Clamp_Pos;

   procedure Set_Range (W : in out Slider; Min, Max : U64) is
   begin
      W.Min := Min;
      W.Max := Max;
      Clamp_Pos (W);
      W.Dirty := True;
   end Set_Range;

   procedure Set_Pos (W : in out Slider; P : U64) is
   begin
      if P /= W.Pos then
         W.Pos := P;
         Clamp_Pos (W);
         W.Dirty := True;
      end if;
   end Set_Pos;

   procedure User_Move (W : access Slider; P : U64) is
   begin
      if P /= W.Pos then
         W.Pos := P;
         Clamp_Pos (W.all);
         W.Dirty := True;
         if W.On_Change /= null then
            W.On_Change (W.Pos);
         end if;
      end if;
   end User_Move;

   --  Knob left edge for the current Pos: linear over the track
   --  span (widget width minus the knob).
   function Knob_X (W : Slider) return U64 is
      Span  : constant U64 :=
        (if W.W > Slider_Knob then W.W - Slider_Knob else 0);
      Rng   : constant U64 :=
        (if W.Max > W.Min then W.Max - W.Min else 0);
   begin
      if Span = 0 or else Rng = 0 then
         return W.X;
      end if;
      return W.X + Span * (W.Pos - W.Min) / Rng;
   end Knob_X;

   procedure Draw (W : Slider; C : Canvas) is
      KX   : constant U64 := Knob_X (W);
      Track_T : constant U64 :=
        W.Y + (if W.H > 6 then (W.H - 6) / 2 else 0);
      Sh   : constant U64 := (if W.Dragging then 1 else 0);
      GX   : U64;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      --  Sunken channel across the middle.
      Paint.Fill_Rect (C, W.X, Track_T, W.X + W.W, Track_T + 6, Pane);
      Paint.Bevel2 (C, W.X, Track_T, W.X + W.W, Track_T + 6,
                    Raised => False);
      --  Knob: hover brightens, dragging sinks + shifts the grips.
      Paint.Fill_Rect (C, KX, W.Y, KX + Slider_Knob, W.Y + W.H,
                       (if W.Hover and then not W.Dragging
                        then Akernel_User.Theme.Face_Hi else Face));
      Paint.Bevel2 (C, KX, W.Y, KX + Slider_Knob, W.Y + W.H,
                    Raised => not W.Dragging);
      for I in U64 range 0 .. 1 loop
         GX := KX + Slider_Knob / 2 - 2 + I * 3 + Sh;
         Paint.Fill_Rect
           (C, GX, W.Y + 3 + Sh, GX + 1, W.Y + W.H - 3 + Sh,
            Bevel_Lo);
      end loop;
   end Draw;

   procedure Min_Size (W : Slider; MW, MH : out U64) is
      pragma Unreferenced (W);
   begin
      MW := 64;
      MH := 14;  --  12px knob + frame slack
   end Min_Size;

   function On_Pointer
     (W : access Slider; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
      Span  : constant U64 :=
        (if W.W > Slider_Knob then W.W - Slider_Knob else 0);
      Rng   : constant U64 :=
        (if W.Max > W.Min then W.Max - W.Min else 0);
      Page  : constant U64 := U64'Max (Rng / 10, 1);
      KX    : constant U64 := Knob_X (W.all);
   begin
      case K is
         when Press =>
            if not Inside (W.all, PX, PY) then
               return False;
            end if;
            if PX >= KX and then PX < KX + Slider_Knob then
               W.Dragging := True;
               W.Grab_DX := PX - KX;
               W.Dirty := True;
            elsif PX < KX then
               --  Guarded step: U64 wraps on Pos - Page, and the
               --  clamp would read the wrap as "past Max".
               User_Move
                 (W, (if W.Pos > W.Min + Page
                      then W.Pos - Page else W.Min));
            else
               User_Move (W, W.Pos + Page);
            end if;
            return True;
         when Move =>
            if W.Dragging then
               declare
                  Rel : constant U64 :=
                    (if PX > W.X + W.Grab_DX
                     then PX - W.X - W.Grab_DX else 0);
               begin
                  User_Move
                    (W, W.Min +
                     (if Span > 0 then Rng * Rel / Span else 0));
               end;
               return True;
            end if;
            --  Hover tracking, same as Button: never consume an
            --  unpressed move so siblings clear their own hover.
            declare
               Now_In : constant Boolean := Inside (W.all, PX, PY);
            begin
               if Now_In /= W.Hover then
                  W.Hover := Now_In;
                  W.Dirty := True;
               end if;
            end;
            return False;
         when Release =>
            if W.Dragging then
               W.Dragging := False;
               W.Dirty := True;
               return True;
            end if;
      end case;
      return False;
   end On_Pointer;

   --  Group

   function New_Group
     (Dir : Direction; Title : String := ""; Inset : Boolean := False)
      return Any_Widget
   is
      G : constant Group_Access := new Group;
   begin
      G.Dir := Dir;
      G.Inset := Inset;
      G.Title_Len := Natural'Min (Title'Length, G.Title'Length);
      G.Title (1 .. G.Title_Len) :=
        Title (Title'First .. Title'First + G.Title_Len - 1);
      return Any_Widget (G);
   end New_Group;

   procedure Add (G : in out Group; Child : Any_Widget; Weight : U64 := 1) is
   begin
      if G.N < Max_Children then
         G.N := G.N + 1;
         G.Kids (G.N) := Child;
         G.Wts (G.N) := (if Weight = 0 then 1 else Weight);
      end if;
   end Add;

   procedure Min_Size (W : Group; MW, MH : out U64) is
      Margin  : constant U64 := 8;
      Spacing : constant U64 := 8;
      Top     : constant U64 := (if W.Title_Len > 0 then 16 else 8);
      KW, KH  : U64;
      CW      : U64 := 0;  --  kids in the cross direction: max
      CS      : U64 := 0;  --  kids in the layout direction: sum
   begin
      for I in 1 .. W.N loop
         W.Kids (I).Min_Size (KW, KH);
         if W.Dir = Vertical then
            CW := Max (CW, KW);
            CS := CS + KH;
         else
            CW := Max (CW, KH);
            CS := CS + KW;
         end if;
      end loop;
      if W.N > 0 then
         CS := CS + Spacing * U64 (W.N - 1);
      end if;
      --  The title sits in a 6px-gapped band on the top edge;
      --  keep it inside the frame too (width-only, either
      --  direction).
      MW := Margin * 2 + (if W.Dir = Vertical then CW else CS);
      if W.Title_Len > 0 then
         MW := Max (MW, Margin * 2 + Fonts.Text_Width
                      (W.Title (1 .. W.Title_Len)) + 28);
      end if;
      MH := Top + Margin + (if W.Dir = Vertical then CS else CW);
   end Min_Size;

   procedure Layout (W : in out Group) is
      Margin  : constant U64 := 8;
      Spacing : constant U64 := 8;
      Top     : constant U64 := (if W.Title_Len > 0 then 16 else 8);
      IX0     : constant U64 := W.X + Margin;
      IY0     : constant U64 := W.Y + Top;
      IX1     : constant U64 := W.X + W.W - Margin;
      IY1     : constant U64 := W.Y + W.H - Margin;
      Mins    : array (1 .. Max_Children) of U64 := (others => 0);
      KW, KH  : U64;
      Avail   : U64;
      Extra   : U64;
      Pos     : U64;
      Fixed   : Natural := 0;  --  scrollbars pin to Arrow wide
      Total_W : U64 := 0;
      Base    : U64 := 0;
      Cum     : U64;
      Prev    : U64;

      --  M87c: scrollbars pin to Arrow in the CROSS axis of the
      --  group that holds them (vertical bars in horizontal
      --  groups, horizontal bars in vertical groups).
      function Pinned_V (K : Any_Widget) return Boolean is
        (K.all in Scrollbar
         and then Scrollbar (K.all).Dir = Vertical);
      function Pinned_H (K : Any_Widget) return Boolean is
        (K.all in Scrollbar
         and then Scrollbar (K.all).Dir = Horizontal);
   begin
      if W.N = 0 then
         return;
      end if;
      --  M86g: content minimums come FIRST — every child gets at
      --  least its Min_Size in the layout direction; only the
      --  remainder splits by weight (cumulative fractions, so
      --  rounding never drifts). Mins past the inner extent just
      --  overflow and the canvas clip takes it — a huge user
      --  font degrades to clipping, never to a negative size.
      if W.Dir = Vertical then
         for I in 1 .. W.N loop
            if Pinned_H (W.Kids (I)) then
               Mins (I) := Arrow;  --  pinned, no weight share
            else
               W.Kids (I).Min_Size (KW, KH);
               Mins (I) := KH;
               Total_W := Total_W + W.Wts (I);
            end if;
            Base := Base + Mins (I);
         end loop;
         Avail := IY1 - IY0 - Spacing * U64 (W.N - 1);
         Extra := (if Avail > Base then Avail - Base else 0);
         Pos   := IY0;
         Cum   := 0;
         for I in 1 .. W.N loop
            W.Kids (I).Y := Pos;
            if Pinned_H (W.Kids (I)) then
               W.Kids (I).X := IX0;
               W.Kids (I).W := IX1 - IX0;
               W.Kids (I).H := Mins (I);
            else
               Prev := Cum;
               Cum  := Cum + W.Wts (I);
               W.Kids (I).H := Mins (I)
                 + (if Total_W > 0
                    then Extra * Cum / Total_W
                      - Extra * Prev / Total_W
                    else 0);
               if Pinned_V (W.Kids (I)) then
                  W.Kids (I).W := U64'Min (Arrow, IX1 - IX0);
                  W.Kids (I).X :=
                    IX0 + (IX1 - IX0 - W.Kids (I).W) / 2;
               else
                  W.Kids (I).X := IX0;
                  W.Kids (I).W := IX1 - IX0;
               end if;
            end if;
            Pos := Pos + W.Kids (I).H + Spacing;
         end loop;
      else
         for I in 1 .. W.N loop
            if Pinned_V (W.Kids (I)) then
               Fixed := Fixed + 1;
            else
               W.Kids (I).Min_Size (Mins (I), KH);
               Base := Base + Mins (I);
               Total_W := Total_W + W.Wts (I);
            end if;
         end loop;
         Avail := IX1 - IX0 - Spacing * U64 (W.N - 1)
           - U64 (Fixed) * Arrow;
         Extra := (if Avail > Base then Avail - Base else 0);
         Pos := IX0;
         Cum := 0;
         for I in 1 .. W.N loop
            if Pinned_V (W.Kids (I)) then
               W.Kids (I).Y := IY0;
               W.Kids (I).H := IY1 - IY0;
               W.Kids (I).X := Pos;
               W.Kids (I).W := Arrow;
               Pos := Pos + Arrow + Spacing;
            else
               Prev := Cum;
               Cum  := Cum + W.Wts (I);
               W.Kids (I).X := Pos;
               W.Kids (I).W := Mins (I)
                 + (if Total_W > 0
                    then Extra * Cum / Total_W
                      - Extra * Prev / Total_W
                    else 0);
               if Pinned_H (W.Kids (I)) then
                  W.Kids (I).H := U64'Min (Arrow, IY1 - IY0);
                  W.Kids (I).Y :=
                    IY0 + (IY1 - IY0 - W.Kids (I).H) / 2;
               else
                  W.Kids (I).Y := IY0;
                  W.Kids (I).H := IY1 - IY0;
               end if;
               Pos := Pos + W.Kids (I).W + Spacing;
            end if;
         end loop;
      end if;
      for I in 1 .. W.N loop
         W.Kids (I).Layout;
      end loop;
   end Layout;

   procedure Draw (W : Group; C : Canvas) is
   begin
      if not Intersects (W, C) then
         return;
      end if;
      if W.Inset then
         Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);
         Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                      Raised => False);
      elsif W.Title_Len > 0 then
         Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H);
         declare
            TW : constant U64 :=
              Fonts.Text_Width (W.Title (1 .. W.Title_Len));
            TX : constant U64 :=
              W.X + (if W.W > TW + 16 then (W.W - TW) / 2 else 8);
            --  Root groups sit at Y=0: never wrap the title band
            --  negative (the tdemo CONSTRAINT_ERROR).
            TY : constant U64 := (if W.Y >= 2 then W.Y - 2 else 0);
         begin
            --  Window-bg band breaks the frame behind the title.
            Paint.Fill_Rect (C, TX - 6, W.Y, TX + TW + 6,
                             W.Y + Fonts.Line_Height, Win_Face);
            Fonts.Draw_Text
              (C, TX, TY, W.Title (1 .. W.Title_Len), Text_Dark);
         end;
      end if;
      for I in 1 .. W.N loop
         W.Kids (I).Draw (C);
      end loop;
   end Draw;

   function On_Pointer
     (W : access Group; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
   begin
      --  Reverse order: later children draw on top.
      for I in reverse 1 .. W.N loop
         if Inside (W.Kids (I).all, PX, PY)
           and then W.Kids (I).On_Pointer (K, PX, PY)
         then
            return True;
         end if;
      end loop;
      --  Release must reach a pressed child even when the
      --  pointer has slid off it; Move must ALSO reach children
      --  the pointer is not over, so hover states clear (M86c —
      --  including the leave-window marker one pixel past the
      --  pane's bottom-right corner).
      if K = Release or else K = Move then
         for I in 1 .. W.N loop
            if W.Kids (I).On_Pointer (K, PX, PY) then
               return True;
            end if;
         end loop;
      end if;
      return False;
   end On_Pointer;

   function On_Key (W : access Group; Code : U64) return Boolean is
   begin
      --  Later-added children get first crack: a focusable
      --  gadget added after a list steals editing keys only
      --  while focused (Input gates on Focused), and key
      --  priority never overlaps visually (layout has no
      --  z-order).
      for I in reverse 1 .. W.N loop
         if W.Kids (I).On_Key (Code) then
            return True;
         end if;
      end loop;
      return False;
   end On_Key;

   function Dirty_Union
     (W : Group; X0, Y0, X1, Y1 : out U64) return Boolean
   is
      Any    : Boolean := False;
      Found  : Boolean;
      KX0, KY0, KX1, KY1 : U64;
   begin
      X0 := 0;  Y0 := 0;  X1 := 0;  Y1 := 0;
      if W.Dirty then
         X0 := W.X;  Y0 := W.Y;  X1 := W.X + W.W;  Y1 := W.Y + W.H;
         Any := True;
      end if;
      for I in 1 .. W.N loop
         Found := W.Kids (I).Dirty_Union (KX0, KY0, KX1, KY1);
         if Found then
            if Any then
               X0 := Min (X0, KX0);  Y0 := Min (Y0, KY0);
               X1 := Max (X1, KX1);  Y1 := Max (Y1, KY1);
            else
               X0 := KX0;  Y0 := KY0;  X1 := KX1;  Y1 := KY1;
            end if;
            Any := True;
         end if;
      end loop;
       return Any;
    end Dirty_Union;

    procedure Dirty_List
      (W        : Group;
       Rects    : in out Rect_Array;
       N        : in out Natural;
       Overflow : in out Boolean) is
    begin
       if W.Dirty then
          --  A dirty group redraws its whole extent; the kids sit
          --  inside it, so their rects would only merge away.
          Add_Rect (Rects, N, Overflow, W.X, W.Y, W.X + W.W,
                    W.Y + W.H);
          return;
       end if;
       for I in 1 .. W.N loop
          W.Kids (I).Dirty_List (Rects, N, Overflow);
       end loop;
    end Dirty_List;

   procedure Clear_Dirty (W : in out Group) is
   begin
      W.Dirty := False;
      for I in 1 .. W.N loop
         W.Kids (I).Clear_Dirty;
      end loop;
   end Clear_Dirty;

   --  Tabs (M87e)

   function Strip_H return U64 is (Fonts.Line_Height + 8);

   function Tab_W (W : Tabs; I : Positive) return U64 is
     (Fonts.Text_Width (W.Labels (I).Buf (1 .. W.Labels (I).Len))
      + 16);

   --  Left edge of tab I (contiguous tabs from X + 2).
   function Tab_X0 (W : Tabs; I : Positive) return U64 is
      X : U64 := W.X + 2;
   begin
      for J in 1 .. I - 1 loop
         X := X + Tab_W (W, J);
      end loop;
      return X;
   end Tab_X0;

   --  Tab under PX, 0 when past the last one.
   function Tab_At (W : Tabs; PX : U64) return Natural is
      X : U64 := W.X + 2;
   begin
      for I in 1 .. W.N loop
         if PX >= X and then PX < X + Tab_W (W, I) then
            return I;
         end if;
         X := X + Tab_W (W, I);
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
         TW := TW + Tab_W (W, I);
      end loop;
      MW := Max (PW + 4, TW + 2);
      MH := Strip_H + PH + 4;
   end Min_Size;

   procedure Draw (W : Tabs; C : Canvas) is
      LH : constant U64 := Fonts.Line_Height;
      PY : constant U64 := W.Y + Strip_H;
      TX : U64;
      TW : U64;
      LW : U64;
      LX : U64;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      --  Page: Face interior + raised frame whose top edge the
      --  strip sits on.
      Paint.Fill_Rect (C, W.X, PY, W.X + W.W, W.Y + W.H, Face);
      Paint.Bevel2 (C, W.X, PY, W.X + W.W, W.Y + W.H);
      --  Inactive tabs first: Win_Face buttons on the frame
      --  edge (hover brightens, a held press sinks + shifts).
      TX := W.X + 2;
      for I in 1 .. W.N loop
         TW := Tab_W (W, I);
         if I /= W.Sel then
            Paint.Fill_Rect
              (C, TX, W.Y, TX + TW, PY,
               (if I = W.Hover_Tab and then I /= W.Press_Tab
                then Akernel_User.Theme.Face_Hi else Win_Face));
            Paint.Bevel2 (C, TX, W.Y, TX + TW, PY,
                         Raised => I /= W.Press_Tab);
            LW := Fonts.Text_Width
              (W.Labels (I).Buf (1 .. W.Labels (I).Len));
            LX := TX + (if TW > LW then (TW - LW) / 2 else 1);
            Fonts.Draw_Text
              (C, LX + (if I = W.Press_Tab then 1 else 0),
               W.Y + 4 + (if I = W.Press_Tab then 1 else 0),
               W.Labels (I).Buf (1 .. W.Labels (I).Len),
               Text_Dark);
         end if;
         TX := TX + TW;
      end loop;
      --  Active tab LAST: Face fill covers the frame's top
      --  bevel lines in its span (open bottom = merged into
      --  the page), bevel lines on top/left/right only.
      if W.Sel >= 1 and then W.Sel <= W.N then
         TX := Tab_X0 (W, W.Sel);
         TW := Tab_W (W, W.Sel);
         Paint.Fill_Rect (C, TX, W.Y, TX + TW, PY + 2, Face);
         Paint.Fill_Rect (C, TX, W.Y, TX + TW, W.Y + 1, Border);
         Paint.Fill_Rect (C, TX, W.Y, TX + 1, PY + 2, Border);
         Paint.Fill_Rect
           (C, TX + TW - 1, W.Y, TX + TW, PY + 2, Border);
         Paint.Fill_Rect
           (C, TX + 1, W.Y + 1, TX + TW - 1, W.Y + 2, Bevel_Hi);
         Paint.Fill_Rect (C, TX + 1, W.Y + 1, TX + 2, PY + 2,
                          Bevel_Hi);
         Paint.Fill_Rect
           (C, TX + TW - 2, W.Y + 1, TX + TW - 1, PY + 2,
            Bevel_Lo);
         LW := Fonts.Text_Width
           (W.Labels (W.Sel).Buf (1 .. W.Labels (W.Sel).Len));
         LX := TX + (if TW > LW then (TW - LW) / 2 else 1);
         Fonts.Draw_Text
           (C, LX, W.Y + 4,
            W.Labels (W.Sel).Buf (1 .. W.Labels (W.Sel).Len),
            Text_Dark);
         --  The page itself.
         W.Kids (W.Sel).Draw (C);
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

   function On_Key (W : access Tabs; Code : U64) return Boolean is
   begin
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

end Trinket.Widgets;
