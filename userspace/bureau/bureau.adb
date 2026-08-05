with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Console;
with Akernel_User.Syscalls;
with Akernel_User.Display;
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

procedure Bureau is
   use Akernel_User.Syscalls;
   use type U64;
   use type Interfaces.Unsigned_8;

   Console_EP : constant U64 := 1;
   Display_EP : constant U64 := 2;

   Buf_VA : constant U64 := 16#6000_0000#;

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

   --  Workbench-3.x-ish palette. Burned: the scanout interprets
   --  each LE u32 pixel as AABBGGRR (low byte = RED) despite the
   --  resource being created as format 1 "B8G8R8A8" — verified by
   --  screendump channel decode (a 16#FF6068B0# "blue" title bar
   --  rendered red). The old text console never noticed: white
   --  and black are channel-symmetric.
   Desktop    : constant Pixel := 16#FFA4_A0A0#;
   Bar_Face   : constant Pixel := 16#FFC4_C0C0#;
   Win_Face   : constant Pixel := 16#FFC4_C0C0#;
   Bevel_Hi   : constant Pixel := 16#FFFF_FFFF#;
   Bevel_Lo   : constant Pixel := 16#FF40_4040#;
   Border     : constant Pixel := 16#FF10_1010#;
   Title_Blue : constant Pixel := 16#FFB0_6860#;
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

   procedure Fail (S : String) is
   begin
      Akernel_User.Console.Put_Line ("FAIL bureau " & S);
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
   Idle_EP    : U64;

begin
   Akernel_User.Console.Set_Endpoint (Console_EP);

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
   Akernel_User.Console.Put_Line ("PASS bureau display info ok");

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
   Akernel_User.Console.Put_Line ("PASS bureau display commit ok");

   --  5. Compose and present the full frame.
   Compose;
   if Akernel_User.Display.Present (Display_EP, 0, 0, Width, Height)
     /= Akernel_User.Display.Status_Ok
   then
      Fail ("present failed");
   end if;
   Akernel_User.Console.Put_Line ("bureau desktop online");

   --  Slice 2 stops here: block forever (no clients yet).
   Idle_EP := EP_Create;
   loop
      Result := IPC_Recv (Idle_EP);
   end loop;
end Bureau;
