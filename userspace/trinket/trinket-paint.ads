--  Trinket paint primitives: clipped fills and the Workbench-3.x
--  double-ridge bevel (black outer border, white inner top-left,
--  dark-gray + black inner bottom-right; sunken for insets).
package Trinket.Paint is

   procedure Fill_Rect
     (C : Canvas; X0, Y0, X1, Y1 : U64; Col : Pixel);
   --  Half-open rect, clipped to the canvas clip.

   procedure Bevel2
     (C : Canvas; X0, Y0, X1, Y1 : U64; Raised : Boolean := True);
   --  Half-open rect frame, 3 lines per edge. Does NOT fill the
   --  interior.

end Trinket.Paint;
