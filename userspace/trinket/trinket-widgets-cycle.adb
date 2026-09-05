with Trinket.Paint;
with Trinket.Fonts;
with Akernel_User.Theme;

package body Trinket.Widgets.Cycle is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Cycle_Access is access Cycle;

   --  Cycle (M87f)

   Glyph_Col : constant U64 := 18;  --  right chevron column width

   function New_Cycle
     (On_Change : Cycle_Callback := null) return Any_Widget
   is
      CY : constant Cycle_Access := new Cycle;
   begin
      CY.On_Change := On_Change;
      return Any_Widget (CY);
   end New_Cycle;

   procedure Add_Entry (W : in out Cycle; S : String) is
   begin
      if W.N < Max_Children then
         W.N := W.N + 1;
         Set_Text (W.Entries (W.N).Buf, W.Entries (W.N).Len, S);
         if W.Sel = 0 then
            W.Sel := 1;
         end if;
         W.Dirty := True;
      end if;
   end Add_Entry;

   procedure Set_Selected (W : in out Cycle; I : Natural) is
   begin
      if I >= 1 and then I <= W.N and then I /= W.Sel then
         W.Sel := I;
         W.Dirty := True;
         if W.On_Change /= null then
            W.On_Change (I);
         end if;
      end if;
   end Set_Selected;

   function Selected (W : Cycle) return Natural is (W.Sel);

   procedure Draw (W : Cycle; C : Canvas) is
      LH    : constant U64 := Fonts.Line_Height;
      Shift : constant U64 := (if W.Pressed then 1 else 0);
      GX    : constant U64 := W.X + W.W - Glyph_Col;  --  glyph col
      CX    : constant U64 := GX + Glyph_Col / 2;
      CY    : constant U64 := W.Y + W.H / 2;
      TW    : U64;
      TX    : U64;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                       (if W.Hover and then not W.Pressed
                        then Akernel_User.Theme.Face_Hi else Face));
      Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                   Raised => not W.Pressed);
      --  Glyph column: separator line + up/down chevron pair
      --  (MUI cycle signature), shifted while pressed.
      Paint.Fill_Rect (C, GX + 2, W.Y + 3, GX + 3, W.Y + W.H - 3,
                       Bevel_Lo);
      for I in U64'(0) .. 2 loop
         --  Up chevron: peak at CY-3, arms down-out.
         Paint.Fill_Rect (C, CX - I + Shift, CY - 3 + I + Shift,
                          CX - I + 1 + Shift, CY - 2 + I + Shift,
                          Text_Dark);
         Paint.Fill_Rect (C, CX + I + Shift, CY - 3 + I + Shift,
                          CX + I + 1 + Shift, CY - 2 + I + Shift,
                          Text_Dark);
         --  Down chevron: valley at CY+3, arms up-out.
         Paint.Fill_Rect (C, CX - 2 + I + Shift, CY + 1 + I + Shift,
                          CX - 1 + I + Shift, CY + 2 + I + Shift,
                          Text_Dark);
         Paint.Fill_Rect (C, CX + 2 - I + Shift, CY + 1 + I + Shift,
                          CX + 3 - I + Shift, CY + 2 + I + Shift,
                          Text_Dark);
      end loop;
      if W.Sel >= 1 and then W.Sel <= W.N then
         TW := Fonts.Text_Width
           (W.Entries (W.Sel).Buf (1 .. W.Entries (W.Sel).Len));
         --  Text centered in the field left of the glyph column.
         TX := W.X + (if GX - 2 > W.X + TW
                      then (GX - 2 - W.X - TW) / 2 else 2);
         Fonts.Draw_Text
           (C, TX + Shift,
            W.Y + (if W.H > LH then (W.H - LH) / 2 else 0) + Shift,
            W.Entries (W.Sel).Buf (1 .. W.Entries (W.Sel).Len),
            Text_Dark);
      end if;
      if W.Focused then
         Paint.Focus_Ring (C, W.X + 3, W.Y + 3,
                           W.X + W.W - 3, W.Y + W.H - 3, Text_Dark);
      end if;
   end Draw;

   procedure Min_Size (W : Cycle; MW, MH : out U64) is
      TW : U64 := 0;
   begin
      for I in 1 .. W.N loop
         TW := Max (TW, Fonts.Text_Width
                    (W.Entries (I).Buf (1 .. W.Entries (I).Len)));
      end loop;
      --  Widest entry + side padding + the glyph column.
      MW := TW + 10 + Glyph_Col;
      MH := Fonts.Line_Height + 8;
   end Min_Size;

   function On_Pointer
     (W : access Cycle; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
   begin
      case K is
         when Press =>
            if Inside (W.all, PX, PY) then
               W.Pressed := True;
               W.Focused := True;   --  M87h: click takes focus
               W.Dirty := True;
               return True;
            end if;
         when Release =>
            if W.Pressed then
               W.Pressed := False;
               W.Dirty := True;
               --  Release-over rotates to the next entry (wraps).
               if Inside (W.all, PX, PY) and then W.N > 0 then
                  Set_Selected (W.all, W.Sel mod W.N + 1);
               end if;
               return True;
            end if;
         when Move =>
            --  Hover tracking: never consume an unpressed move,
            --  so siblings clear/set their own hover.
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

   function Wants_Focus (W : Cycle) return Boolean is
      pragma Unreferenced (W);
   begin
      return True;
   end Wants_Focus;

   function On_Key (W : access Cycle; Code : U64) return Boolean is
   begin
      --  M87h: a focused cycle rotates on Enter/Space/Right
      --  (forward) and Left (back), wrapping. Set_Selected
      --  fires On_Change on a real change.
      if not W.Focused or else W.N = 0 then
         return False;
      end if;
      if Code = Key_Return or else Code = 13 or else Code = 32
        or else Code = Key_Right
      then
         Set_Selected (W.all, W.Sel mod W.N + 1);
         return True;
      elsif Code = Key_Left then
         Set_Selected
           (W.all, (if W.Sel <= 1 then W.N else W.Sel - 1));
         return True;
      end if;
      return False;
   end On_Key;

end Trinket.Widgets.Cycle;
