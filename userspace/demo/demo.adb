with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Window;

--  Demo: second Bureau client (milestone 30, slice b) — proves
--  multi-window, click-to-focus and per-window key routing.
--  Spawned from Sys:System/Demo via the Startup list under the
--  UNIFORM program ABI (milestone 31b): 1 = console endpoint
--  (Send, badged; unused), 2 = file server (Send; unused), 3 =
--  Bureau window service (Send). The receive endpoint for the
--  input-notification multiplex is runtime-created (EP_Create).
--
--  Draws eight color bars; every focused key paints a small
--  block in the key strip at the bottom (colour = the character
--  code), so key routing is visible on screen. Keys arrive on
--  the v3 async channel (queue page + notification pushed at
--  Surface_Create; Bureau never calls the client). The strip
--  update flushes AFTER draining, outside any rendezvous with
--  Bureau. Display-stack rule: Debug_Put_Line only, never
--  console writes.

procedure Demo is
   use Akernel_User.Syscalls;
   use type U64;
   use type Interfaces.Unsigned_8;

   Win_EP    : constant U64 := 3;
   --  Runtime-created receive endpoint: the input notification
   --  is thread-bound, so the synthetic message arrives on any
   --  IPC_Recv of this thread — this EP exists only to receive
   --  on (nobody sends to it).
   Sink_EP   : U64 := 0;

   Buf_VA : constant U64 := 16#6000_0000#;
   Queue_VA : constant U64 := 16#5080_0000#;

   Req_W : constant U64 := 320;
   Req_H : constant U64 := 200;

   subtype Pixel is Interfaces.Unsigned_32;
   type Pixel_Array is
     array (U64 range 0 .. Req_W * Req_H - 1) of Pixel
     with Volatile_Components;
   Buf : Pixel_Array
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (Buf_VA));

   --  Eight bar colours (AARRGGBB; low byte is blue).
   Bar_Colors : constant array (0 .. 7) of Pixel :=
     (16#FFFF_2020#, 16#FFFF_8800#, 16#FFFF_D800#, 16#FF30_C030#,
      16#FF30_80D0#, 16#FF60_68B0#, 16#FFA0_40C0#, 16#FFF0_F0F0#);
   Strip_BG : constant Pixel := 16#FF18_1818#;

   package Win renames Akernel_User.Window;

   Surf_Id : U64;
   Pages   : U64;
   Surf_W  : U64;
   Surf_H  : U64;
   Result  : U64;
   Reply_H : U64;
   Label   : U64;

   Obj_Cap : U64;
   Minted  : U64;

   Key_X   : U64 := 4;
   Key_N   : U64 := 0;
   Strip_Dirty : Boolean := False;
   Ptr_X       : U64 := 0;
   Ptr_Y       : U64 := 0;
   Ptr_Drawn   : Boolean := False;
   Ptr_Dirty   : Boolean := False;
   Ptr_Dirty_X0 : U64 := 0;
   Ptr_Dirty_Y0 : U64 := 0;
   Ptr_Dirty_X1 : U64 := 0;
   Ptr_Dirty_Y1 : U64 := 0;

   Queue_Cap : U64 := 0;
   Ntfn_Cap  : U64 := 0;

   type Word_Array is array (U64 range 0 .. 511) of U64
     with Volatile_Components;
   Queue : Word_Array
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (Queue_VA));

   procedure Fail (S : String) is
   begin
      Debug_Put_Line ("FAIL demo " & S);
      Process_Exit;
   end Fail;

   procedure Draw_Bars is
      BW : constant U64 := Surf_W / 8;
      BH : constant U64 := Surf_H - 28;
   begin
      for Y in 0 .. Surf_H - 1 loop
         for X in 0 .. Surf_W - 1 loop
            if Y >= BH then
               Buf (Y * Surf_W + X) := Strip_BG;
            else
               Buf (Y * Surf_W + X) :=
                 Bar_Colors (Natural (X / BW));
            end if;
         end loop;
      end loop;
   end Draw_Bars;

   procedure Key_Block (Ch : U64) is
      BH : constant U64 := Surf_H - 28;
      C  : constant Pixel :=
        Bar_Colors (Natural (Ch mod 8));
   begin
      for Y in BH + 6 .. BH + 21 loop
         for X in Key_X .. Key_X + 15 loop
            if X < Surf_W then
               Buf (Y * Surf_W + X) := C;
            end if;
         end loop;
      end loop;
      Key_X := Key_X + 18;
      if Key_X + 16 >= Surf_W then
         Key_X := 4;
      end if;
      Key_N := Key_N + 1;
   end Key_Block;

   --  Pointer marker (v3 pointer events): a 5x5 block tracking
   --  the pointer inside the bar area — white while button0 is
   --  pressed, black otherwise. The old block is restored to the
   --  bar colours underneath.
   procedure Pointer_Block (X, Y, Buttons : U64) is
      BH : constant U64 := Surf_H - 28;
      C  : constant Pixel :=
        (if (Buttons and 1) = 1 then 16#FFFF_FFFF#
         else 16#FF00_0000#);
      BW : constant U64 := Surf_W / 8;
   begin
      if X + 4 >= Surf_W or else Y + 4 >= BH then
         return;
      end if;
      if Ptr_Drawn then
         for R in U64'(0) .. 4 loop
            for Q in U64'(0) .. 4 loop
               Buf ((Ptr_Y + R) * Surf_W + Ptr_X + Q) :=
                 Bar_Colors (Natural ((Ptr_X + Q) / BW));
            end loop;
         end loop;
      end if;
      Ptr_Dirty_X0 := U64'Min ((if Ptr_Drawn then Ptr_X else X), X);
      Ptr_Dirty_Y0 := U64'Min ((if Ptr_Drawn then Ptr_Y else Y), Y);
      Ptr_Dirty_X1 := U64'Max
        ((if Ptr_Drawn then Ptr_X else X), X) + 5;
      Ptr_Dirty_Y1 := U64'Max
        ((if Ptr_Drawn then Ptr_Y else Y), Y) + 5;
      for R in U64'(0) .. 4 loop
         for Q in U64'(0) .. 4 loop
            Buf ((Y + R) * Surf_W + X + Q) := C;
         end loop;
      end loop;
      Ptr_X := X;
      Ptr_Y := Y;
      Ptr_Drawn := True;
      Ptr_Dirty := True;
   end Pointer_Block;

begin
   --  v3 input channel: one-page event queue + thread-bound
   --  notification, pushed at Surface_Create.
   Queue_Cap := Mem_Alloc (1);
   if Queue_Cap = Syscall_Failed then
      Fail ("queue alloc failed");
   end if;
   Sink_EP := EP_Create;
   if Sink_EP = Syscall_Failed then
      Fail ("recv ep create failed");
   end if;
   Result := Mem_Map
     (Address_Space => Address_Space_Cap,
      Cap           => Queue_Cap,
      VA            => Queue_VA,
      Offset        => 0,
      Length        => 4096,
      Flags         => 3);
   if Result /= 0 then
      Fail ("queue map failed");
   end if;
   Queue (Win.Input_Queue_Head) := 0;
   Queue (Win.Input_Queue_Tail) := 0;
   Ntfn_Cap := Ntfn_Create;
   if Ntfn_Cap = Syscall_Failed
     or else Ntfn_Bind_Thread (Ntfn_Cap) /= 0
   then
      Fail ("ntfn setup failed");
   end if;

   declare
      Q_Mint : constant U64 := Cap_Mint
        (Queue_Cap, Right_Map + Right_Read + Right_Write +
         Right_Transfer, 0);
      N_Mint : constant U64 := Cap_Mint
        (Ntfn_Cap, Right_Write + Right_Transfer, 0);
   begin
      if Q_Mint = Syscall_Failed or else N_Mint = Syscall_Failed then
         Fail ("input mint failed");
      end if;
      if Win.Surface_Create
        (Win_EP, Req_W, Req_H, Q_Mint, N_Mint, Surf_Id, Pages,
         Surf_W, Surf_H) /= Win.Status_Ok
      then
         Fail ("surface create failed");
      end if;
      Result := Cap_Delete (Q_Mint);
      Result := Cap_Delete (N_Mint);
   end;

   --  Single chunk suffices at this size (<= 64 pages).
   if Pages > 64 then
      Fail ("surface too large");
   end if;
   Obj_Cap := Mem_Alloc (Pages);
   if Obj_Cap = Syscall_Failed then
      Fail ("surface alloc failed");
   end if;
   Result := Mem_Map
     (Address_Space => Address_Space_Cap,
      Cap           => Obj_Cap,
      VA            => Buf_VA,
      Offset        => 0,
      Length        => Pages * 4096,
      Flags         => 3);
   if Result /= 0 then
      Fail ("surface map failed");
   end if;
   Minted := Cap_Mint (Obj_Cap, Right_Map + Right_Read +
                         Right_Transfer, 0);
   if Minted = Syscall_Failed then
      Fail ("surface mint failed");
   end if;
   if Win.Surface_Set_Buffer
     (Win_EP, Surf_Id, 0, Minted) /= Win.Status_Ok
   then
      Fail ("surface set buffer rejected");
   end if;
   Result := Cap_Delete (Minted);
   if Win.Surface_Commit_Buffer (Win_EP, Surf_Id) /= Win.Status_Ok
   then
      Fail ("surface commit failed");
   end if;
   if Win.Surface_Set_Title
     (Win_EP, Surf_Id, "System/Demo") /= Win.Status_Ok
   then
      Fail ("title failed");
   end if;

   Draw_Bars;
   if Win.Surface_Update
     (Win_EP, Surf_Id, 0, 0, Surf_W, Surf_H) /= Win.Status_Ok
   then
      Fail ("update failed");
   end if;
   Debug_Put_Line ("demo online");

   --  Service loop: v3 input signals arrive as synthetic
   --  notification messages on the sink endpoint receive
   --  (thread-bound ntfn multiplex, rng-style — NO reply cap
   --  rides them). The strip update flushes after draining,
   --  never inside a rendezvous with Bureau.
   loop
      if Strip_Dirty then
         Strip_Dirty := False;
         if Win.Surface_Update
           (Win_EP, Surf_Id, 0, Surf_H - 28, Surf_W, 28) /=
             Win.Status_Ok
         then
            Debug_Put_Line ("demo update failed");
         end if;
      end if;
      if Ptr_Dirty then
         Ptr_Dirty := False;
         if Win.Surface_Update
           (Win_EP, Surf_Id, Ptr_Dirty_X0, Ptr_Dirty_Y0,
            Ptr_Dirty_X1 - Ptr_Dirty_X0, Ptr_Dirty_Y1 - Ptr_Dirty_Y0) /=
             Win.Status_Ok
         then
            Debug_Put_Line ("demo update failed");
         end if;
      end if;
      if IPC_Recv (Sink_EP, Reply_H) /= IPC_Ok then
         Debug_Put_Line ("demo recv failed");
         Process_Exit;
      end if;
      Label := Message.Label;
      if Label = Notification_Label then
         --  Drain v3 input-queue key events.
         declare
            Head : constant U64 := Queue (Win.Input_Queue_Head);
            Tail : U64 := Queue (Win.Input_Queue_Tail);
            Slot : U64;
         begin
            while Tail < Head loop
               Slot := Win.Input_Queue_First
                 + (Tail mod Win.Input_Queue_Events) * 2;
               if Queue (Slot) = Win.Input_Event_Key then
                  Key_Block (Queue (Slot + 1) and 16#FF#);
                  Strip_Dirty := True;
               elsif Queue (Slot) = Win.Input_Event_Pointer then
                  Pointer_Block
                    (Win.Pointer_X (Queue (Slot + 1)),
                     Win.Pointer_Y (Queue (Slot + 1)),
                     Win.Pointer_Buttons (Queue (Slot + 1)));
               elsif Queue (Slot) = Win.Input_Event_Close then
                  --  Close gadget: CLOSEWINDOW analog — destroy
                  --  the surface and leave.
                  Result := Win.Surface_Destroy (Win_EP, Surf_Id);
                  Process_Exit;
               end if;
               Tail := Tail + 1;
            end loop;
            Queue (Win.Input_Queue_Tail) := Tail;
         end;
      else
         Message.Words := (others => 0);
         Message.Words (0) := 0;
         Message.Caps := (others => 0);
         if IPC_Reply (Reply_H) /= IPC_Ok then
            Debug_Put_Line ("demo reply failed");
            Process_Exit;
         end if;
      end if;
   end loop;
end Demo;
