with Trinket.Paint;
with Trinket.Fonts;
with Akernel_User.Theme;

package body Trinket.Widgets.Gauge is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Gauge_Access is access Gauge;

   --  Gauge

   function New_Gauge (Show_Pct : Boolean := True) return Any_Widget is
      G : constant Gauge_Access := new Gauge;
   begin
      G.Show_Pct := Show_Pct;
      return Any_Widget (G);
   end New_Gauge;

   procedure Set_Fraction (W : in out Gauge; Num, Den : U64) is
      Old_Num : constant U64 := W.Num;
      Old_Den : constant U64 := W.Den;
   begin
      W.Den := (if Den = 0 then 1 else Den);
      W.Num := (if Num > W.Den then W.Den else Num);
      if W.Num /= Old_Num or else W.Den /= Old_Den then
         W.Dirty := True;
      end if;
   end Set_Fraction;

   procedure Draw (W : Gauge; C : Canvas) is
      LH  : constant U64 := Fonts.Line_Height;
      Den : constant U64 := (if W.Den = 0 then 1 else W.Den);
      FW  : U64;  --  fill run inside the 2px bevel
      Pct : String (1 .. 4);
      PL  : Natural := 0;
      N   : U64;
      TW  : U64;
      TX  : U64;
      TY  : U64;
      C2  : Canvas;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);
      Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                    Raised => False);
      FW := (if W.W > 4 then (W.W - 4) * W.Num / Den else 0);
      if FW > 0 then
         Paint.Fill_Rect
           (C, W.X + 2, W.Y + 2, W.X + 2 + FW, W.Y + W.H - 2,
            Sel_Blue);
      end if;
      if W.Show_Pct then
         --  "NN%": N <= 100 (Set_Fraction clamps Num <= Den).
         N := W.Num * 100 / Den;
         if N >= 100 then
            PL := PL + 1;
            Pct (PL) := Character'Val (48 + Natural (N / 100));
         end if;
         if N >= 10 then
            PL := PL + 1;
            Pct (PL) := Character'Val (48 + Natural (N / 10 mod 10));
         end if;
         PL := PL + 1;
         Pct (PL) := Character'Val (48 + Natural (N mod 10));
         PL := PL + 1;
         Pct (PL) := '%';
         TW := Fonts.Text_Width (Pct (1 .. PL));
         TX := W.X + (if W.W > TW then (W.W - TW) / 2 else 0);
         TY := W.Y + (if W.H > LH then (W.H - LH) / 2 else 0);
         --  Dark on the empty half, light on the fill.
         C2 := C;
         Set_Clip (C2, W.X + 2 + FW, W.Y + 2,
                   W.X + W.W - 2, W.Y + W.H - 2);
         Fonts.Draw_Text (C2, TX, TY, Pct (1 .. PL), Text_Dark);
         if FW > 0 then
            C2 := C;
            Set_Clip (C2, W.X + 2, W.Y + 2,
                      W.X + 2 + FW, W.Y + W.H - 2);
            Fonts.Draw_Text
              (C2, TX, TY, Pct (1 .. PL),
               Akernel_User.Theme.Title_Text);
         end if;
      end if;
   end Draw;

   procedure Min_Size (W : Gauge; MW, MH : out U64) is
   begin
      --  Bar plus the "100%" label; vertically the Input floor.
      MW := (if W.Show_Pct
             then Fonts.Text_Width ("100%") + 16 else 48);
      MH := Fonts.Line_Height + 8;
   end Min_Size;

end Trinket.Widgets.Gauge;
