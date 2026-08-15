package body Trinket.Paint is
   use type Trinket.U64;

   function Max (A, B : U64) return U64 is (if A > B then A else B);
   function Min (A, B : U64) return U64 is (if A < B then A else B);

   procedure Plot (C : Canvas; X, Y : U64; Col : Pixel) is
      Pix : Pixel_Array (0 .. C.W * C.H - 1)
        with Address => C.Base;
   begin
      if X >= C.CX0 and then X < C.CX1
        and then Y >= C.CY0 and then Y < C.CY1
      then
         Pix (Y * C.W + X) := Col;
      end if;
   end Plot;

   procedure HLine (C : Canvas; X0, X1, Y : U64; Col : Pixel) is
   begin
      for X in X0 .. X1 loop
         Plot (C, X, Y, Col);
      end loop;
   end HLine;

   procedure VLine (C : Canvas; X, Y0, Y1 : U64; Col : Pixel) is
   begin
      for Y in Y0 .. Y1 loop
         Plot (C, X, Y, Col);
      end loop;
   end VLine;

   procedure Fill_Rect
     (C : Canvas; X0, Y0, X1, Y1 : U64; Col : Pixel)
   is
      Pix : Pixel_Array (0 .. C.W * C.H - 1)
        with Address => C.Base;
      RX0 : constant U64 := Max (X0, C.CX0);
      RY0 : constant U64 := Max (Y0, C.CY0);
      RX1 : constant U64 := Min (X1, C.CX1);
      RY1 : constant U64 := Min (Y1, C.CY1);
   begin
      if RX0 >= RX1 or else RY0 >= RY1 then
         return;
      end if;
      for Y in RY0 .. RY1 - 1 loop
         for X in RX0 .. RX1 - 1 loop
            Pix (Y * C.W + X) := Col;
         end loop;
      end loop;
   end Fill_Rect;

   procedure Bevel2
     (C : Canvas; X0, Y0, X1, Y1 : U64; Raised : Boolean := True)
   is
      I1_Hi : constant Pixel := (if Raised then Bevel_Hi else Bevel_Lo);
      I1_Lo : constant Pixel := (if Raised then Bevel_Lo else Bevel_Hi);
      I2_Hi : constant Pixel := (if Raised then Bevel_Hi else Border);
      I2_Lo : constant Pixel := (if Raised then Border else Bevel_Hi);
   begin
      if X1 - X0 < 6 or else Y1 - Y0 < 6 then
         return;
      end if;
      --  Outer black ridge.
      HLine (C, X0, X1 - 1, Y0, Border);
      HLine (C, X0, X1 - 1, Y1 - 1, Border);
      VLine (C, X0, Y0, Y1 - 1, Border);
      VLine (C, X1 - 1, Y0, Y1 - 1, Border);
      --  Inner ridge 1.
      HLine (C, X0 + 1, X1 - 2, Y0 + 1, I1_Hi);
      VLine (C, X0 + 1, Y0 + 1, Y1 - 2, I1_Hi);
      HLine (C, X0 + 1, X1 - 2, Y1 - 2, I1_Lo);
      VLine (C, X1 - 2, Y0 + 1, Y1 - 2, I1_Lo);
      --  Inner ridge 2.
      HLine (C, X0 + 2, X1 - 3, Y0 + 2, I2_Hi);
      VLine (C, X0 + 2, Y0 + 2, Y1 - 3, I2_Hi);
      HLine (C, X0 + 2, X1 - 3, Y1 - 3, I2_Lo);
      VLine (C, X1 - 3, Y0 + 2, Y1 - 3, I2_Lo);
   end Bevel2;

end Trinket.Paint;
