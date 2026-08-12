with System;
with System.Storage_Elements;
with Interfaces;
with Ada.Streams;
with Akernel_User.Console;
with Akernel_User.Syscalls;
with Akernel_User.IPC;
with Akernel_User.Streams;
with Akernel_User.Display;
with Virtio;
with Virtio.PCI;
with Virtio.Queues;
with Font8x8;

--  Virtio GPU driver over the PCI transport (virtio-gpu-pci,
--  transitional id 1af4:1010 or modern 1050). Spawned by init's
--  device manager when the PCI bus scan matches a System/Drivers
--  pci line of class 16. Fixed 7-handle PCI driver ABI (grant
--  order): 1 = console endpoint (Send), 2 = common-cfg MMIO cap,
--  3 = notify MMIO cap, 4 = ISR MMIO cap, 5 = device-cfg MMIO cap,
--  6 = IRQ cap, 7 = service endpoint (Receive).
--
--  2D only (no feature bits negotiated): controlq carries
--  GET_DISPLAY_INFO / RESOURCE_CREATE_2D / ATTACH_BACKING /
--  SET_SCANOUT / TRANSFER_TO_HOST_2D / RESOURCE_FLUSH; the cursor
--  queue is left idle. The framebuffer is B8G8R8A8 backing-store
--  pages (kernel memory objects, 64 pages max each, so a 3 MiB
--  framebuffer is a list of objects; ATTACH_BACKING entries are
--  per page). After bring-up the driver renders TEXT: an 8x16
--  console (font8x8 stretched 2x vertically) served through the
--  stream protocol on handle 7 — the console server mirrors its
--  line-atomic output here once the device manager attaches this
--  endpoint as a sink (Op_Attach_Sink).
--
--  The same endpoint ALSO serves the display-service protocol
--  (Akernel_User.Display, labels 10+): the compositor (Bureau)
--  allocates the compositing buffer and pushes its memory-object
--  chunk caps here (Op_Set_Buffer x N, caps move caller ->
--  callee only), Op_Commit_Buffer re-attaches the scanout
--  resource's backing onto those pages, and Op_Present pushes
--  pixel bands straight from the compositor's buffer. The text
--  console above keeps working against the driver's own boot
--  framebuffer until a compositor commits (its writes become
--  invisible then — Bureau's terminal client takes the sink
--  over in slice 3).
--
--  Burned: ALL driver log output (PASS/FAIL/online) goes through
--  Debug_Put_Line (kernel UART), NEVER the console stream: the
--  console server blocks in the sink-write RPC while this driver
--  is still initializing, so a console print here would deadlock
--  (server waits for this driver to Receive, driver waits for the
--  server to Receive).
--
--  Self-test (before the service loop):
--    GET_DISPLAY_INFO -> OK_DISPLAY_INFO with an enabled mode
--    CREATE_2D + ATTACH_BACKING + SET_SCANOUT + pattern
--    TRANSFER + FLUSH -> every response OK_NODATA
--  End-to-end pixel verification is host-side: qemu monitor
--  screendump of the virtio console shows the rendered text.

procedure Virtio_Gpu is
   use Akernel_User.Syscalls;
   use type U64;
   use type Virtio.U8;
   use type Virtio.U16;
   use type Virtio.U32;
   use type Interfaces.Unsigned_8;

   subtype U8 is Interfaces.Unsigned_8;

   Console_EP : constant U64 := 1;
   Common_Cap : constant U64 := 2;
   Notify_Cap : constant U64 := 3;
   ISR_Cap    : constant U64 := 4;
   Cfg_Cap    : constant U64 := 5;
   IRQ_Cap    : constant U64 := 6;
   Svc_EP     : constant U64 := 7;

   Common_VA : constant U64 := 16#5000_0000#;
   Notify_VA : constant U64 := 16#5000_1000#;
   ISR_VA    : constant U64 := 16#5000_2000#;
   Cfg_VA    : constant U64 := 16#5000_3000#;
   DMA_VA    : constant U64 := 16#5004_0000#;
   FB_VA     : constant U64 := 16#5040_0000#;
   --  DMA object layout: page 0 descriptors, page 1 avail ring,
   --  page 2 used ring, page 3 command buffer, page 4 response
   --  buffer, pages 5..7 attach-backing entries (3 pages = 768
   --  entries = up to 3 MiB of framebuffer, one entry per page).
   DMA_Pages  : constant U64 := 8;
   Max_Entries : constant U64 := 3 * 4096 / 16;

   --  First service-endpoint message from the device manager.
   Driver_Config_Label : constant U64 := U64'Last - 1;

   --  virtio-gpu control commands/responses (virtio 1.2 §5.7.6,
   --  cross-checked against linux virtio_gpu.h).
   Cmd_Get_Display_Info : constant Virtio.U32 := 16#100#;
   Cmd_Resource_Create_2D  : constant Virtio.U32 := 16#101#;
   Cmd_Set_Scanout      : constant Virtio.U32 := 16#103#;
   Cmd_Resource_Flush   : constant Virtio.U32 := 16#104#;
   Cmd_Transfer_To_Host : constant Virtio.U32 := 16#105#;
   Cmd_Attach_Backing   : constant Virtio.U32 := 16#106#;
   Cmd_Detach_Backing   : constant Virtio.U32 := 16#107#;

   Resp_Ok_Nodata       : constant Virtio.U32 := 16#1100#;
   Resp_Ok_Display_Info : constant Virtio.U32 := 16#1101#;

   Format_B8G8R8A8 : constant Virtio.U32 := 1;
   Resource_Id     : constant Virtio.U32 := 1;

   --  Text console geometry: 8x16 cells (8x8 font stretched 2x
   --  vertically). Display clamped to [640x480 .. 1024x768].
   Max_W : constant := 1024;
   Max_H : constant := 768;
   Min_W : constant := 640;
   Min_H : constant := 480;

   FG : constant Virtio.U32 := 16#FFFF_FFFF#;  --  white
   BG : constant Virtio.U32 := 16#FF00_0000#;  --  black (opaque)

   ------------------------------------------------------------------
   --  Region register access
   ------------------------------------------------------------------

   type U8_File is array (U64 range 0 .. 4095) of Virtio.U8
     with Volatile_Components;
   type U16_File is array (U64 range 0 .. 2047) of Virtio.U16
     with Volatile_Components;
   type U32_File is array (U64 range 0 .. 1023) of Virtio.U32
     with Volatile_Components;

   function To_Addr (VA : U64) return System.Address is
     (System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (VA)));

   Common8  : U8_File  with Address => To_Addr (Common_VA);
   Common16 : U16_File with Address => To_Addr (Common_VA);
   Common32 : U32_File with Address => To_Addr (Common_VA);
   Notify16 : U16_File with Address => To_Addr (Notify_VA);
   ISR8     : U8_File  with Address => To_Addr (ISR_VA);
   Cfg32    : U32_File with Address => To_Addr (Cfg_VA);

   function Common_Read8 (Offset : U64) return Virtio.U8 is
     (Common8 (Offset));
   function Common_Read16 (Offset : U64) return Virtio.U16 is
     (Common16 (Offset / 2));
   function Common_Read32 (Offset : U64) return Virtio.U32 is
     (Common32 (Offset / 4));

   procedure Common_Write8 (Offset : U64; Value : Virtio.U8) is
   begin
      Common8 (Offset) := Value;
   end Common_Write8;

   procedure Common_Write16 (Offset : U64; Value : Virtio.U16) is
   begin
      Common16 (Offset / 2) := Value;
   end Common_Write16;

   procedure Common_Write32 (Offset : U64; Value : Virtio.U32) is
   begin
      Common32 (Offset / 4) := Value;
   end Common_Write32;

   function ISR_Read return Virtio.U32 is
     (Virtio.U32 (ISR8 (0)));

   Notify_Mult : U64 := 0;

   procedure Notify_Write (Notify_Offset : U64; Value : Virtio.U16) is
   begin
      Notify16 ((Notify_Offset * Notify_Mult) / 2) := Value;
   end Notify_Write;

   package Dev is new Virtio.PCI
     (Common_Read8   => Common_Read8,
      Common_Read16  => Common_Read16,
      Common_Read32  => Common_Read32,
      Common_Write8  => Common_Write8,
      Common_Write16 => Common_Write16,
      Common_Write32 => Common_Write32,
      ISR_Read       => ISR_Read,
      Notify_Write   => Notify_Write);

   ------------------------------------------------------------------
   --  DMA overlays
   ------------------------------------------------------------------

   --  Command page: hdr is words 0..5 (type, flags, fence_id u64,
   --  ctx_id, ring/padding); payload words from 6 on.
   type Word_Array is array (Natural range 0 .. 1023) of Virtio.U32
     with Volatile_Components;

   --  Entries span pages 5..7 (3072 words = 768 entries).
   type Ent_Array is array (Natural range 0 .. 3071) of Virtio.U32
     with Volatile_Components;

   Cmd_Words  : Word_Array with Address => To_Addr (DMA_VA + 3 * 4096);
   Resp_Words : Word_Array with Address => To_Addr (DMA_VA + 4 * 4096);
   Ent_Words  : Ent_Array  with Address => To_Addr (DMA_VA + 5 * 4096);

   --  Framebuffer pixel overlay (max geometry).
   type Pixel_Array is
     array (U64 range 0 .. Max_W * Max_H - 1) of Virtio.U32
     with Volatile_Components;

   FB : Pixel_Array with Address => To_Addr (FB_VA);

   ------------------------------------------------------------------

   Result    : U64;
   DMA_Cap   : U64;
   Ntfn_Cap  : U64;
   Bits      : U64;
   ISR       : Virtio.U32;
   Q         : Virtio.Queues.Queue;
   Desc_PA   : U64;
   Avail_PA  : U64;
   Used_PA   : U64;
   Cmd_PA    : U64;
   Resp_PA   : U64;
   Ent_PA    : U64;
   Head      : Virtio.U16;
   Written   : Virtio.U32;

   --  Display geometry (after display-info clamp).
   Width  : Natural := 0;
   Height : Natural := 0;
   Cols   : Natural := 0;  --  Width / 8
   Rows   : Natural := 0;  --  Height / 16

   --  Text cursor and dirty pixel-row band.
   Cur_Col  : Natural := 0;
   Cur_Row  : Natural := 0;
   Dirty_Y0 : Natural := Natural'Last;
   Dirty_Y1 : Natural := 0;

   FB_Objects : constant := (Max_W * Max_H * 4) / 4096 / 64;  --  12
   FB_Caps : array (0 .. FB_Objects - 1) of U64 := (others => 0);
   FB_Obj_Count : Natural := 0;

   --  Compositor buffer handoff (display-service protocol): chunk
   --  caps pushed by Op_Set_Buffer until Op_Commit_Buffer swaps
   --  the scanout backing. Kept for the session once received
   --  (deliberate exception to the per-op cap_delete rule — the
   --  frames must outlive the compositor).
   New_Caps   : array (0 .. FB_Objects - 1) of U64 := (others => 0);
   New_Chunks : Natural := 0;

   FB_Pages  : U64;
   Obj_Pages : U64;
   PA        : U64;
   Ent_Count : U64;

   procedure Fail (S : String) is
   begin
      Debug_Put_Line ("FAIL " & S);
      Process_Exit;
   end Fail;

   procedure Map_Region (Cap : U64; VA : U64; Name : String) is
   begin
      Result := Map_MMIO
        (Address_Space => Address_Space_Cap,
         Cap           => Cap,
         VA            => VA,
         Offset        => 0,
         Length        => 4096,
         Flags         => 3);
      if Result /= 0 then
         Debug_Put_Line ("virtio-gpu map " & Name & " failed");
         Process_Exit;
      end if;
   end Map_Region;

   --  Run one controlq command synchronously: descriptor chain is
   --  [command (OUT)] (+ [entries (OUT)] when Extra_Len > 0)
   --  [response (IN)]. Returns the response header type.
   function Ctrl_Cmd
     (Cmd_Len   : Virtio.U32;
      Extra_Len : Virtio.U32 := 0;
      Resp_Len  : Virtio.U32 := 24) return Virtio.U32
   is
      H : constant Virtio.U16 := Virtio.Queues.Alloc (Q);
      R : constant Virtio.U16 := Virtio.Queues.Alloc (Q);
      Spins : Natural;
      Prev  : Virtio.U16;
   begin
      Resp_Words (0) := 16#FFFF_FFFF#;

      Virtio.Queues.Set_Buffer
        (Q, H, Cmd_PA, Cmd_Len, Device_Writes => False);
      if Extra_Len > 0 then
         declare
            E : constant Virtio.U16 := Virtio.Queues.Alloc (Q);
         begin
            Virtio.Queues.Chain_Next (Q, H, E);
            Virtio.Queues.Set_Buffer
              (Q, E, Ent_PA, Extra_Len, Device_Writes => False);
            Prev := E;
         end;
      else
         Prev := H;
      end if;
      Virtio.Queues.Chain_Next (Q, Prev, R);
      Virtio.Queues.Set_Buffer
        (Q, R, Resp_PA, Resp_Len, Device_Writes => True);
      Virtio.Queues.Submit (Q, H);
      Dev.Notify (0);

      Spins := 0;
      loop
         ISR := Dev.Interrupt_Status;
         if ISR /= 0 then
            Dev.ACK_Interrupt (ISR);
         end if;

         Result := IRQ_Ack (IRQ_Cap);

         exit when Virtio.Queues.Has_Completed (Q);

         Spins := Spins + 1;
         if Spins > 1_000 then
            Fail ("virtio-gpu command timeout");
         end if;

         Bits := Ntfn_Wait (Ntfn_Cap);
      end loop;

      Virtio.Queues.Pop (Q, Head, Written);
      Virtio.Queues.Free (Q, Head);
      return Resp_Words (0);
   end Ctrl_Cmd;

   --  Hdr words 0..5; payload from word 6.
   procedure Set_Hdr (Cmd : Virtio.U32) is
   begin
      Cmd_Words (0) := Cmd;
      Cmd_Words (1) := 0;
      Cmd_Words (2) := 0;
      Cmd_Words (3) := 0;
      Cmd_Words (4) := 0;
      Cmd_Words (5) := 0;
   end Set_Hdr;

   procedure Set_Rect (X, Y, W, H : Virtio.U32) is
   begin
      Cmd_Words (6) := X;
      Cmd_Words (7) := Y;
      Cmd_Words (8) := W;
      Cmd_Words (9) := H;
   end Set_Rect;

   ------------------------------------------------------------------
   --  Text renderer
   ------------------------------------------------------------------

   procedure Touch (Y0, Y1 : Natural) is
   begin
      if Y0 < Dirty_Y0 then
         Dirty_Y0 := Y0;
      end if;
      if Y1 > Dirty_Y1 then
         Dirty_Y1 := Y1;
      end if;
   end Touch;

   procedure Fill_Rect (X0, Y0, X1, Y1 : Natural; Color : Virtio.U32) is
   begin
      for Y in Y0 .. Y1 - 1 loop
         for X in X0 .. X1 - 1 loop
            FB (U64 (Y * Width + X)) := Color;
         end loop;
      end loop;
      Touch (Y0, Y1);
   end Fill_Rect;

   procedure Draw_Glyph (Col, Row : Natural; Ch : Character) is
      GX   : constant Natural := Col * 8;
      GY   : constant Natural := Row * 16;
      Bits : Font8x8.U8;
   begin
      for R in 0 .. 7 loop
         if Ch in ' ' .. '~' then
            Bits := Font8x8.Font (Ch) (R);
         else
            Bits := Font8x8.Font ('?') (R);
         end if;
         for Rep in 0 .. 1 loop
            declare
               Base : constant U64 :=
                 U64 ((GY + R * 2 + Rep) * Width + GX);
            begin
               --  font8x8: bit 0 is the LEFTMOST pixel (the
               --  header comment says bit 7 — wrong, mirrored
               --  output proved it on the real display).
               for B in 0 .. 7 loop
                  if (Interfaces.Shift_Right (Bits, B) and 1) = 1 then
                     FB (Base + U64 (B)) := FG;
                  else
                     FB (Base + U64 (B)) := BG;
                  end if;
               end loop;
            end;
         end loop;
      end loop;
      Touch (GY, GY + 16);
   end Draw_Glyph;

   procedure Scroll is
   begin
      for Y in 0 .. Height - 17 loop
         for X in 0 .. Width - 1 loop
            FB (U64 (Y * Width + X)) := FB (U64 ((Y + 16) * Width + X));
         end loop;
      end loop;
      for Y in Height - 16 .. Height - 1 loop
         for X in 0 .. Width - 1 loop
            FB (U64 (Y * Width + X)) := BG;
         end loop;
      end loop;
      Touch (0, Height);
   end Scroll;

   procedure New_Line is
   begin
      Cur_Col := 0;
      if Cur_Row = Rows - 1 then
         Scroll;
      else
         Cur_Row := Cur_Row + 1;
      end if;
   end New_Line;

   procedure Put_Char (Ch : Character) is
      Code : constant Natural := Character'Pos (Ch);
   begin
      if Code = 10 then
         New_Line;
      elsif Code = 13 then
         Cur_Col := 0;
      elsif Code = 9 then
         Cur_Col := (Cur_Col + 4) / 4 * 4;
         if Cur_Col >= Cols then
            New_Line;
         end if;
      elsif Code = 8 then
         if Cur_Col > 0 then
            Cur_Col := Cur_Col - 1;
            Draw_Glyph (Cur_Col, Cur_Row, ' ');
         end if;
      elsif Code >= 32 and then Code < 127 then
         Draw_Glyph (Cur_Col, Cur_Row, Ch);
         Cur_Col := Cur_Col + 1;
         if Cur_Col = Cols then
            New_Line;
         end if;
      end if;
      --  Other control bytes dropped.
   end Put_Char;

   --  Push the dirty band to the host: TRANSFER_TO_HOST_2D copies
   --  backing-store bytes into the resource, RESOURCE_FLUSH updates
   --  the scanout on screen.
   procedure Flush_Dirty is
      Y0 : Natural;
      Y1 : Natural;
   begin
      if Dirty_Y1 <= Dirty_Y0 then
         return;
      end if;
      Y0 := Dirty_Y0;
      Y1 := Dirty_Y1;
      Dirty_Y0 := Natural'Last;
      Dirty_Y1 := 0;

      Set_Hdr (Cmd_Transfer_To_Host);
      Set_Rect (0, Virtio.U32 (Y0), Virtio.U32 (Width),
                Virtio.U32 (Y1 - Y0));
      Cmd_Words (10) := Virtio.U32 (Y0 * Width * 4);  --  byte offset
      Cmd_Words (11) := 0;
      Cmd_Words (12) := Resource_Id;
      Cmd_Words (13) := 0;
      if Ctrl_Cmd (56) /= Resp_Ok_Nodata then
         Debug_Put_Line ("virtio-gpu transfer failed");
         return;
      end if;

      Set_Hdr (Cmd_Resource_Flush);
      Set_Rect (0, Virtio.U32 (Y0), Virtio.U32 (Width),
                Virtio.U32 (Y1 - Y0));
      Cmd_Words (10) := Resource_Id;
      Cmd_Words (11) := 0;
      if Ctrl_Cmd (48) /= Resp_Ok_Nodata then
         Debug_Put_Line ("virtio-gpu flush failed");
      end if;
   end Flush_Dirty;

   ------------------------------------------------------------------
   --  Display-service protocol (Akernel_User.Display)
   ------------------------------------------------------------------

   package DSP renames Akernel_User.Display;

   --  Reply with raw words (the RPC generic marshals stream
   --  payloads; display replies are plain words).
   procedure Display_Reply (Reply_H : U64; Req_Label : U64; W0 : U64) is
   begin
      Message.Label := Req_Label;
      Message.Words (0) := W0;
      Message.Words (1) := U64 (Width);
      Message.Words (2) := U64 (Height);
      Message.Words (3) := U64 (Width * 4);
      Message.Words (4) := FB_Pages;
      Message.Words (5) := 64;
      if IPC_Reply (Reply_H) /= IPC_Ok then
         Debug_Put_Line ("virtio-gpu display reply failed");
         Process_Exit;
      end if;
   end Display_Reply;

   --  TRANSFER_TO_HOST_2D + RESOURCE_FLUSH for one pixel band.
   procedure Present_Band (X, Y, W, H : Natural) is
   begin
      if W = 0 or else H = 0 or else Width = 0 then
         return;
      end if;
      Set_Hdr (Cmd_Transfer_To_Host);
      Set_Rect (Virtio.U32 (X), Virtio.U32 (Y),
                Virtio.U32 (W), Virtio.U32 (H));
      Cmd_Words (10) := Virtio.U32 ((Y * Width + X) * 4);
      Cmd_Words (11) := 0;
      Cmd_Words (12) := Resource_Id;
      Cmd_Words (13) := 0;
      if Ctrl_Cmd (56) /= Resp_Ok_Nodata then
         Debug_Put_Line ("virtio-gpu present transfer failed");
         return;
      end if;

      Set_Hdr (Cmd_Resource_Flush);
      Set_Rect (Virtio.U32 (X), Virtio.U32 (Y),
                Virtio.U32 (W), Virtio.U32 (H));
      Cmd_Words (10) := Resource_Id;
      Cmd_Words (11) := 0;
      if Ctrl_Cmd (48) /= Resp_Ok_Nodata then
         Debug_Put_Line ("virtio-gpu present flush failed");
      end if;
   end Present_Band;

   --  Swap the scanout backing onto the compositor's chunks:
   --  DETACH the driver's boot framebuffer, ATTACH the stored
   --  caps' frames, push the full screen once.
   function Commit_Buffer return U64 is
      PA : U64;
      Pages_In : U64;
   begin
      if New_Chunks = 0 then
         return DSP.Status_No_Buffer;
      end if;
      if U64 (New_Chunks) /= (FB_Pages + 63) / 64 then
         return DSP.Status_Bad_Index;
      end if;

      Ent_Count := 0;
      for I in 0 .. New_Chunks - 1 loop
         Pages_In := U64'Min (FB_Pages - U64 (I) * 64, 64);
         for P in 0 .. Pages_In - 1 loop
            PA := Mem_Object_PA (New_Caps (I), P);
            if PA = 0 then
               return DSP.Status_Bad_Caps;
            end if;
            Ent_Words (Natural (Ent_Count) * 4) :=
              Virtio.U32 (PA and 16#FFFF_FFFF#);
            Ent_Words (Natural (Ent_Count) * 4 + 1) :=
              Virtio.U32 (PA / 16#1_0000_0000#);
            Ent_Words (Natural (Ent_Count) * 4 + 2) := 4096;
            Ent_Words (Natural (Ent_Count) * 4 + 3) := 0;
            Ent_Count := Ent_Count + 1;
         end loop;
      end loop;

      Set_Hdr (Cmd_Detach_Backing);
      Cmd_Words (6) := Resource_Id;
      Cmd_Words (7) := 0;
      if Ctrl_Cmd (32) /= Resp_Ok_Nodata then
         return DSP.Status_Device;
      end if;

      Set_Hdr (Cmd_Attach_Backing);
      Cmd_Words (6) := Resource_Id;
      Cmd_Words (7) := Virtio.U32 (Ent_Count);
      if Ctrl_Cmd (32, Extra_Len => Virtio.U32 (Ent_Count) * 16)
        /= Resp_Ok_Nodata
      then
         return DSP.Status_Device;
      end if;

      Present_Band (0, 0, Width, Height);
      return DSP.Status_Ok;
   end Commit_Buffer;

   ------------------------------------------------------------------

   package RPC is new Akernel_User.IPC
     (Akernel_User.Streams.Stream_Request,
      Akernel_User.Streams.Stream_Response);

   Status   : U64;
   Label    : U64;
   Badge    : U64;
   Request  : Akernel_User.Streams.Stream_Request;
   Response : Akernel_User.Streams.Stream_Response;
   Caps     : RPC.Cap_Array;
   Reply_H  : U64;

begin
   Akernel_User.Console.Set_Endpoint (Console_EP);

   Map_Region (Common_Cap, Common_VA, "common");
   Map_Region (Notify_Cap, Notify_VA, "notify");
   Map_Region (ISR_Cap,    ISR_VA,    "isr");
   Map_Region (Cfg_Cap,    Cfg_VA,    "cfg");

   --  Devmgr driver config message.
   Result := IPC_Recv (Svc_EP, Reply_H);
   if Result /= IPC_Ok or else Message.Label /= Driver_Config_Label then
      Debug_Put_Line ("virtio-gpu config message missing");
      Process_Exit;
   end if;
   Notify_Mult := Message.Words (0);
   Message.Words := (others => 0);
   if IPC_Reply (Reply_H) /= IPC_Ok then
      Debug_Put_Line ("virtio-gpu config reply failed");
      Process_Exit;
   end if;

   if Dev.Num_Queues < 1 or else Cfg32 (2) = 0 then  --  num_scanouts
      Debug_Put_Line ("virtio-gpu no queues/scanouts");
      Process_Exit;
   end if;

   Dev.Reset;
   Dev.Set_Status (Virtio.Status_Acknowledge);
   Dev.Add_Status (Virtio.Status_Driver);
   Dev.Set_Driver_Features (0);
   Dev.Add_Status (Virtio.Status_Features_Ok);

   if (Dev.Status and Virtio.Status_Features_Ok) = 0 then
      Debug_Put_Line ("virtio-gpu features rejected");
      Process_Exit;
   end if;

   Ntfn_Cap := Ntfn_Create;
   if Ntfn_Cap = Syscall_Failed
     or else Ntfn_Bind_Thread (Ntfn_Cap) /= 0
     or else IRQ_Bind_Ntfn (IRQ_Cap, Ntfn_Cap, 1) /= 0
   then
      Debug_Put_Line ("virtio-gpu ntfn setup failed");
      Process_Exit;
   end if;

   DMA_Cap := Mem_Alloc (DMA_Pages);
   if DMA_Cap = Syscall_Failed then
      Debug_Put_Line ("virtio-gpu dma alloc failed");
      Process_Exit;
   end if;

   Result := Mem_Map
     (Address_Space => Address_Space_Cap,
      Cap           => DMA_Cap,
      VA            => DMA_VA,
      Offset        => 0,
      Length        => DMA_Pages * 4096,
      Flags         => 3);
   if Result /= 0 then
      Debug_Put_Line ("virtio-gpu dma map failed");
      Process_Exit;
   end if;

   Desc_PA  := Mem_Object_PA (DMA_Cap, 0);
   Avail_PA := Mem_Object_PA (DMA_Cap, 1);
   Used_PA  := Mem_Object_PA (DMA_Cap, 2);
   Cmd_PA   := Mem_Object_PA (DMA_Cap, 3);
   Resp_PA  := Mem_Object_PA (DMA_Cap, 4);
   Ent_PA   := Mem_Object_PA (DMA_Cap, 5);
   if Desc_PA = 0 or else Avail_PA = 0 or else Used_PA = 0
     or else Cmd_PA = 0 or else Resp_PA = 0 or else Ent_PA = 0
   then
      Debug_Put_Line ("virtio-gpu dma pa query failed");
      Process_Exit;
   end if;

   Virtio.Queues.Initialize
     (Q     => Q,
      Desc  => To_Addr (DMA_VA),
      Avail => To_Addr (DMA_VA + 4096),
      Used  => To_Addr (DMA_VA + 2 * 4096),
      Num   => 8);

   Dev.Queue_Select (0);
   Dev.Queue_Setup
     (Num      => 8,
      Desc_PA  => Desc_PA,
      Avail_PA => Avail_PA,
      Used_PA  => Used_PA);
   Dev.Add_Status (Virtio.Status_Driver_Ok);

   ------------------------------------------------------------------
   --  Bring-up self-tests (all logging via Debug_Put_Line — see
   --  the deadlock note in the header)
   ------------------------------------------------------------------

   --  1. Display info: response type + an enabled scanout mode of
   --  sane size.
   Set_Hdr (Cmd_Get_Display_Info);
   if Ctrl_Cmd (24, Resp_Len => 24 + 16 * 24) /= Resp_Ok_Display_Info
   then
      Fail ("virtio-gpu display info failed");
   end if;

   --  pmodes[0]: rect at words 6..9, enabled at word 10.
   if Resp_Words (10) = 0
     or else Resp_Words (8) < Min_W
     or else Resp_Words (9) < Min_H
   then
      Fail ("virtio-gpu no enabled display mode");
   end if;

   Width := Natural'Min (Natural (Resp_Words (8)), Max_W);
   Height := Natural'Min (Natural (Resp_Words (9)), Max_H);
   Cols := Width / 8;
   Rows := Height / 16;
   Debug_Put_Line ("PASS virtio-gpu display info ok");

   --  2. 2D resource + backing + scanout.
   Set_Hdr (Cmd_Resource_Create_2D);
   Cmd_Words (6) := Resource_Id;
   Cmd_Words (7) := Format_B8G8R8A8;
   Cmd_Words (8) := Virtio.U32 (Width);
   Cmd_Words (9) := Virtio.U32 (Height);
   if Ctrl_Cmd (40) /= Resp_Ok_Nodata then
      Fail ("virtio-gpu create 2d failed");
   end if;

   --  Framebuffer: list of 64-page memory objects (kernel object
   --  page cap), mapped contiguously at FB_VA; ATTACH_BACKING
   --  entries are per page because object frames are not
   --  physically contiguous.
   FB_Pages := U64 (Width * Height * 4) / 4096;
   if FB_Pages > Max_Entries then
      Fail ("virtio-gpu framebuffer too large");
   end if;

   Obj_Pages := FB_Pages;
   while Obj_Pages > 0 loop
      declare
         This : constant U64 := U64'Min (Obj_Pages, 64);
         VA   : constant U64 :=
           FB_VA + U64 (FB_Obj_Count) * 64 * 4096;
      begin
         FB_Caps (FB_Obj_Count) := Mem_Alloc (This);
         if FB_Caps (FB_Obj_Count) = Syscall_Failed then
            Fail ("virtio-gpu fb alloc failed");
         end if;
         Result := Mem_Map
           (Address_Space => Address_Space_Cap,
            Cap           => FB_Caps (FB_Obj_Count),
            VA            => VA,
            Offset        => 0,
            Length        => This * 4096,
            Flags         => 3);
         if Result /= 0 then
            Fail ("virtio-gpu fb map failed");
         end if;
         Obj_Pages := Obj_Pages - This;
         FB_Obj_Count := FB_Obj_Count + 1;
      end;
   end loop;

   Ent_Count := 0;
   declare
      Remaining : U64 := FB_Pages;
      Obj       : Natural := 0;
      In_Obj    : U64;
   begin
      while Remaining > 0 loop
         In_Obj := U64'Min (Remaining, 64);
         for P in 0 .. In_Obj - 1 loop
            PA := Mem_Object_PA (FB_Caps (Obj), P);
            if PA = 0 then
               Fail ("virtio-gpu fb pa query failed");
            end if;
            Ent_Words (Natural (Ent_Count) * 4) :=
              Virtio.U32 (PA and 16#FFFF_FFFF#);
            Ent_Words (Natural (Ent_Count) * 4 + 1) :=
              Virtio.U32 (PA / 16#1_0000_0000#);
            Ent_Words (Natural (Ent_Count) * 4 + 2) := 4096;
            Ent_Words (Natural (Ent_Count) * 4 + 3) := 0;
            Ent_Count := Ent_Count + 1;
         end loop;
         Remaining := Remaining - In_Obj;
         Obj := Obj + 1;
      end loop;
   end;

   Set_Hdr (Cmd_Attach_Backing);
   Cmd_Words (6) := Resource_Id;
   Cmd_Words (7) := Virtio.U32 (Ent_Count);
   if Ctrl_Cmd (32, Extra_Len => Virtio.U32 (Ent_Count) * 16)
     /= Resp_Ok_Nodata
   then
      Fail ("virtio-gpu attach backing failed");
   end if;

   Set_Hdr (Cmd_Set_Scanout);
   Set_Rect (0, 0, Virtio.U32 (Width), Virtio.U32 (Height));
   Cmd_Words (10) := 0;  --  scanout_id
   Cmd_Words (11) := Resource_Id;
   if Ctrl_Cmd (48) /= Resp_Ok_Nodata then
      Fail ("virtio-gpu set scanout failed");
   end if;

   --  3. Color-bar pattern pushed to the screen, then cleared for
   --  console duty.
   Fill_Rect (0, 0, Width / 4, Height, 16#FFFF_0000#);
   Fill_Rect (Width / 4, 0, Width / 2, Height, 16#FF00_FF00#);
   Fill_Rect (Width / 2, 0, 3 * Width / 4, Height, 16#FF00_00FF#);
   Fill_Rect (3 * Width / 4, 0, Width, Height, 16#FFFF_FF00#);
   Flush_Dirty;
   Fill_Rect (0, 0, Width, Height, BG);
   Cur_Col := 0;
   Cur_Row := 0;
   Flush_Dirty;
   Debug_Put_Line ("PASS virtio-gpu display ok");

   ------------------------------------------------------------------
   --  Stream service: Op_Write renders text, everything else EOF
   ------------------------------------------------------------------

   Debug_Put_Line ("virtio-gpu console online");

   loop
      Status := RPC.Receive
        (Svc_EP, Label, Request, Badge, Caps, Reply_H);
      if Status /= IPC_Ok then
         Debug_Put_Line ("virtio-gpu recv failed");
         Process_Exit;
      end if;

      if Label = Notification_Label then
         ISR := Dev.Interrupt_Status;
         if ISR /= 0 then
            Dev.ACK_Interrupt (ISR);
         end if;

         Result := IRQ_Ack (IRQ_Cap);

      elsif Label = Akernel_User.Streams.Op_Write then
         for I in 1 .. Ada.Streams.Stream_Element_Offset
           (Request.Count)
         loop
            Put_Char (Character'Val (Natural (Request.Data (I))));
         end loop;
         Flush_Dirty;
         Response := (Count => Request.Count, Data => (others => 0));
         if RPC.Reply (Reply_H, Label, Response) /= IPC_Ok then
            Debug_Put_Line ("virtio-gpu reply failed");
            Process_Exit;
         end if;

      elsif Label = DSP.Op_Get_Info then
         Display_Reply (Reply_H, Label, DSP.Status_Ok);

      elsif Label = DSP.Op_Set_Buffer then
         declare
            Base : constant U64 := Message.Words (0);
            St   : U64 := DSP.Status_Ok;
            Idx  : U64;
         begin
            for I in 0 .. 3 loop
               exit when Caps (I) = 0;
               Idx := Base + U64 (I);
               if Idx >= U64 (FB_Objects)
                 or else New_Caps (Natural (Idx)) /= 0
               then
                  St := DSP.Status_Bad_Index;
                  Result := Cap_Delete (Caps (I));
               else
                  New_Caps (Natural (Idx)) := Caps (I);
                  New_Chunks := New_Chunks + 1;
               end if;
            end loop;
            Display_Reply (Reply_H, Label, St);
         end;

      elsif Label = DSP.Op_Commit_Buffer then
         Display_Reply (Reply_H, Label, Commit_Buffer);

      elsif Label = DSP.Op_Present then
         declare
            X : constant Natural :=
              Natural'Min (Natural (Message.Words (0)), Width);
            Y : constant Natural :=
              Natural'Min (Natural (Message.Words (1)), Height);
            W : constant Natural :=
              Natural'Min (Natural (Message.Words (2)), Width - X);
            H : constant Natural :=
              Natural'Min (Natural (Message.Words (3)), Height - Y);
         begin
            Present_Band (X, Y, W, H);
            Display_Reply (Reply_H, Label, DSP.Status_Ok);
         end;

      else
         --  Op_Read/Op_Input/unknown: no data.
         Response := (Count => 0, Data => (others => 0));
         if RPC.Reply (Reply_H, Label, Response) /= IPC_Ok then
            Debug_Put_Line ("virtio-gpu reply failed");
            Process_Exit;
         end if;
      end if;
   end loop;
end Virtio_Gpu;
