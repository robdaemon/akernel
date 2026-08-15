--  Terminal line buffer (milestone 58): circular scrollback for
--  the terminal's text grid. The visible screen is a window into
--  the buffer at View_Top.
package Terminal_Buffer is
   pragma Elaborate_Body;

   Max_Lines : constant := 500;
   Max_Cols  : constant := 256;

   procedure Init (C, R : Natural);

   procedure Put_Char (Ch : Character);
   --  Interpret the line-discipline character and update the
   --  scrollback. Marks the buffer dirty.

   procedure Clear;
   --  Reset to one empty line.

   function Line_Count return Natural;
   function Cols return Natural;
   function Rows return Natural;
   function View_Top return Natural;
   function Max_Top return Natural;
   procedure Set_Top (T : Natural);

   function Current_Line return Natural;
   function Current_Col  return Natural;
   --  Logical cursor position (0-based line index and column in
   --  that line). The current line is always the last line.

   procedure Get_Line (I : Natural; S : out String; Len : out Natural);
   --  I is 0-based from the oldest line. Returns "" if I >= Count.

   function Is_Dirty return Boolean;
   procedure Set_Dirty;
   procedure Clear_Dirty;

end Terminal_Buffer;
