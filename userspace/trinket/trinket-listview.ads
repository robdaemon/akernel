with Trinket.Images;
with Trinket.Widgets;

--  Trinket listview (milestone 58): a vertical scrolling list of
--  text items with selection. Designed to pair with a Trinket
--  scrollbar in a horizontal group. Milestone 64 added optional
--  per-item icons: once Set_Item_Icon attaches any image, every
--  row grows to Icon_Size + 2 tall with a 16x16 icon cell at the
--  left (the Workbench list-mode look); the app owns the Image
--  objects and must outlive the widget.
package Trinket.Listview is

   type Listview is new Widgets.Widget with private;
   type Any_Listview is access all Listview;

    type Selected_Callback is access procedure (Index : Natural);
    --  1-based index of the newly selected item; 0 = none.

    type Press_Callback is access procedure;
    --  Fired on EVERY pointer press inside the list, even when the
    --  selection does not change (On_Change only fires on change).
    --  M84: the dual-pane fileman activates the clicked pane from
    --  it; re-clicking the already-selected row must count too.

    --  M84c: double-click detection lives in the widget (Bureau
    --  pointer events carry no timestamps, so the widget times
    --  presses itself — mtime ticks at 10 MHz on qemu virt).
    --  Two presses on the SAME row within the threshold fire
    --  On_Double_Click with the row index, after the usual
    --  selection update.
    Double_Click_Ticks : constant U64 := 4_000_000;  --  400 ms

    function New_Listview
      (On_Change : Selected_Callback := null) return Any_Listview;

    procedure Set_On_Press (W : in out Listview; Cb : Press_Callback);

    procedure Set_On_Double_Click
      (W : in out Listview; Cb : Selected_Callback);

   procedure Clear (W : in out Listview);
   --  Remove all items and reset selection/top.

   procedure Add_Item (W : in out Listview; S : String);
   --  Append an item; truncated to the internal width.

   Icon_Size : constant U64 := 16;
   procedure Set_Item_Icon
     (W : in out Listview; I : Positive;
      Icon : access constant Trinket.Images.Image);
   --  Attach an icon to item I (1-based). The first attachment
   --  flips every row to icon height; the list borrows the
   --  image.

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
   overriding procedure Min_Size (W : Listview; MW, MH : out U64);
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
      Icon : access constant Trinket.Images.Image := null;
   end record;
   type Item_Array is array (1 .. Max_Items) of Item_Rec;

   type Listview is new Widgets.Widget with record
      Items     : Item_Array;
      N         : Natural := 0;
      Sel       : Natural := 0;  --  1-based, 0 = none
      Top       : U64 := 0;
       Has_Icons : Boolean := False;
       On_Change : Selected_Callback := null;
       On_Press  : Press_Callback := null;
       On_Double_Click : Selected_Callback := null;
       --  Double-click detection state (M84c): row + mtime of the
       --  last valid press; a press below the last row resets the
       --  row so stale pairs cannot survive a directory change.
       Last_Press_Row  : Natural := 0;
       Last_Press_Time : U64 := 0;
   end record;

end Trinket.Listview;
