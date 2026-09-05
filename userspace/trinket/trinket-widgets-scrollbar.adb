with Trinket.Paint;

package body Trinket.Widgets.Scrollbar is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Scrollbar_Access is access Scrollbar;

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

   function Fixed_Main
     (W : Scrollbar; Group_Dir : Direction) return Boolean is
     (W.Dir /= Group_Dir);  --  cross-axis bar: fixed Arrow slot

   function Narrow_Cross
     (W : Scrollbar; Group_Dir : Direction) return Boolean is
     (W.Dir = Group_Dir);   --  same-axis bar: Arrow wide, centered

end Trinket.Widgets.Scrollbar;
