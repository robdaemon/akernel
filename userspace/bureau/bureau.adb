with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Display;
with Akernel_User.Window;
with Font8x8;

--  Bureau: the compositor / window server. Spawned by the device
--  manager from Sys:System/Bureau (milestone 29). Grant ABI
--  (3 handles): 1 = console endpoint (Send, badged),
--  2 = display service endpoint (Send), 3 = window service
--  endpoint (Receive).
--
--  Bureau ALLOCATES the compositing buffer (caps move caller ->
--  callee only), pushes its chunk caps to the display service
--  (Op_Set_Buffer), commits (scanout backing re-attaches onto
--  Bureau's pages), renders the desktop + screen bar, and pushes
--  frames with Op_Present. Workbench-3.x-style gadtools look:
--  gray palette, white/dark 3D bevels, blue ACTIVE title bar.
--
--  Window protocol v2 (milestone 30, slice a): up to Max_Win
--  windows. Each client Surface_Create takes a slot with its own
--  geometry (cascade placement), surface chunk caps, input
--  endpoint (focused keys) and title. Compositing is band-based:
--  every change repaints a clipped absolute band in z-order
--  (desktop -> windows bottom-to-top -> screen bar), then one
--  Present; the terminal's scroll path stays a narrow band. The
--  WHOLE display stack logs via Debug_Put_Line only.

procedure Bureau is
   use Akernel_User.Syscalls;
   use type U64;
   use type Interfaces.Unsigned_8;

   Console_EP : constant U64 := 1;
   Display_EP : constant U64 := 2;
   Win_Svc    : constant U64 := 3;

   Buf_VA   : constant U64 := 16#6000_0000#;
   --  Per-slot client surface maps: 4 MiB stride starting here.
   Surf_VA0 : constant U64 := 16#6800_0000#;
   Surf_Slot_Stride : constant U64 := 16#40_0000#;
   --  Per-slot client input-queue maps (v3): one page each.
   Queue_VA0 : constant U64 := 16#6A00_0000#;

   Max_W : constant := 1024;
   Max_H : constant := 768;
   Max_Objects : constant := (Max_W * Max_H * 4) / 4096 / 64;  --  12

   Width   : U64;
   Height  : U64;
   Stride  : U64;  --  bytes per row
   Pages   : U64;
   Objects : U64;

   Obj_Caps : array (0 .. Max_Objects - 1) of U64 := (others => 0);

   type Pixel_Array is
     array (U64 range 0 .. Max_W * Max_H - 1) of Interfaces.Unsigned_32
     with Volatile_Components;
   Buf : Pixel_Array
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (Buf_VA));

   subtype Pixel is Interfaces.Unsigned_32;

   --  Workbench-3.x-ish palette (AARRGGBB; B8G8R8A8 little-endian
   --  means the u32 low byte is BLUE — the format name's channel
   --  order is memory byte order). Burned the OTHER way first: a
   --  screendump decoder that swapped R/B when reconstructing
   --  pixels from the PPM made a correct blue title "read as"
   --  red; "fixing" the palette then produced a REAL salmon
   --  title the buggy decoder re-confirmed as blue. Decode PPM
   --  bytes straight (R,G,B) and trust the user's eyes over the
   --  script.
   Desktop    : constant Pixel := 16#FFA0_A0A4#;
   Bar_Face   : constant Pixel := 16#FFC0_C0C4#;
   Win_Face   : constant Pixel := 16#FFC0_C0C4#;
   Bevel_Hi   : constant Pixel := 16#FFFF_FFFF#;
   Bevel_Lo   : constant Pixel := 16#FF40_4040#;
   Border     : constant Pixel := 16#FF10_1010#;
   Title_Blue : constant Pixel := 16#FF60_68B0#;
   Title_Gray : constant Pixel := 16#FF8C_8C90#;
   Title_Text : constant Pixel := 16#FFFF_FFFF#;
   Title_Dim  : constant Pixel := 16#FF20_2020#;
   Pane       : constant Pixel := 16#FFF8_F8F8#;
   Text_Dark  : constant Pixel := 16#FF20_2020#;

   Bar_H    : constant := 18;   --  screen bar height
   Title_H  : constant := 20;   --  window title bar height
   Frame    : constant := 4;    --  window frame thickness

   Result : U64;

   ------------------------------------------------------------------
   --  Window protocol v2 state: slot table + z-order
   ------------------------------------------------------------------

   package Win renames Akernel_User.Window;

    --  4 boot windows (demo/tdemo/fileman/terminal) + headroom —
    --  4 was SILENTLY FULL at boot (a 5th window, e.g. Edit from
    --  the shell, got Status_No_Slot; the m34/m38 table burn).
    Max_Win : constant := 6;
    --  16 chunks = 4 MiB = exactly the Surf_Slot_Stride window.
    --  Headroom added WITH the v5 zoom consumer: a zoomed pane
    --  (1016x721 @ 1024x768) needs 12 chunks; 8 silently
    --  rejected the resize with Status_No_Slot.
    Surf_Max_Objects : constant := 16;
   type Cap_Set is array (0 .. Surf_Max_Objects - 1) of U64;

   --  Milestone 61: per-window menu tree, COPIED out of the
   --  client's serialized page by Op_Set_Menus (Bureau never
   --  re-reads client memory). Wire layout in
   --  akernel_user-window.ads.
   Max_Menus : constant := 8;
   Max_Items : constant := 32;  --  total across all menus

   type Menu_Rec is record
      Title     : String (1 .. 16) := (others => ' ');
      Title_Len : Natural := 0;
      First     : Natural := 0;   --  0-based into Items
      Count     : Natural := 0;
   end record;

   type Item_Rec is record
      Label     : String (1 .. 24) := (others => ' ');
      Label_Len : Natural := 0;
      Id        : U64 := 0;
      Disabled  : Boolean := False;
   end record;

   type Menu_Table is array (1 .. Max_Menus) of Menu_Rec;
   type Item_Table is array (1 .. Max_Items) of Item_Rec;

   type Window_Rec is record
      Used     : Boolean := False;
      Id       : U64 := 0;
      X, Y     : U64 := 0;   --  frame origin
      FW, FH   : U64 := 0;   --  frame size (pane + chrome)
      PW, PH   : U64 := 0;   --  pane = surface size
      Pages    : U64 := 0;
      Got      : Natural := 0;
      Mapped   : Boolean := False;
      Caps     : Cap_Set := (others => 0);
      --  v3 async input: client's one-page event queue (mapped
      --  RW at Queue_VA (slot)) + its thread-bound notification
      --  (Write). Bureau enqueues focused keys and signals; it
      --  never calls the client.
      Queue_Cap : U64 := 0;
      Ntfn_Cap  : U64 := 0;
      Title    : String (1 .. 40) := (others => ' ');
      Title_Len : Natural := 0;
       --  Milestone 61: declared menus (Op_Set_Menus).
       Menu_Count : Natural := 0;
       Menus      : Menu_Table;
       Items      : Item_Table;
       --  v5 zoom: Resizable = client handles kind-5 resize
       --  events (create flags bit 0). Zoomed/Save_* = the
       --  toggle's saved rect; Pend_* + Resize_Pending = the
       --  target position awaiting the client's
       --  Op_Surface_Resize ack (geometry is applied ONLY at
       --  ack — a client that never answers leaves the window
       --  untouched).
       Resizable      : Boolean := False;
       Zoomed         : Boolean := False;
       Resize_Pending : Boolean := False;
       Save_X, Save_Y : U64 := 0;
       Save_PW, Save_PH : U64 := 0;
       Pend_X, Pend_Y : U64 := 0;
    end record;

   Wins : array (1 .. Max_Win) of Window_Rec;
   Z    : array (1 .. Max_Win) of Natural := (others => 0);
   Z_N  : Natural := 0;                 --  used entries in Z
   Focus : Natural := 0;                --  slot with the keys
   Next_Id : U64 := 0;

   function Slot_Of (Id : U64) return Natural is
   begin
      for S in 1 .. Max_Win loop
         if Wins (S).Used and then Wins (S).Id = Id then
            return S;
         end if;
      end loop;
      return 0;
   end Slot_Of;

   --  Clamped at slot 1: callers overlay the queue BEFORE their
   --  guard can run (overlay addresses elaborate at call entry),
   --  so a 0 (no focus/capture) must not overflow U64 (Slot - 1)
   --  — the m57 bureau death on an early tablet event.
   function Queue_VA (Slot : Natural) return U64 is
     (Queue_VA0 + U64 (Natural'Max (Slot, 1) - 1) * 4096);

   --  v3 input queue word view (layout in akernel_user-window.ads).
   type Word_Array is array (U64 range 0 .. 511) of U64
     with Volatile_Components;

   function Surf_VA (Slot : Natural) return U64 is
     (Surf_VA0 + U64 (Natural'Max (Slot, 1) - 1) *
        Surf_Slot_Stride);

   --  Pane rectangle of a slot (absolute coords).
   function Pane_X (S : Natural) return U64 is (Wins (S).X + Frame);
   function Pane_Y (S : Natural) return U64 is
     (Wins (S).Y + Frame + Title_H);

    --  Raw word reply (same pattern as the display driver). Caps
    --  are cleared (m75): replies transfer them now, and request
    --  caps (queue/ntfn/object) sit live in the buffer.
    procedure Win_Reply
      (Reply_H : U64; Req_Label : U64; W0, W1, W2, W3, W4 : U64) is
    begin
       Message.Label := Req_Label;
       Message.Words (0) := W0;
       Message.Words (1) := W1;
       Message.Words (2) := W2;
       Message.Words (3) := W3;
       Message.Words (4) := W4;
       Message.Words (5) := 0;
       Message.Caps := (others => 0);
       if IPC_Reply (Reply_H) /= IPC_Ok then
         Debug_Put_Line ("bureau reply failed");
         Process_Exit;
      end if;
   end Win_Reply;

   ------------------------------------------------------------------
   --  Cursor state (bodies below; Composite_Band erases the sprite
   --  BEFORE painting an intersecting band and redraws after —
   --  saving the under-rect while Buf still holds sprite pixels
   --  ghosts the arrow, the milestone-32 artifacting burn)
   ------------------------------------------------------------------

   Cur_W : constant := 10;
   Cur_H : constant := 16;
   Cur_X   : U64 := 0;
   Cur_Y   : U64 := 0;
   Cur_Vis : Boolean := False;
   procedure Cursor_Draw (NX, NY : U64);
   procedure Cursor_Erase;

   Prev_Buttons : U64 := 0;
   --  Title-bar drag state (slice c): grabbed slot + pointer
   --  offset inside the window frame at grab time.
   Drag_Slot : Natural := 0;
   Drag_DX   : U64 := 0;
   Drag_DY   : U64 := 0;
    --  Pointer capture (milestone 57, protocol v4): a press inside
    --  a window's CONTENT captures the pointer — moves and the
    --  final release keep flowing to that window (coordinates
    --  clamped to content bounds) until buttons go 0, so a client
    --  drag (scrollbar knob, text selection) survives leaving the
    --  content and the release can never be lost.
    Capture   : Natural := 0;
    --  Gadget presses are Bureau's: set by Pointer_Press on a
    --  close/depth/zoom press, cleared when buttons go 0. While
    --  set, nothing is captured or forwarded — a send-to-back
    --  moves the focus, and without this the REST of the gesture
    --  (moves with button 1 still held) would retarget at the new
    --  front window, whose client would synthesize a press edge
    --  it never earned.
    Eat_Gesture : Boolean := False;

   ------------------------------------------------------------------
   --  Milestone 61: Amiga screen-bar menus. The RIGHT mouse button
   --  is Bureau's (window content never sees it): RMB down opens
   --  the focused window's bar; held = classic drag-select
   --  (M_Tracking, release over an item picks); released anywhere
   --  else the bar STAYS open (M_Sticky — touchpads) with hover
   --  switching dropdowns, left-click picking, and left-click
   --  elsewhere / RMB again / Esc / focus loss dismissing. While
   --  the menu is active Bureau consumes ALL pointer events.
   ------------------------------------------------------------------

   type Menu_Mode_T is (M_Hidden, M_Tracking, M_Sticky);
   Menu_Mode   : Menu_Mode_T := M_Hidden;
   Menu_Slot   : Natural := 0;   --  window owning the open menu
   Active_Menu : Natural := 0;   --  1..Menu_Count, 0 = bar only
   Hot_Item    : Natural := 0;   --  1-based into Items, 0 = none
   Title_X     : array (1 .. Max_Menus) of U64 := (others => 0);
   Title_W     : array (1 .. Max_Menus) of U64 := (others => 0);
   --  Scratch map for the client's serialized menu page.
   Menu_VA : constant U64 := 16#6A10_0000#;

   procedure Open_Menu;
   procedure Dismiss_Menu;
   procedure Menu_Hover (PX, PY : U64);
   procedure Pick_Menu;
   procedure Update_Clock;

   --  Bar clock (RTC, syscall 34): HH:MM right-justified beside
   --  the depth gadget. Painted by Paint_Band from Clock_Text;
   --  Update_Clock refreshes on every service-loop wake (Bureau
   --  blocks in Receive — an idle desktop's clock freezes until
   --  the next event; noted in NEXT.md).
   Clock_Text : String (1 .. 5) := "--:--";
   Clock_Min  : U64 := U64'Last;
   Clock_X0   : constant := 72;  --  Width - Clock_X0 .. - gadget

   --  RMB acknowledgment: with no menu to show (focused window
   --  declared none), the screen title inverts while RMB is
   --  held — a visible "I saw it; nothing here" instead of a
   --  silent no-op (Amiga reveals the screen bar; ours is
   --  persistent, so it needs a cue).
   Bar_Ack : Boolean := False;

   ------------------------------------------------------------------
   --  Pixel plumbing. All drawing is clipped to the active band
   --  (Clip_*) AND the screen.
   ------------------------------------------------------------------

   Clip_X0 : U64 := 0;
   Clip_Y0 : U64 := 0;
   Clip_X1 : U64 := Max_W;
   Clip_Y1 : U64 := Max_H;

   procedure Set_Pixel (X, Y : U64; Color : Pixel) is
   begin
      if X < Width and then Y < Height
        and then X >= Clip_X0 and then X < Clip_X1
        and then Y >= Clip_Y0 and then Y < Clip_Y1
      then
         Buf (Y * (Stride / 4) + X) := Color;
      end if;
   end Set_Pixel;

   procedure Fill_Rect (X0, Y0, X1, Y1 : U64; Color : Pixel) is
      Row0 : constant U64 := U64'Max (U64'Min (Y0, Height), Clip_Y0);
      Row1 : constant U64 := U64'Min (U64'Min (Y1, Height), Clip_Y1);
      Col0 : constant U64 := U64'Max (U64'Min (X0, Width), Clip_X0);
      Col1 : constant U64 := U64'Min (U64'Min (X1, Width), Clip_X1);
   begin
      if Row1 <= Row0 or else Col1 <= Col0 then
         return;
      end if;
      for Y in Row0 .. Row1 - 1 loop
         for X in Col0 .. Col1 - 1 loop
            Buf (Y * (Stride / 4) + X) := Color;
         end loop;
      end loop;
   end Fill_Rect;

   --  font8x8: bit 0 is the LEFTMOST pixel (burned in milestone
   --  27b — the upstream header comment lies).
   procedure Draw_Char
     (PX, PY  : U64;
      Ch      : Character;
      FG, BG  : Pixel;
      Stretch : U64 := 2)
   is
      Bits : Font8x8.U8;
   begin
      for R in 0 .. 7 loop
         if Ch in ' ' .. '~' then
            Bits := Font8x8.Font (Ch) (R);
         else
            Bits := Font8x8.Font ('?') (R);
         end if;
         for Rep in 0 .. Stretch - 1 loop
            for B in 0 .. 7 loop
               if (Interfaces.Shift_Right (Bits, B) and 1) = 1 then
                  Set_Pixel (PX + U64 (B), PY + U64 (R) * Stretch + Rep,
                             FG);
               else
                  Set_Pixel (PX + U64 (B), PY + U64 (R) * Stretch + Rep,
                             BG);
               end if;
            end loop;
         end loop;
      end loop;
   end Draw_Char;

   procedure Draw_Text
     (PX, PY  : U64;
      S       : String;
      FG, BG  : Pixel;
      Stretch : U64 := 2)
   is
   begin
      for I in S'Range loop
         Draw_Char (PX + U64 (I - S'First) * 8, PY, S (I),
                    FG, BG, Stretch);
      end loop;
   end Draw_Text;

   --  Gadtools 3D bevel: raised = white top/left + dark
   --  bottom/right; recessed = inverse.
   procedure Bevel (X0, Y0, X1, Y1 : U64; Raised : Boolean := True) is
      Hi : constant Pixel := (if Raised then Bevel_Hi else Bevel_Lo);
      Lo : constant Pixel := (if Raised then Bevel_Lo else Bevel_Hi);
   begin
      Fill_Rect (X0, Y0, X1, Y0 + 1, Hi);        --  top
      Fill_Rect (X0, Y0, X0 + 1, Y1, Hi);        --  left
      Fill_Rect (X0, Y1 - 1, X1, Y1, Lo);        --  bottom
      Fill_Rect (X1 - 1, Y0, X1, Y1, Lo);        --  right
   end Bevel;

    --  WB-style gadget glyphs so the three title gadgets read
    --  apart: close = raised mini-box, zoom = single square
    --  outline, depth = two overlapping squares (front one
    --  filled, lower-left).
    type Gadget_Kind is (Gad_Close, Gad_Zoom, Gad_Depth);

    procedure Draw_Gadget
      (GX, GY, Size : U64; Kind : Gadget_Kind;
       Dim : Boolean := False)
    is
       GS : constant U64 := Size / 2 - 2;  --  glyph box size
       CX : constant U64 := GX + (Size - GS) / 2;
       CY : constant U64 := GY + (Size - GS) / 2;
       --  Ghosted (non-resizable) gadgets draw the glyph dim.
       GC : constant Pixel := (if Dim then Title_Gray else Text_Dark);
       procedure Outline (X0, Y0, S : U64) is
       begin
          Fill_Rect (X0, Y0, X0 + S, Y0 + 1, GC);
          Fill_Rect (X0, Y0 + S - 1, X0 + S, Y0 + S, GC);
          Fill_Rect (X0, Y0, X0 + 1, Y0 + S, GC);
          Fill_Rect (X0 + S - 1, Y0, X0 + S, Y0 + S, GC);
       end Outline;
    begin
       Fill_Rect (GX, GY, GX + Size, GY + Size, Win_Face);
       Bevel (GX, GY, GX + Size, GY + Size);
       case Kind is
          when Gad_Close =>
             Fill_Rect (CX, CY, CX + GS, CY + GS, Win_Face);
             Bevel (CX, CY, CX + GS, CY + GS);
          when Gad_Zoom =>
             Outline (CX, CY, GS);
          when Gad_Depth =>
             Outline (CX + 3, CY - 1, GS);   --  back, upper-right
             Fill_Rect (CX - 1, CY + 1, CX - 1 + GS, CY + 1 + GS,
                        Win_Face);
             Outline (CX - 1, CY + 1, GS);   --  front, lower-left
       end case;
    end Draw_Gadget;

   ------------------------------------------------------------------
   --  Band compositor: desktop -> windows (bottom to top) -> bar
   ------------------------------------------------------------------

   procedure Draw_Window (S : Natural) is
      FX : constant U64 := Wins (S).X;
      FY : constant U64 := Wins (S).Y;
      FW : constant U64 := Wins (S).FW;
      FH : constant U64 := Wins (S).FH;
      Title_Y : constant U64 := FY + Frame;
      Title_C : constant Pixel :=
        (if S = Focus then Title_Blue else Title_Gray);
      Text_C  : constant Pixel :=
        (if S = Focus then Title_Text else Title_Dim);
      Surf : Pixel_Array
        with Address => System.Storage_Elements.To_Address
          (System.Storage_Elements.Integer_Address (Surf_VA (S)));
      Stride_Px : constant U64 := Stride / 4;
      BX0, BY0, BX1, BY1, SW, SH : U64;
   begin
      --  Frame: 2px dark border + raised bevel ring.
      Fill_Rect (FX, FY, FX + FW, FY + FH, Border);
      Bevel (FX + 2, FY + 2, FX + FW - 2, FY + FH - 2);
      --  Title bar + gadgets + title text. Gadgets are the full
      --  title-band height, flush against the frame's inner
      --  edges (Workbench): close left; zoom + depth right,
      --  depth outermost. Silly-narrow windows skip the right
      --  pair rather than overlap the title.
      Fill_Rect (FX + Frame, Title_Y,
                 FX + FW - Frame, Title_Y + Title_H, Title_C);
      Draw_Gadget (FX + Frame, Title_Y, Title_H, Gad_Close);
      if FW >= 2 * Frame + 3 * Title_H then
         Draw_Gadget (FX + FW - Frame - 2 * Title_H, Title_Y,
                      Title_H, Gad_Zoom, Dim => not Wins (S).Resizable);
         Draw_Gadget (FX + FW - Frame - Title_H, Title_Y,
                      Title_H, Gad_Depth);
      end if;
      if Wins (S).Title_Len > 0 then
         Draw_Text (FX + Frame + Title_H + 8, Title_Y + 2,
                    Wins (S).Title (1 .. Wins (S).Title_Len),
                    Text_C, Title_C);
      end if;
      --  Pane: surface pixels if mapped, blank pane color else.
      if Wins (S).Mapped then
         BX0 := U64'Max (Pane_X (S), Clip_X0);
         BY0 := U64'Max (Pane_Y (S), Clip_Y0);
         BX1 := U64'Min (Pane_X (S) + Wins (S).PW, Clip_X1);
         BY1 := U64'Min (Pane_Y (S) + Wins (S).PH, Clip_Y1);
         SW := Wins (S).PW;
         SH := Wins (S).PH;
         if BX1 > BX0 and then BY1 > BY0 then
            for Row in BY0 .. BY1 - 1 loop
               for Col in BX0 .. BX1 - 1 loop
                  Buf (Row * Stride_Px + Col) :=
                    Surf ((Row - Pane_Y (S)) * SW +
                            (Col - Pane_X (S)));
               end loop;
            end loop;
         end if;
      else
         Fill_Rect (Pane_X (S), Pane_Y (S),
                    Pane_X (S) + Wins (S).PW, Pane_Y (S) + Wins (S).PH,
                    Pane);
      end if;
   end Draw_Window;

   ------------------------------------------------------------------
   --  Milestone 61: menu geometry + chrome drawing. The panel
   --  functions are only valid while Active_Menu /= 0 (callers
   --  guard — indexing Menus (0) would raise).
   ------------------------------------------------------------------

   Item_H : constant := 12;      --  dropdown row height
   Panel_Top : constant := Bar_H + 2;

   function Panel_W return U64 is
      W : Window_Rec renames Wins (Menu_Slot);
      M : Menu_Rec renames W.Menus (Active_Menu);
      Max_L : Natural := 0;
   begin
      for K in M.First + 1 .. M.First + M.Count loop
         Max_L := Natural'Max (Max_L, W.Items (K).Label_Len);
      end loop;
      return U64 (Max_L) * 8 + 28;
   end Panel_W;

   function Panel_X return U64 is
      Raw : constant U64 :=
        (if Title_X (Active_Menu) > 6 then Title_X (Active_Menu) - 6
         else 0);
   begin
      return U64'Min (Raw, Width - Panel_W);
   end Panel_X;

   function Panel_H return U64 is
     (U64 (Wins (Menu_Slot).Menus (Active_Menu).Count) * Item_H + 6);

   --  Bar menu titles + the dropped panel, drawn after the bar
   --  so they sit above every window (the cursor stays on top —
   --  sprite handling in Composite_Band).
   procedure Draw_Menus is
   begin
      if Menu_Mode = M_Hidden then
         return;
      end if;
      declare
         W : Window_Rec renames Wins (Menu_Slot);
      begin
      for M in 1 .. W.Menu_Count loop
         if M = Active_Menu then
            Fill_Rect (Title_X (M), 1,
                       Title_X (M) + Title_W (M), Bar_H - 1,
                       Title_Blue);
            Draw_Text (Title_X (M) + 8, 5,
                       W.Menus (M).Title (1 .. W.Menus (M).Title_Len),
                       Title_Text, Title_Blue, Stretch => 1);
         else
            Draw_Text (Title_X (M) + 8, 5,
                       W.Menus (M).Title (1 .. W.Menus (M).Title_Len),
                       Text_Dark, Bar_Face, Stretch => 1);
         end if;
      end loop;
      if Active_Menu /= 0 then
         declare
            PX0 : constant U64 := Panel_X;
            PW  : constant U64 := Panel_W;
            M   : Menu_Rec renames W.Menus (Active_Menu);
            RY  : U64;
            Idx : Natural;
         begin
            Fill_Rect (PX0, Panel_Top, PX0 + PW, Panel_Top + Panel_H,
                       Bar_Face);
            Bevel (PX0, Panel_Top, PX0 + PW, Panel_Top + Panel_H);
            for K in 0 .. M.Count - 1 loop
               Idx := M.First + K + 1;
               RY := Panel_Top + 3 + U64 (K) * Item_H;
               if Idx = Hot_Item and then not W.Items (Idx).Disabled
               then
                  Fill_Rect (PX0 + 2, RY, PX0 + PW - 2, RY + Item_H,
                             Title_Blue);
                  Draw_Text (PX0 + 14, RY + 2,
                             W.Items (Idx).Label
                               (1 .. W.Items (Idx).Label_Len),
                             Title_Text, Title_Blue, Stretch => 1);
               elsif W.Items (Idx).Disabled then
                  Draw_Text (PX0 + 14, RY + 2,
                             W.Items (Idx).Label
                               (1 .. W.Items (Idx).Label_Len),
                             Title_Gray, Bar_Face, Stretch => 1);
               else
                  Draw_Text (PX0 + 14, RY + 2,
                             W.Items (Idx).Label
                               (1 .. W.Items (Idx).Label_Len),
                             Text_Dark, Bar_Face, Stretch => 1);
               end if;
            end loop;
         end;
      end if;
      end;
   end Draw_Menus;

   --  Repaint the clipped absolute band in stacking order, then
   --  present it once. Caller sets the clip implicitly.
   procedure Paint_Band (X0, Y0, X1, Y1 : U64) is
   begin
      Clip_X0 := X0;
      Clip_Y0 := Y0;
      Clip_X1 := U64'Min (X1, Width);
      Clip_Y1 := U64'Min (Y1, Height);
      if Clip_X1 <= Clip_X0 or else Clip_Y1 <= Clip_Y0 then
         return;
      end if;
      Fill_Rect (0, 0, Width, Height, Desktop);
      for I in 1 .. Z_N loop
         declare
            S : constant Natural := Z (I);
         begin
            if Wins (S).X < Clip_X1
              and then Wins (S).X + Wins (S).FW > Clip_X0
              and then Wins (S).Y < Clip_Y1
              and then Wins (S).Y + Wins (S).FH > Clip_Y0
            then
               Draw_Window (S);
            end if;
         end;
      end loop;
       --  Screen bar (always on top) + right-side depth gadget,
       --  RTC clock beside it (milestone 61), then the menu
       --  titles/dropdown when one is active. While a menu is
       --  open the "Bureau" screen title is REPLACED by the menu
       --  titles (Workbench: the bar shows menus, not the screen
       --  name); Bar_Ack only exists when no menu can open.
       Fill_Rect (0, 0, Width, Bar_H, Bar_Face);
       Fill_Rect (0, Bar_H, Width, Bar_H + 1, Bevel_Lo);
       if Menu_Mode = M_Hidden then
          if Bar_Ack then
             Fill_Rect (4, 1, 60, Bar_H - 1, Title_Blue);
             Draw_Text (8, 5, "Bureau", Title_Text, Title_Blue,
                        Stretch => 1);
          else
             Draw_Text (8, 5, "Bureau", Text_Dark, Bar_Face,
                        Stretch => 1);
          end if;
       end if;
       Draw_Gadget (Width - 24, 1, 16, Gad_Depth);
      Draw_Text (Width - Clock_X0, 5, Clock_Text,
                 Text_Dark, Bar_Face, Stretch => 1);
      Draw_Menus;
      Clip_X0 := 0;
      Clip_Y0 := 0;
      Clip_X1 := Max_W;
      Clip_Y1 := Max_H;
   end Paint_Band;

   --  Present a band, redrawing the cursor if the band hit it.
   procedure Present_Band (X, Y, W, H : U64) is
   begin
      if W = 0 or else H = 0 then
         return;
      end if;
      Result := Akernel_User.Display.Present (Display_EP, X, Y, W, H);
   end Present_Band;

   --  Composite one band: erase the cursor FIRST when the band
   --  intersects the sprite rect (so Paint_Band can never leave
   --  sprite pixels inside a partially-covered under-rect — the
   --  next Cursor_Draw saves a clean under-rect), repaint, then
   --  redraw the cursor on top.
   procedure Composite_Band (X0, Y0, X1, Y1 : U64) is
      Hit : constant Boolean := Cur_Vis
        and then X0 < Cur_X + Cur_W
        and then Cur_X < X1
        and then Y0 < Cur_Y + Cur_H
        and then Cur_Y < Y1;
   begin
      if Hit then
         Cursor_Erase;
      end if;
      Paint_Band (X0, Y0, X1, Y1);
      Present_Band (X0, Y0, X1 - X0, Y1 - Y0);
      if Hit then
         Cursor_Draw (Cur_X, Cur_Y);
      end if;
   end Composite_Band;

   procedure Repaint_Window (S : Natural) is
   begin
      Composite_Band (Wins (S).X, Wins (S).Y,
                      Wins (S).X + Wins (S).FW,
                      Wins (S).Y + Wins (S).FH);
   end Repaint_Window;

   --  Title band of a slot (for focus-color changes).
   procedure Repaint_Title (S : Natural) is
   begin
      Composite_Band (Wins (S).X, Wins (S).Y,
                      Wins (S).X + Wins (S).FW,
                      Wins (S).Y + Frame + Title_H);
   end Repaint_Title;

   --  Move a slot to the top of the z-order.
   procedure Raise_Slot (S : Natural) is
      Idx : Natural := 0;
   begin
      for I in 1 .. Z_N loop
         if Z (I) = S then
            Idx := I;
            exit;
         end if;
      end loop;
      if Idx = 0 then
         return;
      end if;
       for I in Idx .. Z_N - 1 loop
          Z (I) := Z (I + 1);
       end loop;
       Z (Z_N) := S;
    end Raise_Slot;

    --  Move a slot to the bottom of the z-order (depth gadget).
    procedure Lower_Slot (S : Natural) is
       Idx : Natural := 0;
    begin
       for I in 1 .. Z_N loop
          if Z (I) = S then
             Idx := I;
             exit;
          end if;
       end loop;
       if Idx = 0 then
          return;
       end if;
       for I in reverse 2 .. Idx loop
          Z (I) := Z (I - 1);
       end loop;
       Z (1) := S;
    end Lower_Slot;

   procedure Focus_Slot (S : Natural) is
      Old : constant Natural := Focus;
   begin
      if S = Old then
         return;
      end if;
      Focus := S;
      if Old /= 0 and then Wins (Old).Used then
         Repaint_Title (Old);
      end if;
      if S /= 0 then
         Repaint_Title (S);
      end if;
   end Focus_Slot;

   ------------------------------------------------------------------
   --  Seat: focused-window input + software cursor (the
   --  arch-independent fallback by design; virtio hw cursor ops
   --  stay reserved in the display protocol)
   ------------------------------------------------------------------

   --  Classic up-left arrow: '#' outline, 'O' fill, '.' clear.
   Arrow : constant array (0 .. Cur_H - 1) of String (1 .. Cur_W) :=
     ("#.........",
      "##........",
      "#O#.......",
      "#OO#......",
      "#OOO#.....",
      "#OOOO#....",
      "#OOOOO#...",
      "#OOOOOO#..",
      "#OOOOOOO#.",
      "#OOOOOOOO#",
      "#OOOOO####",
      "#OO#OO#...",
      "#O#.#OO#..",
      "##..#OO#..",
      "#....#OO#.",
      ".....##...");
   Cur_Outline : constant Pixel := 16#FF10_1010#;
   Cur_Fill    : constant Pixel := 16#FFFF_FFFF#;

   Under   : array (U64 range 0 .. Cur_W * Cur_H - 1) of Pixel;

   --  Save the under-rect fresh, draw the sprite, present the band.
   procedure Cursor_Draw (NX, NY : U64) is
      CX : constant U64 := U64'Min (NX, Width - Cur_W);
      CY : constant U64 := U64'Min (NY, Height - Cur_H);
      Stride_Px : constant U64 := Stride / 4;
      Idx : U64;
   begin
      Cur_X := CX;
      Cur_Y := CY;
      for R in 0 .. Cur_H - 1 loop
         for C in 0 .. Cur_W - 1 loop
            Idx := (CY + U64 (R)) * Stride_Px + CX + U64 (C);
            Under (U64 (R) * Cur_W + U64 (C)) := Buf (Idx);
            case Arrow (R) (C + 1) is
               when '#' => Buf (Idx) := Cur_Outline;
               when 'O' => Buf (Idx) := Cur_Fill;
               when others => null;
            end case;
         end loop;
      end loop;
      Cur_Vis := True;
      Result := Akernel_User.Display.Present
        (Display_EP, CX, CY, Cur_W, Cur_H);
   end Cursor_Draw;

   procedure Cursor_Erase is
      Stride_Px : constant U64 := Stride / 4;
   begin
      if not Cur_Vis then
         return;
      end if;
      for R in 0 .. Cur_H - 1 loop
         for C in 0 .. Cur_W - 1 loop
            Buf ((Cur_Y + U64 (R)) * Stride_Px + Cur_X + U64 (C)) :=
              Under (U64 (R) * Cur_W + U64 (C));
         end loop;
      end loop;
      Cur_Vis := False;
      Result := Akernel_User.Display.Present
        (Display_EP, Cur_X, Cur_Y, Cur_W, Cur_H);
   end Cursor_Erase;

   --  Drag the grabbed window to follow the pointer; repaint
   --  the union band of the old and new frames.
   procedure Drag_Move (PX, PY : U64) is
      S : constant Natural := Drag_Slot;
      NX : constant U64 := U64'Min
        ((if PX > Drag_DX then PX - Drag_DX else 0),
         Width - Wins (S).FW);
      NY : constant U64 := U64'Min
        ((if PY > Drag_DY then PY - Drag_DY else 0),
         Height - Wins (S).FH);
      X0 : constant U64 := U64'Min (Wins (S).X, NX);
      Y0 : constant U64 := U64'Min (Wins (S).Y, NY);
      X1 : constant U64 := U64'Max (Wins (S).X + Wins (S).FW,
                                    NX + Wins (S).FW);
      Y1 : constant U64 := U64'Max (Wins (S).Y + Wins (S).FH,
                                    NY + Wins (S).FH);
   begin
      if NX = Wins (S).X and then NY = Wins (S).Y then
         return;
      end if;
      Wins (S).X := NX;
      Wins (S).Y := NY;
      Composite_Band (X0, Y0, X1, Y1);
   end Drag_Move;

    --  Click-to-focus (slice b): button0 press inside a window
    --  raises it to the top and gives it the keys; a press in
    --  the title band also grabs the window for dragging.
    --  Gadget presses are Bureau's own: they set Eat_Gesture so
    --  the gesture is never captured or forwarded (a send-to-back
    --  moves the focus — the point can land inside the NEW front
    --  window's content).
    procedure Forward_Close (S : Natural);
    procedure Forward_Resize (S : Natural; New_W, New_H : U64);
    procedure Pointer_Press (PX, PY : U64) is
    begin
       for I in reverse 1 .. Z_N loop
          declare
             S : constant Natural := Z (I);
          begin
             if PX >= Wins (S).X
               and then PX < Wins (S).X + Wins (S).FW
               and then PY >= Wins (S).Y
               and then PY < Wins (S).Y + Wins (S).FH
             then
                --  Depth gadget (right, outermost): WB toggle
                --  semantics — already at the back pops the
                --  window to the front, otherwise it drops
                --  behind everything. Handled BEFORE the raise
                --  below: a send-to-back must not raise first.
                if Wins (S).FW >= 2 * Frame + 3 * Title_H
                  and then PY >= Wins (S).Y + Frame
                  and then PY < Wins (S).Y + Frame + Title_H
                  and then PX >= Wins (S).X + Wins (S).FW - Frame
                    - Title_H
                  and then PX < Wins (S).X + Wins (S).FW - Frame
                then
                   Eat_Gesture := True;
                   if Z (1) = S then
                      Raise_Slot (S);
                      Focus_Slot (S);
                   else
                      Lower_Slot (S);
                      if Z_N > 0 then
                         Focus_Slot (Z (Z_N));
                      end if;
                   end if;
                   Repaint_Window (S);
                   return;
                end if;
                if I /= Z_N then
                   Raise_Slot (S);
                   Repaint_Window (S);
                end if;
                Focus_Slot (S);
                if PY < Wins (S).Y + Frame + Title_H then
                   --  Title band: the LEFT gadget is close
                   --  (CLOSEWINDOW to the client, no drag); the
                   --  right pair is zoom (v5 resize handshake)
                   --  and depth (handled above, pre-raise);
                   --  anywhere else grabs the window. Gadgets
                   --  are full band height.
                   if PX >= Wins (S).X + Frame
                     and then PX < Wins (S).X + Frame + Title_H
                     and then PY >= Wins (S).Y + Frame
                   then
                      Eat_Gesture := True;
                      Forward_Close (S);
                   elsif Wins (S).FW >= 2 * Frame + 3 * Title_H
                     and then PX >= Wins (S).X + Wins (S).FW - Frame
                       - 2 * Title_H
                     and then PX < Wins (S).X + Wins (S).FW - Frame
                       - Title_H
                     and then PY >= Wins (S).Y + Frame
                   then
                      --  Zoom: toggle between the saved rect and
                      --  the full screen below the bar. Bureau
                      --  records the target and ASKS the client
                      --  (kind 5, no rendezvous); geometry moves
                      --  only when the client's Op_Surface_Resize
                      --  ack lands. One pending resize at a time.
                      Eat_Gesture := True;
                      if Wins (S).Resizable
                        and then not Wins (S).Resize_Pending
                        and then Wins (S).Queue_Cap /= 0
                      then
                         if Wins (S).Zoomed then
                            Wins (S).Pend_X := Wins (S).Save_X;
                            Wins (S).Pend_Y := Wins (S).Save_Y;
                            Forward_Resize
                              (S, Wins (S).Save_PW,
                               Wins (S).Save_PH);
                         else
                            Wins (S).Save_X  := Wins (S).X;
                            Wins (S).Save_Y  := Wins (S).Y;
                            Wins (S).Save_PW := Wins (S).PW;
                            Wins (S).Save_PH := Wins (S).PH;
                            Wins (S).Pend_X := 0;
                            Wins (S).Pend_Y := Bar_H + 1;
                            Forward_Resize
                              (S,
                               Width - 2 * Frame,
                               Height - Bar_H - 1 - 2 * Frame
                                 - Title_H);
                         end if;
                         Wins (S).Resize_Pending := True;
                      end if;
                   else
                      Drag_Slot := S;
                      Drag_DX := PX - Wins (S).X;
                      Drag_DY := PY - Wins (S).Y;
                   end if;
                end if;
                return;
             end if;
          end;
       end loop;
    end Pointer_Press;

   --  Enqueue one focused key into the focused window's input
   --  queue and signal its notification (v3: shared memory +
   --  signal — Bureau NEVER calls the client; a blocking forward
   --  rendezvous deadlocked against the client's Surface_Update
   --  calls, milestone 31 burn). Drop-new when the ring is full.
   --  v4: while Capture /= 0 events go to the CAPTURED window
   --  with coordinates clamped into content bounds instead of
   --  being dropped outside it.
   procedure Forward_Key (Ch : U64) is
      Q  : Word_Array
        with Address => System.Storage_Elements.To_Address
          (System.Storage_Elements.Integer_Address (Queue_VA (Focus)));
      Head : U64;
      Tail : U64;
      Slot : U64;
      Res  : U64;
   begin
      if Focus = 0 or else Wins (Focus).Queue_Cap = 0 then
         return;
      end if;
      Head := Q (Win.Input_Queue_Head);
      Tail := Q (Win.Input_Queue_Tail);
      if Head - Tail >= Win.Input_Queue_Events then
         return;  --  full: drop
      end if;
      Slot := Win.Input_Queue_First
        + (Head mod Win.Input_Queue_Events) * 2;
      Q (Slot)     := Win.Input_Event_Key;
      Q (Slot + 1) := Ch;
      Q (Win.Input_Queue_Head) := Head + 1;
      Res := Ntfn_Signal (Wins (Focus).Ntfn_Cap,
                          Win.Input_Signal_Bit);
      if Res /= 0 then
         Debug_Put_Line ("bureau input signal failed");
      end if;
   end Forward_Key;

   --  Enqueue a close event (kind 3, CLOSEWINDOW analog) into
   --  slot S's input queue and signal. The CLIENT decides what
   --  to do (Surface_Destroy + exit); Bureau never kills the
   --  window itself.
   procedure Forward_Close (S : Natural) is
      Q  : Word_Array
        with Address => System.Storage_Elements.To_Address
          (System.Storage_Elements.Integer_Address (Queue_VA (S)));
      Head : U64;
      Tail : U64;
      Slot : U64;
      Res  : U64;
   begin
      if Wins (S).Queue_Cap = 0 then
         return;
      end if;
      Head := Q (Win.Input_Queue_Head);
      Tail := Q (Win.Input_Queue_Tail);
      if Head - Tail >= Win.Input_Queue_Events then
         return;  --  full: drop
      end if;
      Slot := Win.Input_Queue_First
        + (Head mod Win.Input_Queue_Events) * 2;
      Q (Slot)     := Win.Input_Event_Close;
      Q (Slot + 1) := 0;
      Q (Win.Input_Queue_Head) := Head + 1;
      Res := Ntfn_Signal (Wins (S).Ntfn_Cap,
                          Win.Input_Signal_Bit);
       if Res /= 0 then
          Debug_Put_Line ("bureau input signal failed");
       end if;
    end Forward_Close;

    --  Enqueue a resize request (kind 5, value = Pack_Size of the
    --  requested content size) into slot S's input queue and
    --  signal. v5 zoom handshake: the client answers with
    --  Op_Surface_Resize + a fresh buffer cycle; Bureau applies
    --  the geometry only then. Same drop-new/shared-memory
    --  discipline as keys, close and menu.
    procedure Forward_Resize (S : Natural; New_W, New_H : U64) is
       Q  : Word_Array
         with Address => System.Storage_Elements.To_Address
           (System.Storage_Elements.Integer_Address (Queue_VA (S)));
       Head : U64;
       Tail : U64;
       Slot : U64;
       Res  : U64;
    begin
       if Wins (S).Queue_Cap = 0 then
          return;
       end if;
       Head := Q (Win.Input_Queue_Head);
       Tail := Q (Win.Input_Queue_Tail);
       if Head - Tail >= Win.Input_Queue_Events then
          return;  --  full: drop
       end if;
       Slot := Win.Input_Queue_First
         + (Head mod Win.Input_Queue_Events) * 2;
       Q (Slot)     := Win.Input_Event_Resize;
       Q (Slot + 1) := Win.Pack_Size (New_W, New_H);
       Q (Win.Input_Queue_Head) := Head + 1;
       Res := Ntfn_Signal (Wins (S).Ntfn_Cap,
                           Win.Input_Signal_Bit);
       if Res /= 0 then
          Debug_Put_Line ("bureau input signal failed");
       end if;
    end Forward_Resize;

   ------------------------------------------------------------------
   --  Milestone 61: menu actions

   --  Enqueue a menu pick (kind 4, value = item Id) into slot
   --  S's input queue and signal. Same drop-new/shared-memory
   --  discipline as keys and close.
   procedure Forward_Menu (S : Natural; Id : U64) is
      Q  : Word_Array
        with Address => System.Storage_Elements.To_Address
          (System.Storage_Elements.Integer_Address (Queue_VA (S)));
      Head : U64;
      Tail : U64;
      Slot : U64;
      Res  : U64;
   begin
      if Wins (S).Queue_Cap = 0 then
         return;
      end if;
      Head := Q (Win.Input_Queue_Head);
      Tail := Q (Win.Input_Queue_Tail);
      if Head - Tail >= Win.Input_Queue_Events then
         return;  --  full: drop
      end if;
      Slot := Win.Input_Queue_First
        + (Head mod Win.Input_Queue_Events) * 2;
      Q (Slot)     := Win.Input_Event_Menu;
      Q (Slot + 1) := Id;
      Q (Win.Input_Queue_Head) := Head + 1;
      Res := Ntfn_Signal (Wins (S).Ntfn_Cap,
                          Win.Input_Signal_Bit);
      if Res /= 0 then
         Debug_Put_Line ("bureau input signal failed");
      end if;
   end Forward_Menu;

   --  Lay out the bar title cells (fixed while a menu is open:
   --  focus cannot change — every pointer event is consumed).
    procedure Menu_Layout is
       X : U64 := 8;  --  in place of the hidden "Bureau" title
    begin
      for M in 1 .. Wins (Menu_Slot).Menu_Count loop
         Title_X (M) := X;
         Title_W (M) :=
           U64 (Wins (Menu_Slot).Menus (M).Title_Len) * 8 + 16;
         X := X + Title_W (M);
      end loop;
   end Menu_Layout;

   procedure Open_Menu is
   begin
      Menu_Slot := Focus;
      Menu_Mode := M_Tracking;
      Active_Menu := 0;
      Hot_Item := 0;
      Menu_Layout;
      Composite_Band (0, 0, Width, Bar_H + 1);
   end Open_Menu;

   procedure Dismiss_Menu is
      Bottom : U64 := Bar_H + 1;
   begin
      if Menu_Mode = M_Hidden then
         return;
      end if;
      if Active_Menu /= 0 then
         Bottom := Panel_Top + Panel_H;
      end if;
      Menu_Mode := M_Hidden;
      Menu_Slot := 0;
      Active_Menu := 0;
      Hot_Item := 0;
      Composite_Band (0, 0, Width, Bottom);
   end Dismiss_Menu;

   --  Hover tracking: over a bar title drops/switches that
   --  menu; over the dropped panel highlights a row (disabled
   --  items can never go hot); anywhere else just clears the
   --  hot row. Repaints the bar + panel union on any change.
   procedure Menu_Hover (PX, PY : U64) is
      W : Window_Rec renames Wins (Menu_Slot);
      New_Active : Natural := Active_Menu;
      New_Hot    : Natural := 0;
      Old_Bottom : U64 := Bar_H + 1;
      New_Bottom : U64 := Bar_H + 1;
   begin
      if PY < Bar_H then
         for M in 1 .. W.Menu_Count loop
            if PX >= Title_X (M)
              and then PX < Title_X (M) + Title_W (M)
            then
               New_Active := M;
               exit;
            end if;
         end loop;
      elsif Active_Menu /= 0 then
         declare
            PX0 : constant U64 := Panel_X;
            Row : U64;
         begin
            if PX >= PX0 and then PX < PX0 + Panel_W
              and then PY >= Panel_Top
              and then PY < Panel_Top + Panel_H
              and then PY >= Panel_Top + 3
            then
               Row := (PY - Panel_Top - 3) / Item_H;
               if Row < U64 (W.Menus (Active_Menu).Count)
                 and then not W.Items
                   (W.Menus (Active_Menu).First + Natural (Row) + 1)
                   .Disabled
               then
                  New_Hot := W.Menus (Active_Menu).First
                    + Natural (Row) + 1;
               end if;
            end if;
         end;
      end if;
      if New_Active = Active_Menu and then New_Hot = Hot_Item then
         return;
      end if;
      if Active_Menu /= 0 then
         Old_Bottom := Panel_Top + Panel_H;
      end if;
      Active_Menu := New_Active;
      Hot_Item := New_Hot;
      if Active_Menu /= 0 then
         New_Bottom := Panel_Top + Panel_H;
      end if;
      Composite_Band (0, 0, Width, U64'Max (Old_Bottom, New_Bottom));
   end Menu_Hover;

   procedure Pick_Menu is
      Id : constant U64 := Wins (Menu_Slot).Items (Hot_Item).Id;
      S  : constant Natural := Menu_Slot;
   begin
      Forward_Menu (S, Id);
      Dismiss_Menu;
   end Pick_Menu;

   --  Refresh the bar clock when the minute rolls over; repaints
   --  just the clock cell. Silent while the RTC reads 0.
   procedure Update_Clock is
      Secs : U64;
      Nanos : U64;
      Mins : U64;
      T : String (1 .. 5);
   begin
      Read_Clock (Secs, Nanos);
      if Secs = 0 then
         return;
      end if;
      Mins := (Secs / 60) mod 1440;
      if Mins = Clock_Min then
         return;
      end if;
      Clock_Min := Mins;
      T (1) := Character'Val (48 + Natural ((Mins / 60) / 10));
      T (2) := Character'Val (48 + Natural ((Mins / 60) mod 10));
      T (3) := ':';
      T (4) := Character'Val (48 + Natural ((Mins mod 60) / 10));
      T (5) := Character'Val (48 + Natural ((Mins mod 60) mod 10));
      Clock_Text := T;
      Composite_Band (Width - Clock_X0, 0, Width - 24, Bar_H + 1);
   end Update_Clock;

   --  Enqueue the focused window's pointer state (v3, packed
   --  content-relative) and signal. Delivered only while the
   --  pointer is inside the window content and no title drag is
   --  active; consecutive pointer events coalesce in place so a
   --  fast pointer cannot flood the ring.
   procedure Forward_Pointer (PX, PY, Buttons : U64) is
      T    : constant Natural :=
        (if Capture /= 0 then Capture else Focus);
      Q  : Word_Array
        with Address => System.Storage_Elements.To_Address
          (System.Storage_Elements.Integer_Address (Queue_VA (T)));
      Head : U64;
      Tail : U64;
      Slot : U64;
      CX   : U64;
      CY   : U64;
      Res  : U64;
   begin
      if T = 0 or else Wins (T).Queue_Cap = 0
        or else Drag_Slot /= 0
      then
         return;
      end if;
      --  Content-relative; outside the content nothing is
      --  delivered UNLESS captured (v4) — then coordinates clamp
      --  into content bounds so drags track to the edge.
      declare
         IX : constant Long_Long_Integer :=
           Long_Long_Integer (PX) -
             Long_Long_Integer (Wins (T).X + Frame);
         IY : constant Long_Long_Integer :=
           Long_Long_Integer (PY) -
             Long_Long_Integer (Wins (T).Y + Frame + Title_H);
      begin
         if Capture = 0 then
            if IX < 0 or else IY < 0
              or else IX >= Long_Long_Integer (Wins (T).PW)
              or else IY >= Long_Long_Integer (Wins (T).PH)
            then
               return;
            end if;
            CX := U64 (IX);
            CY := U64 (IY);
         else
            CX := U64 (Long_Long_Integer'Min
              (Long_Long_Integer'Max (IX, 0),
               Long_Long_Integer (Wins (T).PW - 1)));
            CY := U64 (Long_Long_Integer'Min
              (Long_Long_Integer'Max (IY, 0),
               Long_Long_Integer (Wins (T).PH - 1)));
         end if;
      end;
      Head := Q (Win.Input_Queue_Head);
      Tail := Q (Win.Input_Queue_Tail);
      if Head > Tail then
         --  Coalesce: overwrite the newest event if it is an
         --  undrained pointer event WITH THE SAME button state —
         --  merging a press into a release (or vice versa) loses
         --  the edge and wedges client drag state.
         Slot := Win.Input_Queue_First
           + ((Head - 1) mod Win.Input_Queue_Events) * 2;
         if Q (Slot) = Win.Input_Event_Pointer
           and then (Q (Slot + 1) / 2 ** 32) mod 256 =
                    Buttons mod 256
         then
            Q (Slot + 1) := Win.Pack_Pointer (CX, CY, Buttons);
            return;  --  already signaled when first enqueued
         end if;
      end if;
      if Head - Tail >= Win.Input_Queue_Events then
         return;  --  full: drop
      end if;
      Slot := Win.Input_Queue_First
        + (Head mod Win.Input_Queue_Events) * 2;
      Q (Slot)     := Win.Input_Event_Pointer;
      Q (Slot + 1) := Win.Pack_Pointer (CX, CY, Buttons);
      Q (Win.Input_Queue_Head) := Head + 1;
      Res := Ntfn_Signal (Wins (Focus).Ntfn_Cap,
                          Win.Input_Signal_Bit);
      if Res /= 0 then
         Debug_Put_Line ("bureau input signal failed");
      end if;
   end Forward_Pointer;

   procedure Fail (S : String) is
   begin
      Debug_Put_Line ("FAIL bureau " & S);
      Process_Exit;
   end Fail;

   ------------------------------------------------------------------

   Pages_Left : U64;
   This       : U64;
   Count      : Natural;
   Minted     : U64;
   Label      : U64;
   Reply_H    : U64;

begin
   --  1. Mode geometry from the display service.
   if Akernel_User.Display.Get_Info
     (Display_EP, Width, Height, Stride, Pages) /=
       Akernel_User.Display.Status_Ok
   then
      Fail ("display info failed");
   end if;
   if Width = 0 or else Width > Max_W or else Height > Max_H
     or else Stride /= Width * 4
   then
      Fail ("display geometry unsupported");
   end if;
   Debug_Put_Line ("PASS bureau display info ok");

   --  2. Compositing buffer: chunks of at most 64 pages, mapped
   --  contiguously at Buf_VA.
   Objects := (Pages + 63) / 64;
   if Objects > Max_Objects then
      Fail ("buffer too large");
   end if;

   Pages_Left := Pages;
   Count := 0;
   while Pages_Left > 0 loop
      This := U64'Min (Pages_Left, 64);
      Obj_Caps (Count) := Mem_Alloc (This);
      if Obj_Caps (Count) = Syscall_Failed then
         Fail ("buffer alloc failed");
      end if;
      Result := Mem_Map
        (Address_Space => Address_Space_Cap,
         Cap           => Obj_Caps (Count),
         VA            => Buf_VA + U64 (Count) * 64 * 4096,
         Offset        => 0,
         Length        => This * 4096,
         Flags         => 3);
      if Result /= 0 then
         Fail ("buffer map failed");
      end if;
      Pages_Left := Pages_Left - This;
      Count := Count + 1;
   end loop;

   --  3. Push chunk caps to the display service (4 per call).
   --  The driver needs the Manage right for Mem_Object_PA;
   --  minted copies are deleted after each call (transfer keeps
   --  the sender's slot; Bureau's originals stay for mapping).
   declare
      Base : U64 := 0;
      Send : array (0 .. 3) of U64;
      St   : U64;
   begin
      while Base < Objects loop
         Send := (others => 0);
         for I in 0 .. 3 loop
            exit when Base + U64 (I) >= Objects;
            Minted := Cap_Mint
              (Obj_Caps (Natural (Base + U64 (I))),
               Right_Map + Right_Read + Right_Write + Right_Manage +
                 Right_Transfer,
               0);
            if Minted = Syscall_Failed then
               Fail ("buffer mint failed");
            end if;
            Send (I) := Minted;
         end loop;
         St := Akernel_User.Display.Set_Buffer
           (Display_EP, Base, Send (0), Send (1), Send (2), Send (3));
         for I in 0 .. 3 loop
            if Send (I) /= 0 then
               Result := Cap_Delete (Send (I));
            end if;
         end loop;
         if St /= Akernel_User.Display.Status_Ok then
            Fail ("set buffer rejected");
         end if;
         Base := Base + 4;
      end loop;
   end;

   --  4. Commit: the scanout backing is now Bureau's buffer.
   if Akernel_User.Display.Commit_Buffer (Display_EP) /=
     Akernel_User.Display.Status_Ok
   then
      Fail ("buffer commit failed");
   end if;
   Debug_Put_Line ("PASS bureau display commit ok");

   --  5. Compose the bare desktop and present the full frame.
   Paint_Band (0, 0, Width, Height);
   if Akernel_User.Display.Present (Display_EP, 0, 0, Width, Height)
     /= Akernel_User.Display.Status_Ok
   then
      Fail ("present failed");
   end if;
   Debug_Put_Line ("bureau desktop online");

   --  Pointer starts centered; bar clock primed from the RTC.
   Update_Clock;
   Cursor_Draw (Width / 2, Height / 2);

   --  Window-protocol service loop (v2: up to Max_Win slots).
   loop
      if IPC_Recv (Win_Svc, Reply_H) /= IPC_Ok then
         Debug_Put_Line ("bureau recv failed");
         Process_Exit;
      end if;
      Label := Message.Label;

      if Label = Win.Op_Surface_Create then
         declare
            Slot : Natural := 0;
            PW   : U64;
            PH   : U64;
         begin
            for S in 1 .. Max_Win loop
               if not Wins (S).Used then
                  Slot := S;
                  exit;
               end if;
            end loop;
            if Slot = 0 then
               Win_Reply (Reply_H, Label, Win.Status_No_Slot, 0, 0, 0, 0);
            elsif Message.Words (0) = 0 or else Message.Words (1) = 0
            then
               Win_Reply (Reply_H, Label, Win.Status_Bad_Index, 0, 0, 0, 0);
            else
               PW := U64'Min (Message.Words (0), Width - 2 * Frame);
               PH := U64'Min (Message.Words (1),
                              Height - 2 * Frame - Title_H);
               if (PW * PH * 4 + 4095) / 4096 >
                 U64 (Surf_Max_Objects) * 64
               then
                  Win_Reply (Reply_H, Label, Win.Status_No_Slot, 0, 0, 0, 0);
               else
                  Next_Id := Next_Id + 1;
                  Wins (Slot).Used     := True;
                  Wins (Slot).Id       := Next_Id;
                  Wins (Slot).PW       := PW;
                  Wins (Slot).PH       := PH;
                  Wins (Slot).FW       := PW + 2 * Frame;
                  Wins (Slot).FH       := PH + 2 * Frame + Title_H;
                  --  Cascade placement, clamped on-screen.
                  Wins (Slot).X := U64'Min
                    (32 + 48 * U64 (Slot - 1),
                     Width - Wins (Slot).FW);
                  Wins (Slot).Y := U64'Min
                    (40 + 36 * U64 (Slot - 1),
                     Height - Wins (Slot).FH);
                  Wins (Slot).Pages    := (PW * PH * 4 + 4095) / 4096;
                  Wins (Slot).Got      := 0;
                  Wins (Slot).Mapped   := False;
                  Wins (Slot).Caps     := (others => 0);
                   Wins (Slot).Queue_Cap := Message.Caps (0);
                   Wins (Slot).Ntfn_Cap  := Message.Caps (1);
                   Wins (Slot).Title    := (others => ' ');
                   Wins (Slot).Title_Len := 0;
                   --  Slot reuse must not leak the previous
                   --  window's menus or zoom state.
                   Wins (Slot).Menu_Count := 0;
                   Wins (Slot).Resizable :=
                     (Message.Words (2) and Win.Flag_Resizable) /= 0;
                   Wins (Slot).Zoomed := False;
                   Wins (Slot).Resize_Pending := False;
                  --  v3: map the client's input queue RW (the
                  --  one-page memobj arrives with Map+Read+
                  --  Write+Transfer).
                  if Wins (Slot).Queue_Cap /= 0 then
                     if Mem_Map
                       (Address_Space => Address_Space_Cap,
                        Cap           => Wins (Slot).Queue_Cap,
                        VA            => Queue_VA (Slot),
                        Offset        => 0,
                        Length        => 4096,
                        Flags         => 3) /= 0
                     then
                        Debug_Put_Line ("bureau queue map failed");
                        Result := Cap_Delete (Wins (Slot).Queue_Cap);
                        Wins (Slot).Queue_Cap := 0;
                        if Wins (Slot).Ntfn_Cap /= 0 then
                           Result := Cap_Delete (Wins (Slot).Ntfn_Cap);
                           Wins (Slot).Ntfn_Cap := 0;
                        end if;
                     end if;
                  end if;
                  Z_N := Z_N + 1;
                  Z (Z_N) := Slot;
                  Focus_Slot (Slot);
                  --  A new window takes the focus: any open menu
                  --  belonged to the previous owner.
                  Dismiss_Menu;
                  Repaint_Window (Slot);
                  Win_Reply (Reply_H, Label, Win.Status_Ok,
                             Wins (Slot).Id, Wins (Slot).Pages,
                             PW, PH);
               end if;
            end if;
         end;

      elsif Label = Win.Op_Surface_Set_Buffer then
         declare
            S : constant Natural := Slot_Of (Message.Words (0));
         begin
            if S = 0 or else Wins (S).Mapped then
               Win_Reply (Reply_H, Label, Win.Status_Bad_Id, 0, 0, 0, 0);
            else
               declare
                  Base : constant U64 := Message.Words (1);
                  St   : U64 := Win.Status_Ok;
                  Idx  : U64;
               begin
                  for I in 0 .. 3 loop
                     exit when Message.Caps (I) = 0;
                     Idx := Base + U64 (I);
                     if Idx >= U64 (Surf_Max_Objects)
                       or else Wins (S).Caps (Natural (Idx)) /= 0
                     then
                        St := Win.Status_Bad_Index;
                        Result := Cap_Delete (Message.Caps (I));
                     else
                        Wins (S).Caps (Natural (Idx)) :=
                          Message.Caps (I);
                        Wins (S).Got := Wins (S).Got + 1;
                     end if;
                  end loop;
                  Win_Reply (Reply_H, Label, St, 0, 0, 0, 0);
               end;
            end if;
         end;

      elsif Label = Win.Op_Surface_Commit_Buffer then
         declare
            S : constant Natural := Slot_Of (Message.Words (0));
         begin
            if S = 0 or else Wins (S).Mapped then
               Win_Reply (Reply_H, Label, Win.Status_Bad_Id, 0, 0, 0, 0);
            elsif U64 (Wins (S).Got) /= (Wins (S).Pages + 63) / 64 then
               Win_Reply (Reply_H, Label, Win.Status_Bad_Index, 0, 0, 0, 0);
            else
               declare
                  St : U64 := Win.Status_Ok;
               begin
                  for I in 0 .. Wins (S).Got - 1 loop
                     This := U64'Min
                       (Wins (S).Pages - U64 (I) * 64, 64);
                     if Mem_Map
                       (Address_Space => Address_Space_Cap,
                        Cap           => Wins (S).Caps (I),
                        VA            => Surf_VA (S) +
                          U64 (I) * 64 * 4096,
                        Offset        => 0,
                        Length        => This * 4096,
                        Flags         => 1) /= 0
                     then
                        St := Win.Status_Bad_Caps;
                     end if;
                  end loop;
                  if St = Win.Status_Ok then
                     Wins (S).Mapped := True;
                     Repaint_Window (S);
                  end if;
                  Win_Reply (Reply_H, Label, St, 0, 0, 0, 0);
               end;
            end if;
         end;

      elsif Label = Win.Op_Surface_Update then
         declare
            S : constant Natural := Slot_Of (Message.Words (0));
         begin
            if S /= 0 and then Wins (S).Mapped then
               declare
                  CX : constant U64 :=
                    U64'Min (Message.Words (1), Wins (S).PW);
                  CY : constant U64 :=
                    U64'Min (Message.Words (2), Wins (S).PH);
                  CW : constant U64 :=
                    U64'Min (Message.Words (3), Wins (S).PW - CX);
                  CH : constant U64 :=
                    U64'Min (Message.Words (4), Wins (S).PH - CY);
               begin
                  if CW > 0 and then CH > 0 then
                     Composite_Band (Pane_X (S) + CX, Pane_Y (S) + CY,
                                     Pane_X (S) + CX + CW,
                                     Pane_Y (S) + CY + CH);
                  end if;
               end;
               Win_Reply (Reply_H, Label, Win.Status_Ok, 0, 0, 0, 0);
            else
               Win_Reply (Reply_H, Label, Win.Status_Bad_Id, 0, 0, 0, 0);
            end if;
         end;

       elsif Label = Win.Op_Surface_Resize then
          --  v5 zoom ack (or a client-initiated resize): tear
          --  down the old buffer with Destroy's discipline, apply
          --  the pending zoom geometry if there is one, repaint
          --  the old-union-new frame band. The pane draws blank
          --  until the client commits a fresh buffer.
          declare
             S : constant Natural := Slot_Of (Message.Words (0));
          begin
             if S = 0 then
                Win_Reply (Reply_H, Label, Win.Status_Bad_Id,
                           0, 0, 0, 0);
             else
                declare
                   PW : constant U64 := U64'Min
                     (Message.Words (1), Width - 2 * Frame);
                   PH : constant U64 := U64'Min
                     (Message.Words (2), Height - 2 * Frame - Title_H);
                   FX : constant U64 := Wins (S).X;
                   FY : constant U64 := Wins (S).Y;
                   FW : constant U64 := Wins (S).FW;
                   FH : constant U64 := Wins (S).FH;
                begin
                   if (PW * PH * 4 + 4095) / 4096 >
                     U64 (Surf_Max_Objects) * 64
                   then
                      Win_Reply (Reply_H, Label, Win.Status_No_Slot,
                                 0, 0, 0, 0);
                   else
                      if Wins (S).Mapped then
                         for I in 0 .. Wins (S).Got - 1 loop
                            This := U64'Min
                              (Wins (S).Pages - U64 (I) * 64, 64);
                            if Mem_Unmap
                              (Address_Space_Cap,
                               Surf_VA (S) + U64 (I) * 64 * 4096,
                               This * 4096) /= 0
                            then
                               Debug_Put_Line ("bureau unmap failed");
                            end if;
                         end loop;
                      end if;
                      for I in 0 .. Surf_Max_Objects - 1 loop
                         if Wins (S).Caps (I) /= 0 then
                            Result := Cap_Delete (Wins (S).Caps (I));
                            Wins (S).Caps (I) := 0;
                         end if;
                      end loop;
                      Wins (S).Got    := 0;
                      Wins (S).Mapped := False;
                      Wins (S).PW     := PW;
                      Wins (S).PH     := PH;
                      Wins (S).FW     := PW + 2 * Frame;
                      Wins (S).FH     := PH + 2 * Frame + Title_H;
                      Wins (S).Pages  := (PW * PH * 4 + 4095) / 4096;
                      if Wins (S).Resize_Pending then
                         Wins (S).X := Wins (S).Pend_X;
                         Wins (S).Y := Wins (S).Pend_Y;
                         Wins (S).Zoomed := not Wins (S).Zoomed;
                         Wins (S).Resize_Pending := False;
                      end if;
                      --  Keep the frame on-screen: an in-place
                      --  GROW can push the right/bottom edge off.
                      Wins (S).X := U64'Min
                        (Wins (S).X, Width - Wins (S).FW);
                      Wins (S).Y := U64'Min
                        (Wins (S).Y, Height - Wins (S).FH);
                      Composite_Band
                        (U64'Min (FX, Wins (S).X),
                         U64'Min (FY, Wins (S).Y),
                         U64'Max (FX + FW, Wins (S).X + Wins (S).FW),
                         U64'Max (FY + FH, Wins (S).Y + Wins (S).FH));
                      Win_Reply (Reply_H, Label, Win.Status_Ok,
                                 Wins (S).Pages, PW, PH, 0);
                   end if;
                end;
             end if;
          end;

       elsif Label = Win.Op_Surface_Destroy then
         declare
            S : constant Natural := Slot_Of (Message.Words (0));
         begin
            if S = 0 then
               Win_Reply (Reply_H, Label, Win.Status_Bad_Id, 0, 0, 0, 0);
            else
               declare
                  FX : constant U64 := Wins (S).X;
                  FY : constant U64 := Wins (S).Y;
                  FW : constant U64 := Wins (S).FW;
                  FH : constant U64 := Wins (S).FH;
               begin
                  --  Its menu bar (if open) dies with the window.
                  if S = Menu_Slot then
                     Dismiss_Menu;
                  end if;
                  if Wins (S).Mapped then
                     for I in 0 .. Wins (S).Got - 1 loop
                        This := U64'Min
                          (Wins (S).Pages - U64 (I) * 64, 64);
                        if Mem_Unmap
                          (Address_Space_Cap,
                           Surf_VA (S) + U64 (I) * 64 * 4096,
                           This * 4096) /= 0
                        then
                           Debug_Put_Line ("bureau unmap failed");
                        end if;
                     end loop;
                  end if;
                  for I in 0 .. Surf_Max_Objects - 1 loop
                     if Wins (S).Caps (I) /= 0 then
                        Result := Cap_Delete (Wins (S).Caps (I));
                     end if;
                  end loop;
                  if Wins (S).Queue_Cap /= 0 then
                     Result := Mem_Unmap
                       (Address_Space_Cap, Queue_VA (S), 4096);
                     Result := Cap_Delete (Wins (S).Queue_Cap);
                  end if;
                  if Wins (S).Ntfn_Cap /= 0 then
                     Result := Cap_Delete (Wins (S).Ntfn_Cap);
                  end if;
                  Wins (S).Used := False;
                  --  A destroyed window must not hold v4 capture
                  --  or a title drag.
                  if Capture = S then
                     Capture := 0;
                  end if;
                  if Drag_Slot = S then
                     Drag_Slot := 0;
                  end if;
                  --  Remove from the z-order.
                  for I in 1 .. Z_N loop
                     if Z (I) = S then
                        for J in I .. Z_N - 1 loop
                           Z (J) := Z (J + 1);
                        end loop;
                        Z_N := Z_N - 1;
                        exit;
                     end if;
                  end loop;
                  if Focus = S then
                     Focus := 0;
                     if Z_N > 0 then
                        Focus_Slot (Z (Z_N));
                     end if;
                  end if;
                  Composite_Band (FX, FY, FX + FW, FY + FH);
                  Win_Reply (Reply_H, Label, Win.Status_Ok, 0, 0, 0, 0);
               end;
            end if;
         end;

      elsif Label = Win.Op_Set_Title then
         declare
            S : constant Natural := Slot_Of (Message.Words (0));
         begin
            if S = 0 then
               Win_Reply (Reply_H, Label, Win.Status_Bad_Id, 0, 0, 0, 0);
            else
               declare
                  W    : U64;
                  B    : U64;
                  Ch   : Natural;
               begin
                  Wins (S).Title := (others => ' ');
                  Wins (S).Title_Len := 0;
                  for K in 0 .. 39 loop
                     W := Message.Words (1 + K / 8);
                     B := Interfaces.Shift_Right
                       (W, (K mod 8) * 8) and 16#FF#;
                     exit when B = 0;
                     Ch := Natural (B);
                     if Ch >= 32 and then Ch <= 126 then
                        Wins (S).Title (K + 1) :=
                          Character'Val (Ch);
                        Wins (S).Title_Len := K + 1;
                     end if;
                  end loop;
                  Repaint_Title (S);
                  Win_Reply (Reply_H, Label, Win.Status_Ok, 0, 0, 0, 0);
               end;
            end if;
         end;

      elsif Label = Win.Op_Set_Menus then
         --  Milestone 61: copy the serialized tree out of the
         --  client's one-shot page into the slot (Bureau never
         --  re-reads client memory). caps 0 = 0 clears.
         declare
            S : constant Natural := Slot_Of (Message.Words (0));
            St : U64 := Win.Status_Ok;

            procedure Get_Chars
              (Page : Word_Array; W_Idx : U64;
               Dest : out String; Len : out Natural) is
               B : U64;
            begin
               Dest := (others => ' ');
               Len := 0;
               for K in 0 .. Dest'Length - 1 loop
                  B := Interfaces.Shift_Right
                    (Page (W_Idx + U64 (K / 8)), (K mod 8) * 8)
                    and 16#FF#;
                  exit when B = 0;
                  if B >= 32 and then B <= 126 then
                     Dest (Dest'First + K) := Character'Val (B);
                     Len := K + 1;
                  end if;
               end loop;
            end Get_Chars;
         begin
            if S = 0 then
               Win_Reply (Reply_H, Label, Win.Status_Bad_Id,
                          0, 0, 0, 0);
            else
               if S = Menu_Slot then
                  Dismiss_Menu;
               end if;
               if Message.Caps (0) = 0 then
                  Wins (S).Menu_Count := 0;
                  if S = Focus then
                     Composite_Band (0, 0, Width, Bar_H + 1);
                  end if;
               elsif Mem_Map
                 (Address_Space => Address_Space_Cap,
                  Cap           => Message.Caps (0),
                  VA            => Menu_VA,
                  Offset        => 0,
                  Length        => 4096,
                  Flags         => 1) /= 0
               then
                  St := Win.Status_Bad_Caps;
                  Result := Cap_Delete (Message.Caps (0));
               else
                  declare
                     Page : Word_Array
                       with Address =>
                         System.Storage_Elements.To_Address
                           (System.Storage_Elements.Integer_Address
                              (Menu_VA));
                     M : constant Natural := Natural (Page (0));
                     N : constant Natural := Natural (Page (1));
                  begin
                     if M < 1 or else M > Max_Menus
                       or else N < 1 or else N > Max_Items
                     then
                        St := Win.Status_Bad_Index;
                     else
                        Wins (S).Menu_Count := M;
                        for I in 1 .. M loop
                           declare
                              WI : constant U64 :=
                                2 + U64 (I - 1) * 4;
                              First : constant Natural :=
                                Natural (Page (WI + 2));
                              Cnt   : constant Natural :=
                                Natural (Page (WI + 3));
                           begin
                              Get_Chars
                                (Page, WI,
                                 Wins (S).Menus (I).Title,
                                 Wins (S).Menus (I).Title_Len);
                              --  Clamp the span into the item
                              --  table — a hostile/buggy client
                              --  must not index out of bounds.
                              Wins (S).Menus (I).First :=
                                Natural'Min (First, N);
                              Wins (S).Menus (I).Count :=
                                Natural'Min
                                  (Cnt, N - Wins (S).Menus (I).First);
                           end;
                        end loop;
                        for I in 1 .. N loop
                           declare
                              WI : constant U64 :=
                                2 + U64 (M) * 4 + U64 (I - 1) * 4;
                              W3 : constant U64 := Page (WI + 3);
                           begin
                              Get_Chars
                                (Page, WI,
                                 Wins (S).Items (I).Label,
                                 Wins (S).Items (I).Label_Len);
                              Wins (S).Items (I).Id :=
                                W3 and 16#FFFF_FFFF#;
                              Wins (S).Items (I).Disabled :=
                                ((W3 / 2 ** 32) and 1) = 1;
                           end;
                        end loop;
                        if S = Focus then
                           Composite_Band (0, 0, Width, Bar_H + 1);
                        end if;
                     end if;
                  end;
                  Result := Mem_Unmap (Address_Space_Cap,
                                       Menu_VA, 4096);
                  Result := Cap_Delete (Message.Caps (0));
               end if;
               Win_Reply (Reply_H, Label, St, 0, 0, 0, 0);
            end if;
         end;

      elsif Label = Win.Op_Set_Focus then
         --  v1 devmgr wiring, obsolete in v2 (focus is internal).
         --  Answer and drop the cap so the table stays clean.
         if Message.Caps (0) /= 0 then
            Result := Cap_Delete (Message.Caps (0));
         end if;
         Win_Reply (Reply_H, Label, Win.Status_Ok, 0, 0, 0, 0);

      elsif Label = Win.Op_Key then
         --  While a menu is open, Esc dismisses it and is eaten;
         --  everything else still flows to the focused window.
         if Menu_Mode /= M_Hidden and then Message.Words (0) = 27
         then
            Dismiss_Menu;
         else
            Forward_Key (Message.Words (0));
         end if;
         Win_Reply (Reply_H, Label, Win.Status_Ok, 0, 0, 0, 0);

      elsif Label = Win.Op_Pointer then
         declare
            NX : constant U64 :=
              Message.Words (0) * Width / 32768;
            NY : constant U64 :=
              Message.Words (1) * Height / 32768;
            Buttons : constant U64 := Message.Words (2);
            LMB : constant Boolean := (Buttons and 1) /= 0;
            LMB_Was : constant Boolean := (Prev_Buttons and 1) /= 0;
             RMB : constant Boolean := (Buttons and 2) /= 0;
             RMB_Was : constant Boolean := (Prev_Buttons and 2) /= 0;
         begin
            --  Erase first: a drag repaint would make the
            --  saved under-rect stale.
            Cursor_Erase;
            if Menu_Mode /= M_Hidden then
               --  Milestone 61: the menu owns the pointer.
               if RMB and then not RMB_Was then
                  Dismiss_Menu;  --  RMB again toggles off
               elsif not RMB and then RMB_Was
                 and then Menu_Mode = M_Tracking
               then
                  --  Release ends drag-select: over an item =
                  --  pick; anywhere else the bar STAYS open
                  --  (sticky — the touchpad ruling).
                  if Hot_Item /= 0 then
                     Pick_Menu;
                  else
                     Menu_Mode := M_Sticky;
                     Menu_Hover (NX, NY);
                  end if;
               elsif LMB and then not LMB_Was then
                  if Hot_Item /= 0 then
                     Pick_Menu;
                  elsif NY >= Bar_H then
                     Dismiss_Menu;  --  click off the bar: eaten
                  end if;
               else
                  Menu_Hover (NX, NY);
               end if;
               Prev_Buttons := Buttons;
               Cursor_Draw (NX, NY);
            elsif RMB and then not RMB_Was then
               --  RMB opens the focused window's menu bar and
               --  is Bureau's alone (never reaches content).
               --  Log the edge: the GTK pointer grab eats the
               --  first click, which leaves users thinking RMB
               --  is broken when the focus click never landed.
               Debug_Put_Line ("bureau: rmb down");
               if Focus /= 0 and then Wins (Focus).Menu_Count > 0
               then
                  Open_Menu;
                  Menu_Hover (NX, NY);
               else
                  Debug_Put_Line
                    ("bureau: focused window has no menus");
                  --  Acknowledge the gesture visibly.
                  Bar_Ack := True;
                  Composite_Band (0, 0, 64, Bar_H + 1);
               end if;
               Prev_Buttons := Buttons;
               Cursor_Draw (NX, NY);
            else
            --  RMB release clears the no-menus acknowledgment.
            if not RMB and then RMB_Was and then Bar_Ack then
               Bar_Ack := False;
               Composite_Band (0, 0, 64, Bar_H + 1);
            end if;
             if (Buttons and 1) = 1
               and then (Prev_Buttons and 1) = 0
             then
                Pointer_Press (NX, NY);
                --  v4: a press inside the focused window's content
                --  captures the pointer until release. Title-band
                --  presses (drag/close/depth/zoom) do NOT capture
                --  — Bureau owns those.
                if not Eat_Gesture
                  and then Focus /= 0 and then Wins (Focus).Queue_Cap /= 0
                  and then Drag_Slot = 0
                  and then NX >= Wins (Focus).X + Frame
                  and then NX < Wins (Focus).X + Frame +
                    Wins (Focus).PW
                  and then NY >= Wins (Focus).Y + Frame + Title_H
                  and then NY < Wins (Focus).Y + Frame + Title_H +
                    Wins (Focus).PH
                then
                   Capture := Focus;
                end if;
            elsif (Buttons and 1) = 1 and then Drag_Slot /= 0 then
               Drag_Move (NX, NY);
            elsif (Buttons and 1) = 0 then
               Drag_Slot := 0;
            end if;
            Prev_Buttons := Buttons;
            Cursor_Draw (NX, NY);
             --  Focused-client delivery happens after focus/
             --  raise/drag so a content click lands with the new
             --  focus already in place. Shared-mem enqueue +
             --  signal only — never a rendezvous. Gadget
             --  gestures stay Bureau's.
             if not Eat_Gesture then
                Forward_Pointer (NX, NY, Buttons);
             end if;
             --  v4: the release event above is the LAST captured
             --  delivery; clear capture after it. A gadget
             --  gesture ends here too.
             if (Buttons and 1) = 0 then
                Capture := 0;
                Eat_Gesture := False;
             end if;
            end if;
         end;
         Win_Reply (Reply_H, Label, Win.Status_Ok, 0, 0, 0, 0);

      else
         Win_Reply (Reply_H, Label, Win.Status_Ok, 0, 0, 0, 0);
      end if;

      --  Bar clock tick (Bureau blocks in Receive, so this is
      --  event-driven: one repaint per visible minute change).
      Update_Clock;
   end loop;
end Bureau;
