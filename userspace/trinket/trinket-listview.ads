with Trinket.Widgets;

--  Trinket listview (milestone 58): a vertical scrolling list of
--  text items with selection. Designed to pair with a Trinket
--  scrollbar in a horizontal group.
package Trinket.Listview is

   type Listview is new Widgets.Widget with private;
   type Any_Listview is access all Listview;

   type Selected_Callback is access procedure (Index : Natural);
   --  1-based index of the newly selected item; 0 = none.

   function New_Listview
     (On_Change : Selected_Callback := null) return Any_Listview;

   procedure Clear (W : in out Listview);
   --  Remove all items and reset selection/top.

   procedure Add_Item (W : in out Listview; S : String);
   --  Append an item; truncated to the internal width.

   function Item_Count (W : Listview) return Natural;

   function Get_Item (W : Listview; I : Positive) return String;
   --  1-based; returns "" if out of range.

   procedure Set_Selected (W : in out Listview; I : Natural);
   --  1-based; 0 clears selection. Ensures the selected item is
   --  visible and fires On_Change if it changed.

   function Selected (W : Listview) return Natural;

   procedure Set_Top (W : in out Listview; T : U64);
   --  Set the first visible row index (no On_Change fire).

   function Top (W : Listview) return U64;

   function Visible_Rows (W : Listview) return U64;
   --  Rows that fit in the current widget height (at least 1).

   function Max_Top (W : Listview) return U64;
   --  Largest valid Top value given the current item count and
   --  widget height.

   overriding procedure Draw (W : Listview; C : Canvas);
   overriding function On_Key
     (W : access Listview; Code : U64) return Boolean;
   overriding function On_Pointer
     (W : access Listview; K : Widgets.Pointer_Kind; PX, PY : U64)
      return Boolean;

private

   Max_Items  : constant := 512;
   Item_Width : constant := 64;

   subtype Item_String is String (1 .. Item_Width);
   type Item_Rec is record
      Text : Item_String;
      Len  : Natural;
   end record;
   type Item_Array is array (1 .. Max_Items) of Item_Rec;

   type Listview is new Widgets.Widget with record
      Items     : Item_Array;
      N         : Natural := 0;
      Sel       : Natural := 0;  --  1-based, 0 = none
      Top       : U64 := 0;
      On_Change : Selected_Callback := null;
   end record;

end Trinket.Listview;
