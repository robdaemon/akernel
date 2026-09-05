with Terminal_Buffer;
with Trinket;
with Trinket.Widgets;
with Trinket.Widgets.Scrollbar;
with Trinket.Paint;
with Trinket.Fonts;

package body Terminal_Scroll is

   use type Trinket.U64;
   use Trinket;
   use Trinket.Widgets;
   package SB renames Trinket.Widgets.Scrollbar;

   Scroller : Any_Widget;

   procedure Scroll_Moved (Bar : Any_Widget; Pos : Trinket.U64) is
      pragma Unreferenced (Bar);
   begin
      Terminal_Buffer.Set_Top (Natural (Pos));
   end Scroll_Moved;

   procedure Init (W, H : Natural) is
      S : Any_Widget;
   begin
      S := SB.New_Scrollbar (Scroll_Moved'Access);
      S.X := Trinket.U64 (W - Scrollbar_W);
      S.Y := 0;
      S.W := Trinket.U64 (Scrollbar_W);
      S.H := Trinket.U64 (H);
      Scroller := S;
      Update_Range;
   end Init;

   procedure Update_Range is
      Count : constant Natural := Terminal_Buffer.Line_Count;
      Rows  : constant Natural := Terminal_Buffer.Rows;
      Max   : Natural;
      Vis   : Trinket.U64;
   begin
      Vis := Trinket.U64 (Rows);
      if Count > Rows then
         Max := Count - Rows;
      else
         Max := 0;
      end if;
      SB.Set_Range (SB.Scrollbar (Scroller.all), 0, Trinket.U64 (Max), Vis);
      SB.Set_Pos (SB.Scrollbar (Scroller.all),
                  Trinket.U64 (Terminal_Buffer.View_Top));
   end Update_Range;

   procedure Draw (C : Trinket.Canvas) is
      C2 : Trinket.Canvas := C;
      S  : constant Any_Widget := Scroller;
   begin
      Set_Clip (C2, S.X, S.Y, S.X + S.W, S.Y + S.H);
      S.Draw (C2);
   end Draw;

   function Is_Dirty return Boolean is (Scroller.Dirty);

   procedure Clear_Dirty is
   begin
      Scroller.Dirty := False;
   end Clear_Dirty;

   function Handle_Pointer
     (K : Pointer_Kind; X, Y : Trinket.U64) return Boolean
   is
      Old_Top : constant Natural := Terminal_Buffer.View_Top;
   begin
      if Scroller.On_Pointer (K, X, Y) then
         if Terminal_Buffer.View_Top /= Old_Top then
            Terminal_Buffer.Set_Dirty;
         end if;
         Update_Range;
         return True;
      end if;
      return False;
   end Handle_Pointer;

end Terminal_Scroll;
