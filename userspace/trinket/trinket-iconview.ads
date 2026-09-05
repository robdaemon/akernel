with Trinket.Images;
with Trinket.Widgets;

--  Trinket iconview (M91): a scrolling grid of icon cells — the
--  Workbench "view by icon" look. Each cell is Cell_W x Cell_H:
--  a 32x32 icon centered on top with a centered label beneath.
--  The column count is derived from the widget width at draw and
--  hit-test time, so a resize REFLOWS the grid for free (no
--  stored layout state). Mirrors Listview: click-select,
--  widget-timed double-click (Bureau pointer events carry no
--  timestamps), arrow-key navigation, and a self-wired scrolled
--  composite. The app owns the Image objects and must outlive
--  the widget.
package Trinket.Iconview is

   type Iconview is new Widgets.Widget with private;
   type Any_Iconview is access all Iconview;

   type Selected_Callback is access procedure (Index : Natural);
   --  1-based index of the newly selected item; 0 = none.

   --  Same widget-timed detection as Listview (M84c): two presses
   --  on the SAME cell within the threshold fire On_Double_Click
   --  after the usual selection update.
   Double_Click_Ticks : constant U64 := 4_000_000;  --  400 ms

   function New_Iconview
     (On_Change : Selected_Callback := null) return Any_Iconview;

   procedure Set_On_Double_Click
     (W : in out Iconview; Cb : Selected_Callback);

   procedure Clear (W : in out Iconview);
   --  Remove all items and reset selection/scroll.

   procedure Add_Item
     (W     : in out Iconview;
      Label : String;
      Icon  : access constant Trinket.Images.Image);
   --  Append an item; the label truncates to the internal width,
   --  the icon is borrowed (null = empty icon cell).

   function Item_Count (W : Iconview) return Natural;

   function Get_Label (W : Iconview; I : Positive) return String;
   --  1-based; returns "" if out of range.

   procedure Set_Selected (W : in out Iconview; I : Natural);
   --  1-based; 0 clears selection. Scrolls the item into view and
   --  fires On_Change if it changed.

   function Selected (W : Iconview) return Natural;

   procedure Set_Top (W : in out Iconview; T : U64);
   --  Pixel scroll offset (no On_Change fire).

   function Top (W : Iconview) return U64;

   function Columns (W : Iconview) return U64;
   --  Cells per row at the current widget width (at least 1).

   function Content_Height (W : Iconview) return U64;
   --  Total grid height in pixels at the current column count.

   function Max_Top (W : Iconview) return U64;
   --  Largest valid pixel scroll offset.

   overriding procedure Draw (W : Iconview; C : Canvas);
   overriding procedure Min_Size (W : Iconview; MW, MH : out U64);
   overriding function On_Key
     (W : access Iconview; Code : U64) return Boolean;
   overriding function On_Pointer
     (W : access Iconview; K : Widgets.Pointer_Kind; PX, PY : U64)
      return Boolean;

   --  Scrolled composite: the iconview with its vertical
   --  scrollbar flush right, self-wired both ways (the bar's Ctx
   --  reaches the content; Draw re-syncs bar metrics first).
   --  IV returns the content handle.
   function New_Scrolled_Icons
     (IV        : out Any_Iconview;
      On_Change : Selected_Callback := null) return Widgets.Any_Widget;

private

   Max_Items   : constant := 512;
   Label_Width : constant := 24;  --  readdir wire cap

   Cell_W : constant U64 := 96;
   Cell_H : constant U64 := 64;
   Icon_Px : constant U64 := 32;

   subtype Label_String is String (1 .. Label_Width);
   type Item_Rec is record
      Text : Label_String;
      Len  : Natural := 0;
      Icon : access constant Trinket.Images.Image := null;
   end record;
   type Item_Array is array (1 .. Max_Items) of Item_Rec;

   type Iconview is new Widgets.Widget with record
      Items     : Item_Array;
      N         : Natural := 0;
      Sel       : Natural := 0;  --  1-based, 0 = none
      Top       : U64 := 0;      --  pixel scroll offset
      On_Change : Selected_Callback := null;
      On_Double_Click : Selected_Callback := null;
      --  Double-click detection state: cell + mtime of the last
      --  valid press; a press outside any cell resets the cell
      --  so stale pairs cannot survive a directory change.
      Last_Press_Cell : Natural := 0;
      Last_Press_Time : U64 := 0;
   end record;

   --  The composite is a Group whose Layout pins the bar flush
   --  (no group spacing) and whose Draw re-syncs bar metrics
   --  from the content first (Set_Range/Set_Pos no-op when
   --  unchanged, so this is free).
   type Scrolled_Icons is new Widgets.Group with record
      IV   : Any_Iconview := null;
      VBar : Widgets.Any_Widget := null;
   end record;
   overriding procedure Layout (W : in out Scrolled_Icons);
   overriding procedure Min_Size (W : Scrolled_Icons; MW, MH : out U64);
   overriding procedure Draw (W : Scrolled_Icons; C : Canvas);

end Trinket.Iconview;
