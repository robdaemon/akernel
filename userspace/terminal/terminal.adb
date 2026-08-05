with Interfaces;
with System;
with System.Storage_Elements;
with Ada.Streams;
with Akernel_User.Syscalls;
with Akernel_User.IPC;
with Akernel_User.Streams;
with Akernel_User.Window;
with Font8x8;

--  Terminal: Bureau's first window-protocol client (milestone 28,
--  slice 3). Spawned by the device manager right after Bureau.
--  Grant ABI (3 handles): 1 = console endpoint (Send, badged),
--  2 = Bureau window-service endpoint (Send), 3 = stream sink
--  endpoint (Receive) — the console server mirrors its
--  line-atomic output here (devmgr attaches THIS endpoint via
--  Op_Attach_Sink, replacing the GPU driver's text console).
--
--  The terminal allocates its surface buffer (caps move caller ->
--  callee only), pushes chunk caps to Bureau, renders its text
--  grid into the surface (font8x8, 8x16 cells, dark on white —
--  the Startup-Sequence CLI look), and pushes damaged bands with
--  Op_Surface_Update. Scroll = memmove inside the surface + one
--  band update (no device copy exists in virtio-gpu 2D — see the
--  display-service correction in docs/NEXT.md). Input arrives in
--  slice 4 via the Bureau seat; Op_Read stays EOF.

procedure Terminal is
   use Akernel_User.Syscalls;
   use type U64;
   use type Interfaces.Unsigned_8;

   Console_EP : constant U64 := 1;
   Win_EP     : constant U64 := 2;
   Sink_EP    : constant U64 := 3;

   Buf_VA : constant U64 := 16#6000_0000#;

   Max_W : constant := 1024;
   Max_H : constant := 768;
   Max_Objects : constant := (Max_W * Max_H * 4) / 4096 / 64;

   Surf_Id : U64;
   Pages   : U64;
   Surf_W  : U64;
   Surf_H  : U64;
   Cols    : U64;
   Rows    : U64;

   Obj_Caps : array (0 .. Max_Objects - 1) of U64 := (others => 0);

   subtype Pixel is Interfaces.Unsigned_32;
   type Pixel_Array is
     array (U64 range 0 .. Max_W * Max_H - 1) of Pixel
     with Volatile_Components;
   Buf : Pixel_Array
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (Buf_VA));

   FG : constant Pixel := 16#FF20_2020#;  --  dark text
   BG : constant Pixel := 16#FFF8_F8F8#;  --  white pane

   Cur_Col : U64 := 0;
   Cur_Row : U64 := 0;
   Dirty_Y0 : U64 := U64'Last;
   Dirty_Y1 : U64 := 0;

   Result : U64;

   procedure Fail (S : String) is
   begin
      Debug_Put_Line ("FAIL terminal " & S);
      Process_Exit;
   end Fail;

   procedure Touch (Y0, Y1 : U64) is
   begin
      if Y0 < Dirty_Y0 then
         Dirty_Y0 := Y0;
      end if;
      if Y1 > Dirty_Y1 then
         Dirty_Y1 := Y1;
      end if;
   end Touch;

   --  font8x8: bit 0 is the LEFTMOST pixel (burned, milestone 27b).
   procedure Draw_Glyph (Col, Row : U64; Ch : Character) is
      GX   : constant U64 := Col * 8;
      GY   : constant U64 := Row * 16;
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
                 (GY + U64 (R) * 2 + U64 (Rep)) * Surf_W + GX;
            begin
               for B in 0 .. 7 loop
                  if (Interfaces.Shift_Right (Bits, B) and 1) = 1 then
                     Buf (Base + U64 (B)) := FG;
                  else
                     Buf (Base + U64 (B)) := BG;
                  end if;
               end loop;
            end;
         end loop;
      end loop;
      Touch (GY, GY + 16);
   end Draw_Glyph;

   procedure Scroll is
   begin
      for Y in 0 .. Surf_H - 17 loop
         for X in 0 .. Surf_W - 1 loop
            Buf (Y * Surf_W + X) := Buf ((Y + 16) * Surf_W + X);
         end loop;
      end loop;
      for Y in Surf_H - 16 .. Surf_H - 1 loop
         for X in 0 .. Surf_W - 1 loop
            Buf (Y * Surf_W + X) := BG;
         end loop;
      end loop;
      Touch (0, Surf_H);
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
   end Put_Char;

   --  Push the damaged surface band to Bureau.
   procedure Flush_Dirty is
      Y0 : U64;
      Y1 : U64;
   begin
      if Dirty_Y1 <= Dirty_Y0 then
         return;
      end if;
      Y0 := Dirty_Y0;
      Y1 := Dirty_Y1;
      Dirty_Y0 := U64'Last;
      Dirty_Y1 := 0;
      Result := Akernel_User.Window.Surface_Update
        (Win_EP, Surf_Id, 0, Y0, Surf_W, Y1 - Y0);
      if Result /= Akernel_User.Window.Status_Ok then
         Debug_Put_Line ("terminal update failed");
      end if;
   end Flush_Dirty;

   ------------------------------------------------------------------

   package RPC is new Akernel_User.IPC
     (Akernel_User.Streams.Stream_Request,
      Akernel_User.Streams.Stream_Response);
   package Win renames Akernel_User.Window;

   Status   : U64;
   Label    : U64;
   Badge    : U64;
   Request  : Akernel_User.Streams.Stream_Request;
   Response : Akernel_User.Streams.Stream_Response;
   Caps     : RPC.Cap_Array;

   Pages_Left : U64;
   This       : U64;
   Count      : Natural;
   Minted     : U64;

begin
   --  1. Surface: ask for the whole pane, Bureau clamps.
   if Win.Surface_Create
     (Win_EP, Max_W, Max_H, Surf_Id, Pages, Surf_W, Surf_H) /=
       Win.Status_Ok
   then
      Fail ("surface create failed");
   end if;
   Cols := Surf_W / 8;
   Rows := Surf_H / 16;

   --  2. Surface buffer chunks, pushed to Bureau (4 caps/call).
   Pages_Left := Pages;
   Count := 0;
   while Pages_Left > 0 loop
      This := U64'Min (Pages_Left, 64);
      Obj_Caps (Count) := Mem_Alloc (This);
      if Obj_Caps (Count) = Syscall_Failed then
         Fail ("surface alloc failed");
      end if;
      Result := Mem_Map
        (Address_Space => Address_Space_Cap,
         Cap           => Obj_Caps (Count),
         VA            => Buf_VA + U64 (Count) * 64 * 4096,
         Offset        => 0,
         Length        => This * 4096,
         Flags         => 3);
      if Result /= 0 then
         Fail ("surface map failed");
      end if;
      Pages_Left := Pages_Left - This;
      Count := Count + 1;
   end loop;

   declare
      Objects : constant U64 := (Pages + 63) / 64;
      Base    : U64 := 0;
      Send    : array (0 .. 3) of U64;
      St      : U64;
   begin
      while Base < Objects loop
         Send := (others => 0);
         for I in 0 .. 3 loop
            exit when Base + U64 (I) >= Objects;
            Minted := Cap_Mint
              (Obj_Caps (Natural (Base + U64 (I))),
               Right_Map + Right_Read + Right_Transfer, 0);
            if Minted = Syscall_Failed then
               Fail ("surface mint failed");
            end if;
            Send (I) := Minted;
         end loop;
         St := Win.Surface_Set_Buffer
           (Win_EP, Surf_Id, Base, Send (0), Send (1), Send (2),
            Send (3));
         for I in 0 .. 3 loop
            if Send (I) /= 0 then
               Result := Cap_Delete (Send (I));
            end if;
         end loop;
         if St /= Win.Status_Ok then
            Fail ("surface set buffer rejected");
         end if;
         Base := Base + 4;
      end loop;
   end;

   if Win.Surface_Commit_Buffer (Win_EP, Surf_Id) /= Win.Status_Ok then
      Fail ("surface commit failed");
   end if;
   Debug_Put_Line ("PASS terminal surface ok");

   --  3. Clear the pane and show it.
   for I in 0 .. Surf_W * Surf_H - 1 loop
      Buf (I) := BG;
   end loop;
   Touch (0, Surf_H);
   Flush_Dirty;
   Debug_Put_Line ("terminal online");

   --  4. Stream sink service: Op_Write renders text.
   loop
      Status := RPC.Receive (Sink_EP, Label, Request, Badge, Caps);
      if Status /= IPC_Ok then
         Debug_Put_Line ("terminal recv failed");
         Process_Exit;
      end if;

      if Label = Akernel_User.Streams.Op_Write then
         for I in 1 .. Ada.Streams.Stream_Element_Offset
           (Request.Count)
         loop
            Put_Char (Character'Val (Natural (Request.Data (I))));
         end loop;
         Flush_Dirty;
         Response := (Count => Request.Count, Data => (others => 0));
         if RPC.Reply (Label, Response) /= IPC_Ok then
            Debug_Put_Line ("terminal reply failed");
            Process_Exit;
         end if;
      elsif Label = Akernel_User.Streams.Op_Input then
         --  Seat input (Bureau forwards focused keys as Op_Input
         --  bytes): inject into the console server's input FIFO,
         --  same channel the UART RX and (pre-seat) keyboard
         --  driver feed. A future shell reads it via Op_Read.
         declare
            Fwd   : Akernel_User.Streams.Stream_Request;
            Fresp : Akernel_User.Streams.Stream_Response;
            Rlbl  : U64;
         begin
            Fwd.Count := Request.Count;
            Fwd.Data := Request.Data;
            if RPC.Call (Console_EP, Akernel_User.Streams.Op_Input,
                         Fwd, RPC.No_Caps, Rlbl, Fresp) /= IPC_Ok
            then
               Debug_Put_Line ("terminal console input failed");
            end if;
         end;
         Response := (Count => Request.Count, Data => (others => 0));
         if RPC.Reply (Label, Response) /= IPC_Ok then
            Debug_Put_Line ("terminal reply failed");
            Process_Exit;
         end if;
      else
         --  Op_Read/Op_Input/unknown: no data.
         Response := (Count => 0, Data => (others => 0));
         if RPC.Reply (Label, Response) /= IPC_Ok then
            Debug_Put_Line ("terminal reply failed");
            Process_Exit;
         end if;
      end if;
   end loop;
end Terminal;
