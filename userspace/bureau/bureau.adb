with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Display;
with Akernel_User.Window;
with Akernel_User.Streams;
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

   Max_Win : constant := 4;
   Surf_Max_Objects : constant := 8;
   type Cap_Set is array (0 .. Surf_Max_Objects - 1) of U64;

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
      Input_EP : U64 := 0;   --  client's input stream (Send)
      Title    : String (1 .. 40) := (others => ' ');
      Title_Len : Natural := 0;
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

   function Surf_VA (Slot : Natural) return U64 is
     (Surf_VA0 + U64 (Slot - 1) * Surf_Slot_Stride);

   --  Pane rectangle of a slot (absolute coords).
   function Pane_X (S : Natural) return U64 is (Wins (S).X + Frame);
   function Pane_Y (S : Natural) return U64 is
     (Wins (S).Y + Frame + Title_H);

   --  Raw word reply (same pattern as the display driver).
   procedure Win_Reply (Req_Label : U64; W0, W1, W2, W3, W4 : U64) is
   begin
      Message.Label := Req_Label;
      Message.Words (0) := W0;
      Message.Words (1) := W1;
      Message.Words (2) := W2;
      Message.Words (3) := W3;
      Message.Words (4) := W4;
      Message.Words (5) := 0;
      if IPC_Reply /= IPC_Ok then
         Debug_Put_Line ("bureau reply failed");
         Process_Exit;
      end if;
   end Win_Reply;

   ------------------------------------------------------------------
   --  Cursor state (bodies below; Present_Band redraws the sprite
   --  when a band clobbers it)
   ------------------------------------------------------------------

   Cur_W : constant := 10;
   Cur_H : constant := 16;
   Cur_X   : U64 := 0;
   Cur_Y   : U64 := 0;
   Cur_Vis : Boolean := False;
   procedure Cursor_Draw (NX, NY : U64);

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

   procedure Draw_Gadget (GX, GY, Size : U64) is
   begin
      Fill_Rect (GX, GY, GX + Size, GY + Size, Win_Face);
      Bevel (GX, GY, GX + Size, GY + Size);
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
      --  Title bar + gadgets + title text.
      Fill_Rect (FX + Frame, Title_Y,
                 FX + FW - Frame, Title_Y + Title_H, Title_C);
      Draw_Gadget (FX + Frame + 2, Title_Y + 2, Title_H - 4);
      Draw_Gadget (FX + FW - Frame - Title_H + 2, Title_Y + 2,
                   Title_H - 4);
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
      --  Screen bar (always on top) + right-side depth gadget.
      Fill_Rect (0, 0, Width, Bar_H, Bar_Face);
      Fill_Rect (0, Bar_H, Width, Bar_H + 1, Bevel_Lo);
      Draw_Text (8, 5, "Bureau", Text_Dark, Bar_Face, Stretch => 1);
      Draw_Gadget (Width - 24, 1, 16);
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
      if Cur_Vis
        and then X < Cur_X + Cur_W
        and then Cur_X < X + W
        and then Y < Cur_Y + Cur_H
        and then Cur_Y < Y + H
      then
         Cursor_Draw (Cur_X, Cur_Y);
      end if;
   end Present_Band;

   procedure Repaint_Window (S : Natural) is
   begin
      Paint_Band (Wins (S).X, Wins (S).Y,
                  Wins (S).X + Wins (S).FW, Wins (S).Y + Wins (S).FH);
      Present_Band (Wins (S).X, Wins (S).Y, Wins (S).FW, Wins (S).FH);
   end Repaint_Window;

   --  Title band of a slot (for focus-color changes).
   procedure Repaint_Title (S : Natural) is
   begin
      Paint_Band (Wins (S).X, Wins (S).Y,
                  Wins (S).X + Wins (S).FW,
                  Wins (S).Y + Frame + Title_H);
      Present_Band (Wins (S).X, Wins (S).Y,
                    Wins (S).FW, Frame + Title_H);
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

   procedure Cursor_Move (NX, NY : U64) is
   begin
      Cursor_Erase;
      Cursor_Draw (NX, NY);
   end Cursor_Move;

   --  Forward one focused key as a stream Op_Input byte to the
   --  focused window's input endpoint (Stream_Request layout:
   --  Count = word 0, Data (1) = word 1 byte 0).
   procedure Forward_Key (Ch : U64) is
   begin
      if Focus = 0 or else Wins (Focus).Input_EP = 0 then
         return;
      end if;
      Message.Label := Akernel_User.Streams.Op_Input;
      Message.Words := (others => 0);
      Message.Words (0) := 1;
      Message.Words (1) := Ch;
      Message.Caps := (others => 0);
      if IPC_Call (Wins (Focus).Input_EP) /= IPC_Ok then
         Debug_Put_Line ("bureau focus key forward failed");
      end if;
   end Forward_Key;

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

   --  Pointer starts centered.
   Cursor_Draw (Width / 2, Height / 2);

   --  Window-protocol service loop (v2: up to Max_Win slots).
   loop
      if IPC_Recv (Win_Svc) /= IPC_Ok then
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
               Win_Reply (Label, Win.Status_No_Slot, 0, 0, 0, 0);
            elsif Message.Words (0) = 0 or else Message.Words (1) = 0
            then
               Win_Reply (Label, Win.Status_Bad_Index, 0, 0, 0, 0);
            else
               PW := U64'Min (Message.Words (0), Width - 2 * Frame);
               PH := U64'Min (Message.Words (1),
                              Height - 2 * Frame - Title_H);
               if (PW * PH * 4 + 4095) / 4096 >
                 U64 (Surf_Max_Objects) * 64
               then
                  Win_Reply (Label, Win.Status_No_Slot, 0, 0, 0, 0);
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
                  Wins (Slot).Input_EP := Message.Caps (0);
                  Wins (Slot).Title    := (others => ' ');
                  Wins (Slot).Title_Len := 0;
                  Z_N := Z_N + 1;
                  Z (Z_N) := Slot;
                  Focus_Slot (Slot);
                  Repaint_Window (Slot);
                  Win_Reply (Label, Win.Status_Ok,
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
               Win_Reply (Label, Win.Status_Bad_Id, 0, 0, 0, 0);
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
                  Win_Reply (Label, St, 0, 0, 0, 0);
               end;
            end if;
         end;

      elsif Label = Win.Op_Surface_Commit_Buffer then
         declare
            S : constant Natural := Slot_Of (Message.Words (0));
         begin
            if S = 0 or else Wins (S).Mapped then
               Win_Reply (Label, Win.Status_Bad_Id, 0, 0, 0, 0);
            elsif U64 (Wins (S).Got) /= (Wins (S).Pages + 63) / 64 then
               Win_Reply (Label, Win.Status_Bad_Index, 0, 0, 0, 0);
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
                  Win_Reply (Label, St, 0, 0, 0, 0);
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
                     Paint_Band (Pane_X (S) + CX, Pane_Y (S) + CY,
                                 Pane_X (S) + CX + CW,
                                 Pane_Y (S) + CY + CH);
                     Present_Band (Pane_X (S) + CX, Pane_Y (S) + CY,
                                   CW, CH);
                  end if;
               end;
               Win_Reply (Label, Win.Status_Ok, 0, 0, 0, 0);
            else
               Win_Reply (Label, Win.Status_Bad_Id, 0, 0, 0, 0);
            end if;
         end;

      elsif Label = Win.Op_Surface_Destroy then
         declare
            S : constant Natural := Slot_Of (Message.Words (0));
         begin
            if S = 0 then
               Win_Reply (Label, Win.Status_Bad_Id, 0, 0, 0, 0);
            else
               declare
                  FX : constant U64 := Wins (S).X;
                  FY : constant U64 := Wins (S).Y;
                  FW : constant U64 := Wins (S).FW;
                  FH : constant U64 := Wins (S).FH;
               begin
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
                  if Wins (S).Input_EP /= 0 then
                     Result := Cap_Delete (Wins (S).Input_EP);
                  end if;
                  Wins (S).Used := False;
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
                  Paint_Band (FX, FY, FX + FW, FY + FH);
                  Present_Band (FX, FY, FW, FH);
                  Win_Reply (Label, Win.Status_Ok, 0, 0, 0, 0);
               end;
            end if;
         end;

      elsif Label = Win.Op_Set_Title then
         declare
            S : constant Natural := Slot_Of (Message.Words (0));
         begin
            if S = 0 then
               Win_Reply (Label, Win.Status_Bad_Id, 0, 0, 0, 0);
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
                  Win_Reply (Label, Win.Status_Ok, 0, 0, 0, 0);
               end;
            end if;
         end;

      elsif Label = Win.Op_Set_Focus then
         --  v1 devmgr wiring, obsolete in v2 (focus is internal).
         --  Answer and drop the cap so the table stays clean.
         if Message.Caps (0) /= 0 then
            Result := Cap_Delete (Message.Caps (0));
         end if;
         Win_Reply (Label, Win.Status_Ok, 0, 0, 0, 0);

      elsif Label = Win.Op_Key then
         declare
            Ch : constant U64 := Message.Words (0);
         begin
            --  Interim chain proof (remove when the shell lands,
            --  milestone 31): serial-log each key.
            Debug_Put_Line ("bureau key");
            Forward_Key (Ch);
         end;
         Win_Reply (Label, Win.Status_Ok, 0, 0, 0, 0);

      elsif Label = Win.Op_Pointer then
         declare
            NX : constant U64 :=
              Message.Words (0) * Width / 32768;
            NY : constant U64 :=
              Message.Words (1) * Height / 32768;
         begin
            Cursor_Move (NX, NY);
         end;
         Win_Reply (Label, Win.Status_Ok, 0, 0, 0, 0);

      else
         Win_Reply (Label, Win.Status_Ok, 0, 0, 0, 0);
      end if;
   end loop;
end Bureau;
