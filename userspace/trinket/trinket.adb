package body Trinket is
   use type Trinket.U64;

   function Max (A, B : U64) return U64 is (if A > B then A else B);
   function Min (A, B : U64) return U64 is (if A < B then A else B);

   procedure Set_Clip (C : in out Canvas; X0, Y0, X1, Y1 : U64) is
   begin
      C.CX0 := Max (C.CX0, X0);
      C.CY0 := Max (C.CY0, Y0);
      C.CX1 := Min (C.CX1, X1);
      C.CY1 := Min (C.CY1, Y1);
   end Set_Clip;

   procedure Reset_Clip (C : in out Canvas) is
   begin
      C.CX0 := 0;
      C.CY0 := 0;
      C.CX1 := C.W;
      C.CY1 := C.H;
   end Reset_Clip;

end Trinket;
