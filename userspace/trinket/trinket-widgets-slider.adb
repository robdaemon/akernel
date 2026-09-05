with Trinket.Paint;
with Akernel_User.Theme;

package body Trinket.Widgets.Slider is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Slider_Access is access Slider;

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
      if W.Focused then
         --  No outer frame: ring just outside the track channel.
         Paint.Focus_Ring (C, W.X + 1, W.Y + 1,
                           W.X + W.W - 1, W.Y + W.H - 1, Text_Dark);
      end if;
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
            W.Focused := True;   --  M87h: click takes focus
            W.Dirty := True;
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

   function Wants_Focus (W : Slider) return Boolean is
      pragma Unreferenced (W);
   begin
      return True;
   end Wants_Focus;

   function On_Key (W : access Slider; Code : U64) return Boolean is
      Rng  : constant U64 :=
        (if W.Max > W.Min then W.Max - W.Min else 0);
      Step : constant U64 := U64'Max (Rng / 100, 1);
   begin
      --  M87h: a focused slider's Left/Down step -1%, Right/Up
      --  +1% (1 Pos unit floor); same U64 wrap guard as the
      --  track page-down.
      if not W.Focused then
         return False;
      end if;
      if Code = Key_Left or else Code = Key_Down then
         User_Move
           (W, (if W.Pos > W.Min + Step
                then W.Pos - Step else W.Min));
         return True;
      elsif Code = Key_Right or else Code = Key_Up then
         User_Move (W, W.Pos + Step);
         return True;
      end if;
      return False;
   end On_Key;

end Trinket.Widgets.Slider;
