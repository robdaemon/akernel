with Trinket.Paint;

package body Trinket.Widgets.Separator is
   use type Trinket.U64;

   --  Named access types at library level: allocators of an
   --  anonymous access type inherit FUNCTION-level accessibility
   --  and the Any_Widget conversion's dynamic accessibility check
   --  fails (the tdemo PROGRAM_ERROR at startup).
   type Separator_Access is access Separator;

   --  Separator

   function New_Separator return Any_Widget is
      S : constant Separator_Access := new Separator;
   begin
      return Any_Widget (S);
   end New_Separator;

   procedure Draw (W : Separator; C : Canvas) is
      Y : constant U64 := W.Y + W.H / 2;
   begin
      if not Intersects (W, C) then
         return;
      end if;
      --  Groove: dark line, light line directly under it.
      Paint.Fill_Rect (C, W.X, Y - 1, W.X + W.W, Y, Bevel_Lo);
      Paint.Fill_Rect (C, W.X, Y, W.X + W.W, Y + 1, Bevel_Hi);
   end Draw;

   procedure Min_Size (W : Separator; MW, MH : out U64) is
      pragma Unreferenced (W);
   begin
      MW := 0;
      MH := 2;
   end Min_Size;


end Trinket.Widgets.Separator;
