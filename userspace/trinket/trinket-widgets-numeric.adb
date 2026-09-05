with Trinket.Paint;
with Trinket.Fonts;
with Akernel_User.Theme;

package body Trinket.Widgets.Numeric is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Numeric_Access is access Numeric;

   --  Numeric (M87g)

   --  Decimal image, no leading space.
   function Num_Img (V : U64) return String is
      S : constant String := U64'Image (V);
   begin
      return S (S'First + 1 .. S'Last);
   end Num_Img;

   function New_Numeric
     (Min : U64 := 0; Max : U64 := 100;
      On_Change : Numeric_Callback := null) return Any_Widget
   is
      NM : constant Numeric_Access := new Numeric;
   begin
      NM.Min := Min;
      NM.Max := Max;
      NM.Val := Min;
      NM.On_Change := On_Change;
      return Any_Widget (NM);
   end New_Numeric;

   procedure Set_Value (W : in out Numeric; V : U64) is
      C : constant U64 :=
        (if V < W.Min then W.Min elsif V > W.Max then W.Max
         else V);
   begin
      if C /= W.Val then
         W.Val := C;
         W.Dirty := True;
      end if;
   end Set_Value;

   function Value (W : Numeric) return U64 is (W.Val);

   --  User step: clamp, fire On_Change on a real change.
   procedure User_Step (W : access Numeric; Up : Boolean) is
      Old : constant U64 := W.Val;
   begin
      if Up then
         Set_Value (W.all, W.Val + W.Step);
      else
         --  Pre-clamp (M87b lesson): Val - Step in U64 wraps
         --  past Min.
         Set_Value
           (W.all,
            (if W.Val > W.Min + W.Step then W.Val - W.Step
             else W.Min));
      end if;
      if W.Val /= Old and then W.On_Change /= null then
         W.On_Change (W.Val);
      end if;
   end User_Step;

   --  Which arrow half: 0 outside the column, +1 up, -1 down.
   function Arrow_At (W : Numeric; PX, PY : U64) return Integer is
      GX : constant U64 := W.X + W.W - Glyph_Col;
   begin
      if PX < GX or else PX >= W.X + W.W
        or else PY < W.Y or else PY >= W.Y + W.H
      then
         return 0;
      end if;
      return (if PY < W.Y + W.H / 2 then 1 else -1);
   end Arrow_At;

   procedure Draw (W : Numeric; C : Canvas) is
      LH : constant U64 := Fonts.Line_Height;
      GX : constant U64 := W.X + W.W - Glyph_Col;
      GY : constant U64 := W.Y + W.H / 2;  --  up/down split
      S  : constant String := Num_Img (W.Val);
      TW : constant U64 := Fonts.Text_Width (S);

      --  One arrow half: raised Face mini-button, sunken while
      --  held, chevron (Up glyph else Down) shifted on press.
      procedure Draw_Arrow (Up : Boolean) is
         A  : constant Integer := (if Up then 1 else -1);
         Y0 : constant U64 := (if Up then W.Y else GY);
         Y1 : constant U64 := (if Up then GY else W.Y + W.H);
         Sh : constant U64 := (if W.Arrow_Dn = A then 1 else 0);
         CX : constant U64 := GX + Glyph_Col / 2;
         CY : constant U64 := (Y0 + Y1) / 2;
      begin
         Paint.Fill_Rect
           (C, GX, Y0, W.X + W.W, Y1,
            (if W.Hover_Arr = A and then W.Arrow_Dn = 0
             then Akernel_User.Theme.Face_Hi else Face));
         Paint.Bevel2 (C, GX, Y0, W.X + W.W, Y1,
                      Raised => W.Arrow_Dn /= A);
         for I in U64'(0) .. 3 loop
            if Up then
               Paint.Fill_Rect
                 (C, CX - I + Sh, CY - 3 + I + Sh,
                  CX - I + 1 + Sh, CY - 2 + I + Sh, Text_Dark);
               Paint.Fill_Rect
                 (C, CX + I + Sh, CY - 3 + I + Sh,
                  CX + I + 1 + Sh, CY - 2 + I + Sh, Text_Dark);
            else
               Paint.Fill_Rect
                 (C, CX - 3 + I + Sh, CY - 1 + I + Sh,
                  CX - 2 + I + Sh, CY + I + Sh, Text_Dark);
               Paint.Fill_Rect
                 (C, CX + 3 - I + Sh, CY - 1 + I + Sh,
                  CX + 4 - I + Sh, CY + I + Sh, Text_Dark);
            end if;
         end loop;
      end Draw_Arrow;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      --  Value field: sunken Pane inset, number right-aligned
      --  against the arrow column.
      Paint.Fill_Rect (C, W.X, W.Y, GX, W.Y + W.H, Pane);
      Paint.Bevel2 (C, W.X, W.Y, GX, W.Y + W.H, Raised => False);
      if GX > W.X + TW + 6 then
         Fonts.Draw_Text
           (C, GX - TW - 4,
            W.Y + (if W.H > LH then (W.H - LH) / 2 else 0),
            S, Text_Dark);
      end if;
      Draw_Arrow (True);
      Draw_Arrow (False);
      if W.Focused then
         Paint.Focus_Ring (C, W.X + 3, W.Y + 3,
                           W.X + W.W - 3, W.Y + W.H - 3, Text_Dark);
      end if;
   end Draw;

   procedure Min_Size (W : Numeric; MW, MH : out U64) is
   begin
      --  Widest possible value + padding + the arrow column.
      MW := Fonts.Text_Width (Num_Img (W.Max)) + 10 + Glyph_Col;
      MH := Fonts.Line_Height + 8;
   end Min_Size;

   function On_Pointer
     (W : access Numeric; K : Pointer_Kind; PX, PY : U64)
      return Boolean
   is
      A : Integer;
   begin
      case K is
         when Press =>
            if not Inside (W.all, PX, PY) then
               return False;
            end if;
            W.Focused := True;   --  M87h: click takes focus
            W.Arrow_Dn := Arrow_At (W.all, PX, PY);
            W.Dirty := True;
            return True;
         when Release =>
            if W.Arrow_Dn /= 0 then
               A := Arrow_At (W.all, PX, PY);
               if A = W.Arrow_Dn then
                  User_Step (W, A > 0);
               end if;
               W.Arrow_Dn := 0;
               W.Dirty := True;
               return True;
            end if;
            return False;
         when Move =>
            A := Arrow_At (W.all, PX, PY);
            if A /= W.Hover_Arr then
               W.Hover_Arr := A;
               W.Dirty := True;
            end if;
            return W.Arrow_Dn /= 0;
      end case;
   end On_Pointer;

   function Wants_Focus (W : Numeric) return Boolean is
      pragma Unreferenced (W);
   begin
      return True;
   end Wants_Focus;

   function On_Key (W : access Numeric; Code : U64) return Boolean is
   begin
      --  M87h: a focused numeric's Up/Right step +Step, Down/Left
      --  -Step; User_Step pre-clamps and fires On_Change on a
      --  real change.
      if not W.Focused then
         return False;
      end if;
      if Code = Key_Up or else Code = Key_Right then
         User_Step (W, True);
         return True;
      elsif Code = Key_Down or else Code = Key_Left then
         User_Step (W, False);
         return True;
      end if;
      return False;
   end On_Key;

end Trinket.Widgets.Numeric;
