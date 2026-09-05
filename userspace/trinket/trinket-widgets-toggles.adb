with Trinket.Paint;
with Akernel_User.Theme;

package body Trinket.Widgets.Toggles is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Checkbox_Access is access Checkbox;
   type Radio_Access is access Radio;

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
      if W.Focused then
         --  No frame of its own: ring hugs the whole hit rect.
         Paint.Focus_Ring (C, W.X + 1, W.Y + 1,
                           W.X + W.W - 1, W.Y + W.H - 1, Text_Dark);
      end if;
   end Draw;

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
               W.Focused := True;   --  M87h: click takes focus
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

   function Wants_Focus (W : Checkbox) return Boolean is
     (not W.Disabled);  --  M87h: disabled gadgets skip the chain

   function On_Key
     (W : access Checkbox; Code : U64) return Boolean
   is
   begin
      --  M87h: Enter/Space toggles the focused checkbox.
      if not W.Focused or else W.Disabled then
         return False;
      end if;
      if Code = Key_Return or else Code = 13 or else Code = 32 then
         W.Checked := not W.Checked;
         W.Dirty := True;
         if W.On_Change /= null then
            W.On_Change (W.Checked);
         end if;
         return True;
      end if;
      return False;
   end On_Key;

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
      if W.Focused then
         Paint.Focus_Ring (C, W.X + 1, W.Y + 1,
                           W.X + W.W - 1, W.Y + W.H - 1, Text_Dark);
      end if;
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
               W.Focused := True;   --  M87h: click takes focus
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

   function Wants_Focus (W : Radio) return Boolean is
     (not W.Disabled);  --  M87h: disabled gadgets skip the chain

   function On_Key (W : access Radio; Code : U64) return Boolean is
   begin
      --  M87h: Enter/Space selects the focused radio.
      if not W.Focused or else W.Disabled then
         return False;
      end if;
      if Code = Key_Return or else Code = 13 or else Code = 32 then
         if not W.Selected then
            Set_Selected (W.all, True);
            if W.On_Change /= null then
               W.On_Change (True);
            end if;
         end if;
         return True;
      end if;
      return False;
   end On_Key;

end Trinket.Widgets.Toggles;
