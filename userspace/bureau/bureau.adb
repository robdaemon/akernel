with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Display;
with Akernel_User.Window;
with Akernel_User.Streams;
with Font8x8;

--  Bureau: the compositor / window server (milestone 28, slice 2).
--  Spawned by the device manager right after the virtio-gpu driver
--  comes up and its endpoint is attached as a console sink. Grant
--  ABI (2 handles): 1 = console endpoint (Send, badged),
--  2 = display service endpoint (Send).
--
--  Bureau ALLOCATES the compositing buffer (caps move caller ->
--  callee only), pushes its chunk caps to the display service
--  (Op_Set_Buffer), commits (scanout backing re-attaches onto
--  Bureau's pages — the driver's own framebuffer goes dark, the
--  text console's writes become invisible; the terminal client
--  retakes the sink in slice 3), renders the desktop + screen
--  bar + one matted window, and pushes the full frame with
--  Op_Present. Workbench-3.x-style gadtools look: gray palette,
--  white/dark 3D bevels, blue ACTIVE title bar. Exact hex
--  values are tunable (user call).
--
--  Slice 2 stops here: no clients, no seat. Bureau blocks on an
--  endpoint nobody calls (slice 3 adds the window protocol).
--
--  Slice 3: window protocol v1 (Akernel_User.Window, labels 20+)
--  on handle 3. Exactly one surface slot: the first
--  Op_Surface_Create binds the window drawn above; the client
--  pushes its surface chunk caps, Bureau maps them read-only
--  and copies Op_Surface_Update bands into the compositing
--  buffer at the pane origin, presenting each band to the
--  display service (wl_shm model).

procedure Bureau is
   use Akernel_User.Syscalls;
   use type U64;
   use type Interfaces.Unsigned_8;

   Console_EP : constant U64 := 1;
   Display_EP : constant U64 := 2;
   Win_Svc    : constant U64 := 3;

   Buf_VA   : constant U64 := 16#6000_0000#;
   Surf_VA  : constant U64 := 16#6800_0000#;

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
   Title_Text : constant Pixel := 16#FFFF_FFFF#;
   Pane       : constant Pixel := 16#FFF8_F8F8#;
   Text_Dark  : constant Pixel := 16#FF20_2020#;

   Bar_H    : constant := 18;   --  screen bar height
   Title_H  : constant := 20;   --  window title bar height
   Frame    : constant := 4;    --  window frame thickness
   Win_X    : constant := 64;
   Win_Y    : constant := 48;
   Win_W    : constant := 704;
   Win_H    : constant := 500;

   Result : U64;

   ------------------------------------------------------------------
   --  Window protocol v1 state: exactly one surface slot
   ------------------------------------------------------------------

   package Win renames Akernel_User.Window;

   Surf_Max_Objects : constant := 8;
   Surf_Id     : U64 := 0;  --  0 = slot free
   Surf_W      : U64 := 0;
   Surf_H      : U64 := 0;
   Surf_Pages  : U64 := 0;
   Surf_Got    : Natural := 0;
   Surf_Mapped : Boolean := False;
   Surf_Caps   : array (0 .. Surf_Max_Objects - 1) of U64 :=
     (others => 0);

   Surf : Pixel_Array
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (Surf_VA));

   Pane_X0 : constant U64 := Win_X + Frame;
   Pane_Y0 : constant U64 := Win_Y + Frame + Title_H;
   Pane_W  : constant U64 := Win_W - 2 * Frame;
   Pane_H  : constant U64 := Win_H - 2 * Frame - Title_H;

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

   --  Cursor state (bodies in the seat section below; Update_Band
   --  redraws the sprite when a band clobbers it).
   Cur_W : constant := 10;
   Cur_H : constant := 16;
   Cur_X   : U64 := 0;
   Cur_Y   : U64 := 0;
   Cur_Vis : Boolean := False;
   procedure Cursor_Draw (NX, NY : U64);

   --  Copy a damaged band from the client surface into the
   --  compositing buffer at the pane origin, then present it.
   procedure Update_Band (X, Y, W, H : U64) is
      CX : constant U64 := U64'Min (X, Surf_W);
      CY : constant U64 := U64'Min (Y, Surf_H);
      CW : constant U64 := U64'Min (W, Surf_W - CX);
      CH : constant U64 := U64'Min (H, Surf_H - CY);
      Stride_Px : constant U64 := Stride / 4;
   begin
      if CW = 0 or else CH = 0 then
         return;
      end if;
      for Row in 0 .. CH - 1 loop
         for Col in 0 .. CW - 1 loop
            Buf ((Pane_Y0 + CY + Row) * Stride_Px +
                   Pane_X0 + CX + Col) :=
              Surf ((CY + Row) * Surf_W + CX + Col);
         end loop;
      end loop;
      Result := Akernel_User.Display.Present
        (Display_EP, Pane_X0 + CX, Pane_Y0 + CY, CW, CH);

      --  The band copy may have clobbered the software cursor:
      --  redraw it (re-saves the under-rect fresh).
      if Cur_Vis
        and then Pane_X0 + CX < Cur_X + Cur_W
        and then Cur_X < Pane_X0 + CX + CW
        and then Pane_Y0 + CY < Cur_Y + Cur_H
        and then Cur_Y < Pane_Y0 + CY + CH
      then
         Cursor_Draw (Cur_X, Cur_Y);
      end if;
   end Update_Band;

   ------------------------------------------------------------------
   --  Seat: focus endpoint + software cursor (the arch-independent
   --  fallback by design; virtio hw cursor ops stay reserved in
   --  the display protocol)
   ------------------------------------------------------------------

   Focus_EP : U64 := 0;  --  focused client's stream EP (Send)

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

   --  Forward one focused key as a stream Op_Input byte
   --  (Stream_Request layout: Count = word 0, Data (1) = word 1
   --  byte 0).
   procedure Forward_Key (Ch : U64) is
   begin
      Message.Label := Akernel_User.Streams.Op_Input;
      Message.Words := (others => 0);
      Message.Words (0) := 1;
      Message.Words (1) := Ch;
      Message.Caps := (others => 0);
      if IPC_Call (Focus_EP) /= IPC_Ok then
         Debug_Put_Line ("bureau focus key forward failed");
      end if;
   end Forward_Key;

   procedure Fail (S : String) is
   begin
      Debug_Put_Line ("FAIL bureau " & S);
      Process_Exit;
   end Fail;

   ------------------------------------------------------------------
   --  Pixel plumbing
   ------------------------------------------------------------------

   procedure Set_Pixel (X, Y : U64; Color : Pixel) is
   begin
      if X < Width and then Y < Height then
         Buf (Y * (Stride / 4) + X) := Color;
      end if;
   end Set_Pixel;

   procedure Fill_Rect (X0, Y0, X1, Y1 : U64; Color : Pixel) is
      Row0 : constant U64 := U64'Min (Y0, Height);
      Row1 : constant U64 := U64'Min (Y1, Height);
      Col0 : constant U64 := U64'Min (X0, Width);
      Col1 : constant U64 := U64'Min (X1, Width);
   begin
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

   ------------------------------------------------------------------
   --  Desktop composition
   ------------------------------------------------------------------

   procedure Draw_Gadget (GX, GY, Size : U64) is
   begin
      Fill_Rect (GX, GY, GX + Size, GY + Size, Win_Face);
      Bevel (GX, GY, GX + Size, GY + Size);
   end Draw_Gadget;

   procedure Compose is
      Title_Y : constant U64 := Win_Y + Frame;
      Pane_Y  : constant U64 := Title_Y + Title_H;
   begin
      --  Desktop + screen bar (bar reads "Bureau", right-side
      --  depth gadget placeholder).
      Fill_Rect (0, 0, Width, Height, Desktop);
      Fill_Rect (0, 0, Width, Bar_H, Bar_Face);
      Fill_Rect (0, Bar_H, Width, Bar_H + 1, Bevel_Lo);
      Draw_Text (8, 5, "Bureau", Text_Dark, Bar_Face, Stretch => 1);
      Draw_Gadget (Width - 24, 1, 16);

      --  Window: 2px dark frame, raised bevel inside it, blue
      --  ACTIVE title bar with close/depth gadgets, white pane.
      Fill_Rect (Win_X, Win_Y, Win_X + Win_W, Win_Y + Win_H, Border);
      Bevel (Win_X + 2, Win_Y + 2,
             Win_X + Win_W - 2, Win_Y + Win_H - 2);
      Fill_Rect (Win_X + Frame, Title_Y,
                 Win_X + Win_W - Frame, Title_Y + Title_H, Title_Blue);
      Draw_Gadget (Win_X + Frame + 2, Title_Y + 2, Title_H - 4);
      Draw_Gadget (Win_X + Win_W - Frame - Title_H + 2, Title_Y + 2,
                   Title_H - 4);
      Draw_Text (Win_X + Frame + Title_H + 8, Title_Y + 2,
                 "System/Terminal", Title_Text, Title_Blue);
      Fill_Rect (Win_X + Frame, Pane_Y,
                 Win_X + Win_W - Frame, Win_Y + Win_H - Frame, Pane);
   end Compose;

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

   --  5. Compose and present the full frame.
   Compose;
   if Akernel_User.Display.Present (Display_EP, 0, 0, Width, Height)
     /= Akernel_User.Display.Status_Ok
   then
      Fail ("present failed");
   end if;
   Debug_Put_Line ("bureau desktop online");

   --  Pointer starts centered.
   Cursor_Draw (Width / 2, Height / 2);

   --  Window-protocol service loop: one surface slot (v1).
   loop
      if IPC_Recv (Win_Svc) /= IPC_Ok then
         Debug_Put_Line ("bureau recv failed");
         Process_Exit;
      end if;
      Label := Message.Label;

      if Label = Win.Op_Surface_Create then
         if Surf_Id /= 0 then
            Win_Reply (Label, Win.Status_No_Slot, 0, 0, 0, 0);
         elsif Message.Words (0) = 0 or else Message.Words (1) = 0 then
            Win_Reply (Label, Win.Status_Bad_Index, 0, 0, 0, 0);
         else
            Surf_W := U64'Min (Message.Words (0), Pane_W);
            Surf_H := U64'Min (Message.Words (1), Pane_H);
            Surf_Pages := (Surf_W * Surf_H * 4 + 4095) / 4096;
            if (Surf_Pages + 63) / 64 > Surf_Max_Objects then
               Win_Reply (Label, Win.Status_No_Slot, 0, 0, 0, 0);
            else
               Surf_Id := 1;
               Surf_Got := 0;
               Surf_Mapped := False;
               Surf_Caps := (others => 0);
               Win_Reply (Label, Win.Status_Ok,
                          Surf_Id, Surf_Pages, Surf_W, Surf_H);
            end if;
         end if;

      elsif Label = Win.Op_Surface_Set_Buffer then
         if Message.Words (0) /= Surf_Id or else Surf_Id = 0
           or else Surf_Mapped
         then
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
                    or else Surf_Caps (Natural (Idx)) /= 0
                  then
                     St := Win.Status_Bad_Index;
                     Result := Cap_Delete (Message.Caps (I));
                  else
                     Surf_Caps (Natural (Idx)) := Message.Caps (I);
                     Surf_Got := Surf_Got + 1;
                  end if;
               end loop;
               Win_Reply (Label, St, 0, 0, 0, 0);
            end;
         end if;

      elsif Label = Win.Op_Surface_Commit_Buffer then
         if Message.Words (0) /= Surf_Id or else Surf_Id = 0
           or else Surf_Mapped
         then
            Win_Reply (Label, Win.Status_Bad_Id, 0, 0, 0, 0);
         elsif U64 (Surf_Got) /= (Surf_Pages + 63) / 64 then
            Win_Reply (Label, Win.Status_Bad_Index, 0, 0, 0, 0);
         else
            declare
               St : U64 := Win.Status_Ok;
            begin
               for I in 0 .. Surf_Got - 1 loop
                  This := U64'Min (Surf_Pages - U64 (I) * 64, 64);
                  if Mem_Map
                    (Address_Space => Address_Space_Cap,
                     Cap           => Surf_Caps (I),
                     VA            => Surf_VA + U64 (I) * 64 * 4096,
                     Offset        => 0,
                     Length        => This * 4096,
                     Flags         => 1) /= 0
                  then
                     St := Win.Status_Bad_Caps;
                  end if;
               end loop;
               if St = Win.Status_Ok then
                  Surf_Mapped := True;
               end if;
               Win_Reply (Label, St, 0, 0, 0, 0);
            end;
         end if;

      elsif Label = Win.Op_Surface_Update then
         if Message.Words (0) = Surf_Id and then Surf_Mapped then
            Update_Band (Message.Words (1), Message.Words (2),
                         Message.Words (3), Message.Words (4));
            Win_Reply (Label, Win.Status_Ok, 0, 0, 0, 0);
         else
            Win_Reply (Label, Win.Status_Bad_Id, 0, 0, 0, 0);
         end if;

      elsif Label = Win.Op_Set_Focus then
         --  Devmgr pushes the focused client's stream endpoint.
         Focus_EP := Message.Caps (0);
         Win_Reply (Label, Win.Status_Ok, 0, 0, 0, 0);

      elsif Label = Win.Op_Key then
         if Focus_EP /= 0 then
            declare
               Ch : constant U64 := Message.Words (0);
            begin
               --  Interim chain proof (remove when the shell
               --  lands, milestone 30): serial-log each key.
               Debug_Put_Line ("bureau key");
               Forward_Key (Ch);
            end;
         end if;
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
         --  Op_Surface_Destroy (no-op in v1) and unknown labels.
         Win_Reply (Label, Win.Status_Ok, 0, 0, 0, 0);
      end if;
   end loop;
end Bureau;
