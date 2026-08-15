with Trinket;
with Trinket.Widgets;

--  Terminal scrollbar (milestone 58): wraps a Trinket scrollbar
--  that controls the Terminal_Buffer view offset.
package Terminal_Scroll is
   pragma Elaborate_Body;

   Scrollbar_W : constant := 16;

   procedure Init (W, H : Natural);
   --  Place the scrollbar at the right edge of the terminal pane.

   procedure Update_Range;
   --  Resync the scrollbar range/position from the current buffer.

   procedure Draw (C : Trinket.Canvas);

   function Is_Dirty return Boolean;
   procedure Clear_Dirty;

   function Handle_Pointer
     (K : Trinket.Widgets.Pointer_Kind; X, Y : Trinket.U64)
      return Boolean;
end Terminal_Scroll;
