with Trinket;
with Trinket.Widgets;

--  Mouse text selection over the terminal's scrollback (M9x) and
--  copy to the system clipboard. State is package-level (static)
--  on purpose: a copy stages up to the clipboard's 32 KiB store,
--  far too large for the process stack.
--
--  The main loop routes pointer events whose PRESS landed in the
--  TEXT area (left of the scrollbar gutter) here; a left drag
--  selects whole grid cells (buffer line, column), release of a
--  real drag copies the text (via the service handle installed
--  with Set_Service) and keeps the band visible, and a click that
--  never dragged clears the selection. Render paints the band
--  under each selected row's glyphs; the Copy menu item re-copies
--  the last selection.
package Terminal_Clip is

   procedure Init (CW, RH : Natural);
   --  Grid metrics: pixels per column (a mono face's advance) and
   --  per row (line height). The terminal calls this after its
   --  font decision; the defaults match the BDF 8px grid.

   procedure Set_Service (Svc_In : Trinket.U64);
   --  Clipboard service handle used by release/menu copies
   --  (0 = none: copies become no-ops).

   function Active return Boolean;
   --  A selection is displayed. Set while dragging, kept after
   --  the release-copy until the next text-area press.

   function Dragging return Boolean;
   --  A text-area drag is in progress (press seen, release not):
   --  the main loop keeps routing pointer events here even when
   --  the pointer leaves the text area, so a drag may end over
   --  the gutter.

   procedure Pointer_Text
     (K : Trinket.Widgets.Pointer_Kind; X, Y : Natural);
   --  Press anchors, Move drags the extent, Release auto-copies a
   --  non-trivial drag or clears on a click. X/Y are surface
   --  pixels, clamped into the visible grid.

   --  Column extent of the selection on buffer row Line_I
   --  (0-based, inclusive). Col_A = 1 / Col_B = 0 when the row
   --  carries no selection.
   procedure Row_Extent (Line_I : Natural; Col_A, Col_B : out Natural);

   --  Paint the band for row Line_I (top at pixel Row_Y) under
   --  its glyphs. No-op for an unselected row. Render calls this
   --  before drawing the row's text.
   procedure Draw_Row_Band
     (C : Trinket.Canvas; Line_I : Natural; Row_Y : Natural);

   --  True when the band covers cell (Line_I, Col) — lets Render
   --  pick a contrasting cursor block on a selected cell.
   function Covers (Line_I, Col : Natural) return Boolean;

   --  Copy the current selection to the clipboard (no-op without
   --  a selection or a service handle). Whole rows, LF-joined;
   --  the buffer never stores trailing blanks so they cannot
   --  leak into the copy. A selection bigger than the clipboard
   --  store is taken as the whole rows that fit.
   procedure Copy;

end Terminal_Clip;
