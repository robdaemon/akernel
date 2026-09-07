with Trinket.Widgets;

--  Trinket columns (milestone 9x): a scrolled, selectable
--  multi-column row list for file-requester-style dialogs —
--  three fixed text columns (Name | Size | Date), a recessed
--  header band, right-aligned size/date, and dir/file rows the
--  app feeds as preformatted strings. Rows are plain text cells:
--  the app owns the semantics (a double-click or Return fires
--  On_Open so a requester can enter a directory; the row index
--  is 1-based). The composite pairs the list with a flush
--  vertical scrollbar (New_Scrolled_Columns), self-wired like
--  Listview's.
package Trinket.Columns is

   type Columns is new Widgets.Widget with private;
   type Any_Columns is access all Columns;

   type Selected_Callback is access procedure (Index : Natural);
   --  1-based index of the newly selected row; 0 = none.

   type Row_Callback is access procedure (Index : Natural);
   --  On_Open: double-click on a row (within Double_Click_Ticks,
   --  same timing rule as Listview) or Return on the selection.

   Double_Click_Ticks : constant U64 := 4_000_000;  --  400 ms

   function New_Columns
     (On_Change : Selected_Callback := null;
      On_Open   : Row_Callback := null) return Any_Columns;

   procedure Clear (W : in out Columns);
   --  Remove all rows and reset selection/top.

   procedure Add_Row
     (W : in out Columns; Name, Size, Date : String;
      Is_Dir : Boolean := False);
   --  Append a row; each cell is truncated to its column width.
   --  Size/Date are drawn right-aligned; a directory row leaves
   --  the size cell empty.

   function Item_Count (W : Columns) return Natural;

   procedure Set_Selected (W : in out Columns; I : Natural);
   --  1-based; 0 clears selection. Ensures visible; fires
   --  On_Change only when the selection changed.

   function Selected (W : Columns) return Natural;

   procedure Set_On_Open (W : in out Columns; Cb : Row_Callback);

   overriding procedure Draw (W : Columns; C : Canvas);
   overriding procedure Min_Size (W : Columns; MW, MH : out U64);
   overriding function On_Key
     (W : access Columns; Code : U64) return Boolean;
   overriding function On_Pointer
     (W : access Columns; K : Widgets.Pointer_Kind; PX, PY : U64)
      return Boolean;

   --  Scrolled composite: the columns list with its flush
   --  vertical scrollbar (the New_Scrolled_List pattern).
   function New_Scrolled_Columns
     (CW       : out Any_Columns;
      On_Change : Selected_Callback := null;
      On_Open   : Row_Callback := null) return Widgets.Any_Widget;

private

   Max_Rows  : constant := 512;
   Max_Cells : constant := 3;

   subtype Cell is String (1 .. 32);
   type Row_Rec is record
      Name  : Cell;
      Name_Len : Natural;
      Size  : Cell;
      Size_Len : Natural;
      Date  : Cell;
      Date_Len : Natural;
      Is_Dir : Boolean := False;
   end record;
   type Row_Array is array (1 .. Max_Rows) of Row_Rec;

   --  Column geometry (px). The name column flexes to the widget
   --  width; size and date are fixed-width and right-aligned.
   Name_X0  : constant U64 := 4;
   Size_W   : constant U64 := 74;   --  9 chars mono + 2
   Date_W   : constant U64 := 90;   --  11 chars mono + 2
   Col_Gap  : constant U64 := 10;

   type Columns is new Widgets.Widget with record
      Rows     : Row_Array;
      N        : Natural := 0;
      Sel      : Natural := 0;  --  1-based, 0 = none
      Top      : U64 := 0;
      On_Change : Selected_Callback := null;
      On_Open  : Row_Callback := null;
      Last_Press_Row  : Natural := 0;
      Last_Press_Time : U64 := 0;
   end record;

   type Scrolled_Columns is new Widgets.Group with record
      CW   : Any_Columns := null;
      VBar : Widgets.Any_Widget := null;
   end record;
   overriding procedure Layout (W : in out Scrolled_Columns);
   overriding procedure Min_Size (W : Scrolled_Columns; MW, MH : out U64);
   overriding procedure Draw (W : Scrolled_Columns; C : Canvas);

end Trinket.Columns;
