with Trinket.Paint;
with Trinket.Fonts;

package body Trinket.Listview is

   use type Trinket.U64;
   use Trinket.Widgets;

   function Min (A, B : U64) return U64 is (if A < B then A else B);
   function Max (A, B : U64) return U64 is (if A > B then A else B);

   type Listview_Access is access Listview;

   procedure Set_Text
     (Buf : out Item_String; Len : out Natural; S : String)
   is
      N : constant Natural := Natural'Min (S'Length, Buf'Length);
   begin
      Len := N;
      if N > 0 then
         Buf (1 .. N) := S (S'First .. S'First + N - 1);
      end if;
   end Set_Text;

   function New_Listview
     (On_Change : Selected_Callback := null) return Any_Listview
   is
      L : constant Listview_Access := new Listview;
   begin
      L.On_Change := On_Change;
      return Any_Listview (L);
   end New_Listview;

   procedure Clear (W : in out Listview) is
   begin
      W.N := 0;
      W.Sel := 0;
      W.Top := 0;
      W.Dirty := True;
   end Clear;

   procedure Add_Item (W : in out Listview; S : String) is
   begin
      if W.N < Max_Items then
         W.N := W.N + 1;
         Set_Text (W.Items (W.N).Text, W.Items (W.N).Len, S);
         W.Dirty := True;
      end if;
   end Add_Item;

   function Item_Count (W : Listview) return Natural is (W.N);

   function Get_Item (W : Listview; I : Positive) return String is
   begin
      if I > W.N then
         return "";
      end if;
      return W.Items (I).Text (1 .. W.Items (I).Len);
   end Get_Item;

   function Visible_Rows (W : Listview) return U64 is
      LH : constant U64 := Fonts.Line_Height;
   begin
      if W.H < LH then
         return 1;
      end if;
      return U64'Max (1, W.H / LH);
   end Visible_Rows;

   function Max_Top (W : Listview) return U64 is
      Vis  : constant U64 := Visible_Rows (W);
   begin
      if W.N > Natural (Vis) then
         return U64 (W.N - Natural (Vis));
      end if;
      return 0;
   end Max_Top;

   procedure Clamp_Top (W : in out Listview) is
      M : constant U64 := Max_Top (W);
   begin
      if W.Top > M then
         W.Top := M;
      end if;
   end Clamp_Top;

   procedure Fire_On_Change (W : in out Listview) is
   begin
      if W.On_Change /= null then
         W.On_Change (W.Sel);
      end if;
   end Fire_On_Change;

   procedure Set_Selected (W : in out Listview; I : Natural) is
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

            --  Keep the selected item visible.
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

   function Selected (W : Listview) return Natural is (W.Sel);

   procedure Set_Top (W : in out Listview; T : U64) is
      M : constant U64 := Max_Top (W);
      N : constant U64 := U64'Min (T, M);
   begin
      if N /= W.Top then
         W.Top := N;
         W.Dirty := True;
      end if;
   end Set_Top;

   function Top (W : Listview) return U64 is (W.Top);

   overriding procedure Draw (W : Listview; C : Canvas) is
      C2  : Canvas := C;
      Vis : constant U64 := Visible_Rows (W);
      LH  : constant U64 := Fonts.Line_Height;
      Y   : U64;
   begin
      Set_Clip (C2, W.X, W.Y, W.X + W.W, W.Y + W.H);
      if C2.CX1 <= C2.CX0 or else C2.CY1 <= C2.CY0 then
         return;
      end if;

      Paint.Fill_Rect (C2, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);

      for R in 0 .. Vis - 1 loop
         declare
            Idx : constant U64 := W.Top + R;
         begin
            exit when Idx >= U64 (W.N);
            Y := W.Y + R * LH;
            if Y + LH > W.Y + W.H then
               exit;
            end if;

            if Natural (Idx + 1) = W.Sel then
               Paint.Fill_Rect
                 (C2, W.X, Y, W.X + W.W, Y + LH, Sel_Blue);
            end if;

            Fonts.Draw_Text
              (C2, W.X + 4, Y,
               W.Items (Natural (Idx + 1)).Text
                 (1 .. W.Items (Natural (Idx + 1)).Len),
               Text_Dark);
         end;
      end loop;
   end Draw;

   overriding function On_Key
     (W : access Listview; Code : U64) return Boolean
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
      end if;

      return False;
   end On_Key;

   overriding function On_Pointer
     (W : access Listview; K : Widgets.Pointer_Kind; PX, PY : U64)
      return Boolean
   is
      LH : constant U64 := Fonts.Line_Height;
      R  : U64;
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

      R := (PY - W.Y) / LH;
      Idx := Natural (W.Top + R) + 1;
      if Idx <= W.N then
         Set_Selected (W.all, Idx);
      end if;
      return True;
   end On_Pointer;

end Trinket.Listview;
