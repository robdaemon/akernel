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

   procedure Add (G : in out Group; Child : Any_Widget) is
   begin
      if G.N < Max_Children then
         G.N := G.N + 1;
         G.Kids (G.N) := Child;
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
      Each    : U64;
      Pos     : U64;
   begin
      if W.N = 0 then
         return;
      end if;
      if W.Dir = Vertical then
         Avail := IY1 - IY0 - Spacing * U64 (W.N - 1);
         Each  := Avail / U64 (W.N);
         Pos   := IY0;
         for I in 1 .. W.N loop
            W.Kids (I).X := IX0;
            W.Kids (I).Y := Pos;
            W.Kids (I).W := IX1 - IX0;
            W.Kids (I).H := Each;
            Pos := Pos + Each + Spacing;
         end loop;
      else
         Avail := IX1 - IX0 - Spacing * U64 (W.N - 1);
         Each  := Avail / U64 (W.N);
         Pos   := IX0;
         for I in 1 .. W.N loop
            W.Kids (I).X := Pos;
            W.Kids (I).Y := IY0;
            W.Kids (I).W := Each;
            W.Kids (I).H := IY1 - IY0;
            Pos := Pos + Each + Spacing;
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
      for I in 1 .. W.N loop
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
