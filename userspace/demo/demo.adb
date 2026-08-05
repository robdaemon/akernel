with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Window;
with Akernel_User.Streams;

--  Demo: second Bureau client (milestone 30, slice b) — proves
--  multi-window, click-to-focus and per-window key routing.
--  Spawned from Sys:System/Demo via the Startup list with the
--  generic GUI grant ABI (3 handles): 1 = Bureau window service
--  (Send), 2 = input sink endpoint (Receive), 3 = input sink
--  (Send+Transfer, pushed to Bureau at Surface_Create).
--
--  Draws eight color bars; every focused key paints a small
--  block in the key strip at the bottom (colour = the character
--  code), so key routing is visible on screen. Display-stack
--  rule: Debug_Put_Line only, never console writes.

procedure Demo is
   use Akernel_User.Syscalls;
   use type U64;
   use type Interfaces.Unsigned_8;

   Win_EP    : constant U64 := 1;
   Sink_EP   : constant U64 := 2;
   Sink_Send : constant U64 := 3;

   Buf_VA : constant U64 := 16#6000_0000#;

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
   Label   : U64;

   Obj_Cap : U64;
   Minted  : U64;

   Key_X   : U64 := 4;
   Key_N   : U64 := 0;

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

begin
   if Win.Surface_Create
     (Win_EP, Req_W, Req_H, Sink_Send, Surf_Id, Pages,
      Surf_W, Surf_H) /= Win.Status_Ok
   then
      Fail ("surface create failed");
   end if;
   Result := Cap_Delete (Sink_Send);

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

   --  Input sink: focused keys arrive as stream Op_Input bytes.
   loop
      if IPC_Recv (Sink_EP) /= IPC_Ok then
         Debug_Put_Line ("demo recv failed");
         Process_Exit;
      end if;
      Label := Message.Label;
      if Label = Akernel_User.Streams.Op_Input then
         for I in 1 .. Message.Words (0) loop
            Key_Block (Message.Words (1) and 16#FF#);
         end loop;
         if Win.Surface_Update
           (Win_EP, Surf_Id, 0, Surf_H - 28, Surf_W, 28) /=
             Win.Status_Ok
         then
            Debug_Put_Line ("demo update failed");
         end if;
      end if;
      Message.Words := (others => 0);
      Message.Words (0) := 0;
      Message.Caps := (others => 0);
      if IPC_Reply /= IPC_Ok then
         Debug_Put_Line ("demo reply failed");
         Process_Exit;
      end if;
   end loop;
end Demo;
