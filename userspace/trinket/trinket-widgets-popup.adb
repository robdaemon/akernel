with Trinket.Paint;
with Trinket.Fonts;

package body Trinket.Widgets.Popup is
   use type Trinket.U64;

   --  Named access type at library level (the tdemo
   --  PROGRAM_ERROR lesson): allocators of an anonymous access
   --  type inherit FUNCTION-level accessibility and the
   --  Any_Widget conversion's dynamic check fails.
   type Popup_Access is access Popup;

   Frame : constant U64 := 3;   --  bevel ring thickness
   Pad_X : constant U64 := 8;   --  row text inset per side

   function Item_H return U64 is (Fonts.Line_Height + 4);

   --  Row under PY, 0 when in the frame or past the last row.
   function Item_At (W : Popup; PY : U64) return Natural is
      Rel : constant U64 := (if PY > W.Y + Frame
                             then PY - W.Y - Frame else 0);
      I   : constant Natural := Natural (Rel / Item_H) + 1;
   begin
      if PY < W.Y + Frame or else PY >= W.Y + W.H - Frame
        or else I > W.N
      then
         return 0;
      end if;
      return I;
   end Item_At;

   function New_Popup
     (On_Pick : Pick_Callback := null) return Any_Widget
   is
      P : constant Popup_Access := new Popup;
   begin
      P.On_Pick := On_Pick;
      return Any_Widget (P);
   end New_Popup;

   procedure Add_Item (W : in out Popup; S : String) is
   begin
      if W.N < Max_Children then
         W.N := W.N + 1;
         Set_Text (W.Items (W.N).Buf, W.Items (W.N).Len, S);
      end if;
   end Add_Item;

   procedure Draw (W : Popup; C : Canvas) is
      RY : U64;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);
      Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H);
      for I in 1 .. W.N loop
         RY := W.Y + Frame + U64 (I - 1) * Item_H;
         if I = W.Hover or else I = W.Pressed then
            --  Inverted row, listview selection style.
            Paint.Fill_Rect (C, W.X + Frame, RY,
                             W.X + W.W - Frame, RY + Item_H,
                             Sel_Blue);
         end if;
         Fonts.Draw_Text
           (C, W.X + Pad_X, RY + 2,
            W.Items (I).Buf (1 .. W.Items (I).Len),
            (if I = W.Hover or else I = W.Pressed
             then Pane else Text_Dark));
      end loop;
   end Draw;

   procedure Min_Size (W : Popup; MW, MH : out U64) is
      TW : U64 := 0;
   begin
      for I in 1 .. W.N loop
         TW := Max (TW, Fonts.Text_Width
                    (W.Items (I).Buf (1 .. W.Items (I).Len)));
      end loop;
      MW := TW + 2 * Pad_X + 2 * Frame;
      MH := U64 (W.N) * Item_H + 2 * Frame;
   end Min_Size;

   function On_Pointer
     (W : access Popup; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
      pragma Unreferenced (PX);
      I : Natural;
   begin
      case K is
         when Press =>
            W.Pressed := Item_At (W.all, PY);
            W.Dirty := True;
            return True;
         when Release =>
            if W.Pressed /= 0 then
               I := Item_At (W.all, PY);
               if I = W.Pressed and then W.On_Pick /= null then
                  W.On_Pick (I);
               end if;
               W.Pressed := 0;
               W.Dirty := True;
            end if;
            return True;
         when Move =>
            I := (if Inside (W.all, W.X, PY) then Item_At (W.all, PY)
                  else 0);
            if I /= W.Hover then
               W.Hover := I;
               W.Dirty := True;
            end if;
            return True;
      end case;
   end On_Pointer;

end Trinket.Widgets.Popup;
