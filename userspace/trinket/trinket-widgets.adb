with Trinket.Paint;
with Trinket.Fonts;

package body Trinket.Widgets is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Label_Access is access Label;
   type Button_Access is access Button;
   type Group_Access is access Group;
   type Scrollbar_Access is access Scrollbar;
   type Image_Access is access Image_Widget;

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
      Trinket.Images.Blit (C, W.Img, DX, DY);
   end Draw;

   procedure Set_Image
     (W : in out Image_Widget; Img : Trinket.Images.Image) is
   begin
      W.Img := Img;
      W.Dirty := True;
   end Set_Image;

   function Max (A, B : U64) return U64 is (if A > B then A else B);
   function Min (A, B : U64) return U64 is (if A < B then A else B);

   procedure Layout (W : in out Widget) is
      pragma Unreferenced (W);
   begin
      null;
   end Layout;

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
   --  HOff (character granularity; the font is 8 px monospace).
   procedure Ensure_Visible (W : in out Input) is
      CW      : constant U64 := 8;
      Visible : constant Natural :=
        (if W.W > 8 then Natural ((W.W - 8) / CW) else 1);
   begin
      if W.Cur < W.HOff then
         W.HOff := W.Cur;
      elsif W.Cur > W.HOff + Visible then
         W.HOff := W.Cur - Visible;
      end if;
   end Ensure_Visible;

   procedure Draw (W : Input; C : Canvas) is
      C2 : Canvas := C;
      LH : constant U64 := Fonts.Line_Height;
      CW : constant U64 := 8;
      TY : constant U64 :=
        W.Y + (if W.H > LH then (W.H - LH) / 2 else 0);
      VN : constant Natural := Natural'Min (W.Len, W.HOff +
        (if W.W > 8 then Natural ((W.W - 8) / CW) else 1));
   begin
      if not Intersects (W, C) then
         return;
      end if;
      Set_Clip (C2, W.X, W.Y, W.X + W.W, W.Y + W.H);
      Paint.Fill_Rect (C2, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);
      Paint.Bevel2 (C2, W.X, W.Y, W.X + W.W, W.Y + W.H,
                    Raised => False);
      if VN > W.HOff then
         Fonts.Draw_Text
           (C2, W.X + 4, TY + 2,
            W.Buf (W.HOff + 1 .. VN), Text_Dark);
      end if;
      if W.Focused then
         Paint.Fill_Rect
           (C2, W.X + 4 + U64 (W.Cur - W.HOff) * CW, TY + 2,
            W.X + 5 + U64 (W.Cur - W.HOff) * CW, TY + 2 + LH,
            Text_Dark);
      end if;
   end Draw;

   function On_Key (W : access Input; Code : U64) return Boolean is
      CW : constant U64 := 8;
      pragma Unreferenced (CW);
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
      elsif Code = 13 then              --  Enter
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
      CW : constant U64 := 8;
   begin
      if K /= Press or else not Inside (W.all, PX, PY) then
         return False;
      end if;
      W.Focused := True;
      if PX > W.X + 4 then
         W.Cur := Natural'Min
           (W.Len, W.HOff + Natural ((PX - W.X - 4) / CW));
      else
         W.Cur := W.HOff;
      end if;
      Ensure_Visible (W.all);
      W.Dirty := True;
      return True;
   end On_Pointer;

   --  Button

   function New_Button
     (S : String; On_Click : Click_Callback := null) return Any_Widget
   is
      B : constant Button_Access := new Button;
   begin
      Set_Text (B.Txt, B.Len, S);
      B.On_Click := On_Click;
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
      Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Face);
      Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                   Raised => not W.Pressed);
      Fonts.Draw_Text (C, TX, TY, W.Txt (1 .. W.Len), Text_Dark);
   end Draw;

   function On_Pointer
     (W : access Button; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
   begin
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
            return W.Pressed;
      end case;
      return False;
   end On_Pointer;

   --  Scrollbar

   Arrow : constant U64 := 16;  --  arrow box height

   function New_Scrollbar
     (On_Change : Change_Callback := null) return Any_Widget
   is
      S : constant Scrollbar_Access := new Scrollbar;
   begin
      S.On_Change := On_Change;
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
      W.Min := Min;
      W.Max := Max;
      W.Visible := U64'Max (Visible, 1);
      Clamp_Pos (W);
      W.Dirty := True;
   end Set_Range;

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
            W.On_Change (W.Pos);
         end if;
      end if;
   end User_Move;

   --  Knob geometry: track between the arrow boxes; knob height
   --  proportional to Visible / (Max - Min + Visible); knob top
   --  linear in Pos.
   procedure Knob_Rect
     (W : Scrollbar; Top, Bottom : out U64)
   is
      Track_T : constant U64 := W.Y + Arrow;
      Track_B : constant U64 := W.Y + W.H - Arrow;
      Track_H : constant U64 := Track_B - Track_T;
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

   procedure Draw (W : Scrollbar; C : Canvas) is
      KT, KB : U64;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Face);
      Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                    Raised => False);
      --  Arrow boxes + triangle glyphs.
      Paint.Fill_Rect (C, W.X + 2, W.Y + 2, W.X + W.W - 2,
                       W.Y + Arrow - 2, Face);
      Paint.Bevel2 (C, W.X + 2, W.Y + 2, W.X + W.W - 2,
                    W.Y + Arrow - 2);
      Paint.Fill_Rect (C, W.X + 2, W.Y + W.H - Arrow + 2,
                       W.X + W.W - 2, W.Y + W.H - 2, Face);
      Paint.Bevel2 (C, W.X + 2, W.Y + W.H - Arrow + 2,
                    W.X + W.W - 2, W.Y + W.H - 2);
      declare
         MX : constant U64 := W.X + W.W / 2;
      begin
         for DY in U64'(0) .. 3 loop
            Paint.Fill_Rect (C, MX - DY, W.Y + 5 + DY,
                             MX + DY + 1, W.Y + 6 + DY, Text_Dark);
            Paint.Fill_Rect (C, MX - DY, W.Y + W.H - 6 - DY,
                             MX + DY + 1, W.Y + W.H - 5 - DY,
                             Text_Dark);
         end loop;
      end;
      --  Knob (striped, the mockup look).
      Knob_Rect (W, KT, KB);
      if KB > KT then
         Paint.Fill_Rect (C, W.X + 2, KT, W.X + W.W - 2, KB, Face);
         Paint.Bevel2 (C, W.X + 2, KT, W.X + W.W - 2, KB);
         declare
            SY : U64 := KT + 5;
         begin
            while SY + 1 < KB - 4 loop
               Paint.Fill_Rect (C, W.X + 5, SY, W.X + W.W - 5,
                                SY + 1, Bevel_Lo);
               SY := SY + 3;
            end loop;
         end;
      end if;
   end Draw;

   function On_Pointer
     (W : access Scrollbar; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
      KT, KB : U64;
      Track_T : constant U64 := W.Y + Arrow;
      Track_B : constant U64 := W.Y + W.H - Arrow;
   begin
      case K is
         when Press =>
            if not Inside (W.all, PX, PY) then
               return False;
            end if;
            Knob_Rect (W.all, KT, KB);
            if PY < W.Y + Arrow then
               User_Move (W, W.Pos - 1);
            elsif PY >= W.Y + W.H - Arrow then
               User_Move (W, W.Pos + 1);
            elsif PY >= KT and then PY < KB then
               W.Dragging := True;
               W.Grab_DY := PY - KT;
            elsif PY < KT then
               User_Move (W, W.Pos - W.Visible);
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
                    Track_B - Track_T - Knob_H;
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
            if W.Dragging then
               W.Dragging := False;
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

   procedure Layout (W : in out Group) is
      Margin  : constant U64 := 8;
      Spacing : constant U64 := 8;
      Top     : constant U64 := (if W.Title_Len > 0 then 16 else 8);
      IX0     : constant U64 := W.X + Margin;
      IY0     : constant U64 := W.Y + Top;
      IX1     : constant U64 := W.X + W.W - Margin;
      IY1     : constant U64 := W.Y + W.H - Margin;
      Avail   : U64;
      Pos     : U64;
      Fixed   : Natural := 0;  --  scrollbars pin to Arrow wide
      Total_W : U64 := 0;
      Cum     : U64;
      Prev    : U64;
   begin
      if W.N = 0 then
         return;
      end if;
      if W.Dir = Vertical then
         --  Weighted split (MUI lineage): positions derive from
         --  the CUMULATIVE weight fraction so rounding never
         --  drifts or leaves a remainder strip.
         for I in 1 .. W.N loop
            Total_W := Total_W + W.Wts (I);
         end loop;
         Avail := IY1 - IY0 - Spacing * U64 (W.N - 1);
         Cum   := 0;
         for I in 1 .. W.N loop
            Prev := Cum;
            Cum  := Cum + W.Wts (I);
            W.Kids (I).X := IX0;
            W.Kids (I).Y := IY0 + Spacing * U64 (I - 1)
              + Avail * Prev / Total_W;
            W.Kids (I).W := IX1 - IX0;
            W.Kids (I).H := Avail * Cum / Total_W
              - Avail * Prev / Total_W;
         end loop;
      else
         for I in 1 .. W.N loop
            if W.Kids (I).all in Scrollbar then
               Fixed := Fixed + 1;
            else
               Total_W := Total_W + W.Wts (I);
            end if;
         end loop;
         Avail := IX1 - IX0 - Spacing * U64 (W.N - 1)
           - U64 (Fixed) * Arrow;
         Pos := IX0;
         Cum := 0;
         for I in 1 .. W.N loop
            W.Kids (I).Y := IY0;
            W.Kids (I).H := IY1 - IY0;
            if W.Kids (I).all in Scrollbar then
               W.Kids (I).X := Pos;
               W.Kids (I).W := Arrow;
               Pos := Pos + Arrow + Spacing;
            else
               Prev := Cum;
               Cum  := Cum + W.Wts (I);
               W.Kids (I).X := Pos;
               W.Kids (I).W :=
                 (if Total_W > 0
                  then Avail * Cum / Total_W - Avail * Prev / Total_W
                  else 0);
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
            --  Face-colored band breaks the frame behind the title.
            Paint.Fill_Rect (C, TX - 6, W.Y, TX + TW + 6,
                             W.Y + Fonts.Line_Height, Face);
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
      --  pointer has slid off it.
      if K = Release then
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

   procedure Clear_Dirty (W : in out Group) is
   begin
      W.Dirty := False;
      for I in 1 .. W.N loop
         W.Kids (I).Clear_Dirty;
      end loop;
   end Clear_Dirty;

end Trinket.Widgets;
