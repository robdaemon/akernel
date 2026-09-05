with Trinket.Widgets;

--  Trinket text editor widget (milestone 57): multiline edit
--  with cursor, selection (click + drag, v4 pointer capture),
--  and vertical scrolling. Fixed character grid (the font is
--  monospace in practice — Font8x8 and the BDFs we ship).
--
--  Line storage is bounded (Max_Lines x Max_Cols) on the HEAP —
--  ~66 KiB would murder the 48 KiB process stack (the m33a/54
--  stack burns).
--
--  The widget owns content + cursor + Top scroll line; the APP
--  wires a Scrollbar: On_Modified (recompute range) and
--  On_Change (Set_Top). Focus is implicit — a Text_Edit
--  consumes every key it understands.
package Trinket.Text_Edit is

   Max_Lines : constant := 512;
   Max_Cols  : constant := 128;

   type Text_Edit is new Widgets.Widget with private;
   type Any_Text_Edit is access all Text_Edit;

   function New_Text_Edit return Widgets.Any_Widget;

   --  Content API (for file load/save).
   procedure Clear (W : in out Text_Edit);
   procedure Append_Line (W : in out Text_Edit; S : String);
   function Line_Count (W : Text_Edit) return Natural;
   function Get_Line (W : Text_Edit; I : Natural) return String;
   function Modified (W : Text_Edit) return Boolean;
   procedure Clear_Modified (W : in out Text_Edit);

    --  Scroll coupling for the app's scrollbar.
    procedure Set_Top (W : in out Text_Edit; T : U64);
    function Top_Line (W : Text_Edit) return U64;
    function Visible_Rows (W : Text_Edit) return U64;

    --  Horizontal scrolling (M87c): a PIXEL offset against the
    --  proportional font. The app wires a horizontal Scrollbar
    --  exactly like the vertical one (sync Max_HOff /
    --  Visible_Width into Set_Range; On_Change -> Set_HOff).
    procedure Set_HOff (W : in out Text_Edit; O : U64);
    function H_Offset (W : Text_Edit) return U64;
    function Max_HOff (W : Text_Edit) return U64;
    --  Widest line's pixel width past the inner width (0 when
    --  every line fits).
    function Visible_Width (W : Text_Edit) return U64;
    --  Inner text width: widget width minus frame and Pad.

    --  Content/cursor hook (M87c): fired after any handled key
    --  and after Clear/Append_Line, so the app can re-sync its
    --  scrollbars (content growth changes Max_HOff / Max_Top;
    --  Ensure_Cursor_Visible changes the positions).
    type Change_Callback is access procedure;
    procedure Set_On_Change
      (W : in out Text_Edit; CB : Change_Callback);

   overriding procedure Draw (W : Text_Edit; C : Canvas);
   overriding procedure Min_Size (W : Text_Edit; MW, MH : out U64);
   overriding function On_Key
     (W : access Text_Edit; Code : U64) return Boolean;
   overriding function On_Pointer
     (W : access Text_Edit; K : Widgets.Pointer_Kind; PX, PY : U64)
      return Boolean;

private

   subtype Line_String is String (1 .. Max_Cols);
   type Line_Rec is record
      Buf : Line_String;
      Len : Natural := 0;
   end record;
   type Lines_Array is array (1 .. Max_Lines) of Line_Rec;
   type Lines_Access is access Lines_Array;

   type Text_Edit is new Widgets.Widget with record
      Lines    : Lines_Access := null;
      N        : Natural := 0;       --  lines in use (>= 1 once
                                     --  initialized)
      Cur_L    : Natural := 1;       --  1-based line
      Cur_C    : Natural := 0;       --  0-based column (insert
                                     --  BEFORE this column)
       Top      : U64 := 0;           --  first visible line (0-based)
       HOff     : U64 := 0;           --  horizontal scroll, pixels
      Sel      : Boolean := False;   --  selection active
      Anch_L   : Natural := 1;
      Anch_C   : Natural := 0;
      Dragging : Boolean := False;
      Dirty_F  : Boolean := False;   --  content modified
      On_Change : Change_Callback := null;
   end record;

end Trinket.Text_Edit;
