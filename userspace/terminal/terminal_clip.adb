with Aegir_User.Clipboard;
with Terminal_Buffer;
with Trinket.Fonts;
with Trinket.Paint;

package body Terminal_Clip is

   use type Trinket.U64;

   --  Fixed grid device: 8 px cells, Fonts.Line_Height per row
   --  (mirrors the Render loop in terminal.adb).
   Char_W : constant := 8;

   Svc        : Trinket.U64 := 0;
   Active_Sel : Boolean := False;
   Pressed    : Boolean := False;

   --  Selection endpoints as (0-based buffer line, 0-based
   --  column) cells. Anchor is the press cell (stable); Extent
   --  tracks the drag.
   type Cell is record
      L : Natural := 0;
      C : Natural := 0;
   end record;

   Anchor : Cell;
   Extent : Cell;

   --  Normalized (lower-left, upper-right) cell of the selection.
   procedure Bounds (Lo_L, Hi_L, Lo_C, Hi_C : out Natural) is
   begin
      if Anchor.L < Extent.L
        or else (Anchor.L = Extent.L and then Anchor.C <= Extent.C)
      then
         Lo_L := Anchor.L;
         Lo_C := Anchor.C;
         Hi_L := Extent.L;
         Hi_C := Extent.C;
      else
         Lo_L := Extent.L;
         Lo_C := Extent.C;
         Hi_L := Anchor.L;
         Hi_C := Anchor.C;
      end if;
   end Bounds;

   --  Surface pixel -> grid cell, clamped into the visible window
   --  (drag near the bottom edge cannot run past the last visible
   --  row into an invisible selection).
   procedure To_Cell (X, Y : Natural; P : out Cell) is
      Row : Natural;
   begin
      Row := Y / Natural (Trinket.Fonts.Line_Height);
      if Row >= Terminal_Buffer.Rows then
         Row := Terminal_Buffer.Rows - 1;
      end if;
      P.L := Terminal_Buffer.View_Top + Row;
      if P.L >= Terminal_Buffer.Line_Count then
         P.L := Terminal_Buffer.Line_Count - 1;
      end if;
      P.C := X / Char_W;
      if P.C >= Terminal_Buffer.Cols then
         P.C := Terminal_Buffer.Cols - 1;
      end if;
   end To_Cell;

   procedure Set_Service (Svc_In : Trinket.U64) is
   begin
      Svc := Svc_In;
   end Set_Service;

   function Active return Boolean is (Active_Sel);

   function Dragging return Boolean is (Pressed);

   procedure Row_Extent (Line_I : Natural; Col_A, Col_B : out Natural) is
      Lo_L, Hi_L, Lo_C, Hi_C : Natural;
   begin
      Col_A := 1;
      Col_B := 0;
      if not Active_Sel then
         return;
      end if;
      Bounds (Lo_L, Hi_L, Lo_C, Hi_C);
      if Line_I < Lo_L or else Line_I > Hi_L then
         return;
      end if;
      if Lo_L = Hi_L then
         Col_A := Lo_C;
         Col_B := Hi_C;
      elsif Line_I = Lo_L then
         Col_A := Lo_C;
         Col_B := Terminal_Buffer.Cols - 1;
      elsif Line_I = Hi_L then
         Col_A := 0;
         Col_B := Hi_C;
      else
         Col_A := 0;
         Col_B := Terminal_Buffer.Cols - 1;
      end if;
   end Row_Extent;

   procedure Draw_Row_Band
     (C : Trinket.Canvas; Line_I : Natural; Row_Y : Natural)
   is
      A, B    : Natural;
      LH      : constant Trinket.U64 := Trinket.Fonts.Line_Height;
   begin
      Row_Extent (Line_I, A, B);
      if A <= B then
         Trinket.Paint.Fill_Rect
           (C,
            Trinket.U64 (A) * Char_W,
            Trinket.U64 (Row_Y),
            Trinket.U64 (B + 1) * Char_W,
            Trinket.U64 (Row_Y) + LH,
            Trinket.Sel_Blue);
      end if;
   end Draw_Row_Band;

   function Covers (Line_I, Col : Natural) return Boolean is
      A, B : Natural;
   begin
      Row_Extent (Line_I, A, B);
      return A <= B and then Col >= A and then Col <= B;
   end Covers;

   procedure Pointer_Text
     (K : Trinket.Widgets.Pointer_Kind; X, Y : Natural)
   is
      P : Cell;
   begin
      case K is
         when Trinket.Widgets.Press =>
            To_Cell (X, Y, P);
            Anchor := P;
            Extent := P;
            Pressed := True;
            Active_Sel := True;
            Terminal_Buffer.Set_Dirty;
         when Trinket.Widgets.Move =>
            if Pressed then
               To_Cell (X, Y, Extent);
               Terminal_Buffer.Set_Dirty;
            end if;
         when Trinket.Widgets.Release =>
            if not Pressed then
               return;
            end if;
            Pressed := False;
            To_Cell (X, Y, Extent);
            Terminal_Buffer.Set_Dirty;
            if Anchor.L = Extent.L and then Anchor.C = Extent.C then
               --  A click, not a drag: clear any selection.
               Active_Sel := False;
            else
               --  Drag release: copy and keep the band visible.
               Copy;
            end if;
      end case;
   end Pointer_Text;

   procedure Copy is
      Lo_L, Hi_L, Lo_C, Hi_C : Natural;
      First, Last            : Natural := Natural'Last;
      Line                   : String (1 .. Terminal_Buffer.Max_Cols);
      Len                    : Natural;
      N                      : Natural := 0;
      --  Whole-row staging for the clipboard Put. Sized to the
      --  clipboard's own 32 KiB store (Clipboard_Max = Put's
      --  bound): a larger selection is taken as the whole rows
      --  that fit. Static because 32 KiB cannot live on the
      --  process stack (m33a/54 burn).
      Sel : String (1 .. Aegir_User.Clipboard.Clipboard_Max);

      --  0-based inclusive column slice of buffer row L that the
      --  selection covers (Col_A > Col_B: none).
      procedure Row_Slice
        (L : Natural; Col_A, Col_B : out Natural)
      is
      begin
         if Lo_L = Hi_L then
            Col_A := Lo_C;
            Col_B := Hi_C;
         elsif L = Lo_L then
            Col_A := Lo_C;
            Col_B := Terminal_Buffer.Cols - 1;
         elsif L = Hi_L then
            Col_A := 0;
            Col_B := Hi_C;
         else
            Col_A := 0;
            Col_B := Terminal_Buffer.Cols - 1;
         end if;
      end Row_Slice;
   begin
      if not Active_Sel or else Svc = 0 then
         return;
      end if;
      Bounds (Lo_L, Hi_L, Lo_C, Hi_C);
      if Lo_L = Hi_L and then Lo_C = Hi_C then
         return;   --  collapsed to one cell
      end if;

      --  Pass 1: the rows that carry any selected text. Blank
      --  rows at the ends of the span are dropped; interior blank
      --  rows stay in the copy so pasted text lines up.
      for L in Lo_L .. Hi_L loop
         Terminal_Buffer.Get_Line (L, Line, Len);
         if Len > 0 then
            declare
               A, B : Natural;
            begin
               Row_Slice (L, A, B);
               if A <= B and then A < Len then
                  if First = Natural'Last then
                     First := L;
                  end if;
                  Last := L;
               end if;
            end;
         end if;
      end loop;
      if First = Natural'Last then
         return;   --  only blank rows selected
      end if;

      --  Pass 2: assemble whole rows up to the store bound. A
      --  '\n' separates rows; truncation happens between rows so
      --  a partial line never lands on the clipboard.
      for L in First .. Last loop
         Terminal_Buffer.Get_Line (L, Line, Len);
         declare
            A, B  : Natural;
            From  : Natural;
            To    : Natural;
            Add   : Natural;
         begin
            Row_Slice (L, A, B);
            if Len = 0 or else A > B or else A >= Len then
               From := 1;
               To   := 0;   --  interior blank row: LF only
            else
               From := A + 1;
               To   := Natural'Min (B, Len - 1) + 1;
            end if;
            Add := To - From + 1;
            if L < Last then
               Add := Add + 1;   --  trailing separator
            end if;
            if N + Add > Sel'Length then
               exit;             --  store full
            end if;
            for I in From .. To loop
               N := N + 1;
               Sel (N) := Line (I);
            end loop;
            if L < Last then
               N := N + 1;
               Sel (N) := ASCII.LF;
            end if;
         end;
      end loop;
      --  A store-full exit can leave one trailing separator.
      if N > 0 and then Sel (N) = ASCII.LF then
         N := N - 1;
      end if;
      if N > 0 then
         declare
            Ignore : constant Trinket.U64 :=
              Aegir_User.Clipboard.Put (Svc, Sel (1 .. N));
         begin
            null;
         end;
      end if;
   end Copy;

end Terminal_Clip;
