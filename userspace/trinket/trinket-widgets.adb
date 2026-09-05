with Trinket.Paint;
with Trinket.Fonts;

package body Trinket.Widgets is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Group_Access is access Group;

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

   function Wants_Focus (W : Widget) return Boolean is
      pragma Unreferenced (W);
   begin
      return False;
   end Wants_Focus;

   procedure Set_Tab_Rank (W : in out Widget; Rank : Natural) is
   begin
      W.Tab_Rank := Rank;
   end Set_Tab_Rank;

   procedure Set_Focused (W : in out Widget; F : Boolean) is
   begin
      if W.Focused /= F then
         W.Focused := F;
         W.Dirty := True;
      end if;
   end Set_Focused;

   function Is_Focused (W : Widget) return Boolean is (W.Focused);

   procedure Clear_Focus (Root : Any_Widget) is
   begin
      if Root = null then
         return;
      end if;
      Set_Focused (Root.all, False);
      if Root.all in Group'Class then
         for I in 1 .. Group (Root.all).N loop
            Clear_Focus (Group (Root.all).Kids (I));
         end loop;
      end if;
   end Clear_Focus;

   procedure Cycle_Focus (Root : Any_Widget) is
      Chain  : array (1 .. Max_Focus_Chain) of Any_Widget;
      Keys   : array (1 .. Max_Focus_Chain) of Natural;
      Ranked : array (1 .. Max_Focus_Chain) of Boolean;
      N      : Natural := 0;

      --  Depth-first collect of chain members in add order.
      procedure Collect (W : Any_Widget) is
      begin
         if W = null then
            return;
         end if;
         if Wants_Focus (W.all) and then N < Max_Focus_Chain then
            N := N + 1;
            Chain (N) := W;
         end if;
         if W.all in Group'Class then
            for I in 1 .. Group (W.all).N loop
               Collect (Group (W.all).Kids (I));
            end loop;
         end if;
      end Collect;

      Cur  : Natural := 0;
      Next : Positive;
   begin
      Collect (Root);
      if N = 0 then
         return;
      end if;
      --  Sort key: rank 0 keeps the flattened add position; a
      --  positive rank sorts AS that position. Ties: a RANKED
      --  widget goes before the natural occupant (rank 1 really
      --  means "focus first"); ties between two ranked widgets
      --  keep add order (stable insertion sort).
      for I in 1 .. N loop
         Ranked (I) := Chain (I).Tab_Rank /= 0;
         Keys (I) :=
           (if Ranked (I) then Chain (I).Tab_Rank else I);
      end loop;
      for I in 2 .. N loop
         declare
            Tmp : constant Any_Widget := Chain (I);
            TK  : constant Natural := Keys (I);
            TR  : constant Boolean := Ranked (I);
            J   : Natural := I;
         begin
            while J > 1
              and then (Keys (J - 1) > TK
                        or else (Keys (J - 1) = TK
                                 and then not Ranked (J - 1)
                                 and then TR))
            loop
               Chain (J) := Chain (J - 1);
               Keys (J) := Keys (J - 1);
               Ranked (J) := Ranked (J - 1);
               J := J - 1;
            end loop;
            Chain (J) := Tmp;
            Keys (J) := TK;
            Ranked (J) := TR;
         end;
      end loop;
      for I in 1 .. N loop
         if Chain (I).Focused then
            Cur := I;
            Set_Focused (Chain (I).all, False);
         end if;
      end loop;
      Next := (if Cur = 0 or else Cur = N then 1 else Cur + 1);
      Set_Focused (Chain (Next).all, True);
   end Cycle_Focus;

   function Inside (W : Widget; PX, PY : U64) return Boolean is
     (PX >= W.X and then PX < W.X + W.W
      and then PY >= W.Y and then PY < W.Y + W.H);

   function Fixed_Main
     (W : Widget; Group_Dir : Direction) return Boolean
   is
      pragma Unreferenced (W, Group_Dir);
   begin
      return False;
   end Fixed_Main;

   function Narrow_Cross
     (W : Widget; Group_Dir : Direction) return Boolean
   is
      pragma Unreferenced (W, Group_Dir);
   begin
      return False;
   end Narrow_Cross;

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

   --  Shared floor: box at X+2, label Toggle_Gap right of it,
   --  2px slack on the right; the taller of box/text plus 4.
   procedure Toggle_Min (Txt : String; MW, MH : out U64) is
   begin
      MW := 2 + Toggle_Box + Toggle_Gap
        + Fonts.Text_Width (Txt) + 2;
      MH := Max (Toggle_Box, Fonts.Line_Height) + 4;
   end Toggle_Min;

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
      --  groups, horizontal bars in vertical groups) — via the
      --  Fixed_Main/Narrow_Cross layout hooks, so Group never
      --  names the Scrollbar child package.
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
            if Fixed_Main (W.Kids (I).all, Vertical) then
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
            if Fixed_Main (W.Kids (I).all, Vertical) then
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
               if Narrow_Cross (W.Kids (I).all, Vertical) then
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
            if Fixed_Main (W.Kids (I).all, Horizontal) then
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
            if Fixed_Main (W.Kids (I).all, Horizontal) then
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
               if Narrow_Cross (W.Kids (I).all, Horizontal) then
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

end Trinket.Widgets;
