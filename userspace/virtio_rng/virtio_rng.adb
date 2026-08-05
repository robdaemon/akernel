with System;
with System.Storage_Elements;
with Interfaces;
with Akernel_User.Console;
with Akernel_User.Syscalls;
with Virtio;
with Virtio.PCI;
with Virtio.Queues;

--  Virtio RNG driver over the PCI transport (virtio-rng-pci,
--  transitional id 1af4:1004 or modern 1044). Spawned by init's
--  device manager when the PCI bus scan matches a System/Drivers
--  pci line of class 4. Fixed 7-handle PCI driver ABI (grant
--  order): 1 = console endpoint (Send), 2 = common-cfg MMIO cap,
--  3 = notify MMIO cap, 4 = ISR MMIO cap, 5 = device-cfg MMIO cap
--  (unused), 6 = IRQ cap (unused; completion is polled and the ISR
--  register read afterwards clears INTx), 7 = service endpoint.
--  The first service-endpoint message is the devmgr's driver
--  config (notify_off_multiplier in word 0), answered with a
--  status-0 reply. Requests the default 16 bytes of entropy at
--  boot and proves the full pipeline (ECAM -> BARs -> spawn ->
--  DMA -> doorbell -> completion), then stays resident as the
--  future entropy server.

procedure Virtio_RNG is
   use Akernel_User.Syscalls;
   use type U64;
   use type Virtio.U16;
   use type Virtio.U32;

   subtype U8 is Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_8;

   Console_EP : constant U64 := 1;
   Common_Cap : constant U64 := 2;
   Notify_Cap : constant U64 := 3;
   ISR_Cap    : constant U64 := 4;
   IRQ_Cap    : constant U64 := 6;
   Svc_EP     : constant U64 := 7;

   Common_VA : constant U64 := 16#5000_0000#;
   Notify_VA : constant U64 := 16#5000_1000#;
   ISR_VA    : constant U64 := 16#5000_2000#;
   DMA_VA    : constant U64 := 16#5004_0000#;
   --  DMA object layout: page 0 descriptors, page 1 avail ring,
   --  page 2 used ring, page 3 entropy buffer.
   DMA_Pages : constant U64 := 4;

   Entropy_Len : constant Virtio.U32 := 16;

   --  First service-endpoint message from the device manager.
   Driver_Config_Label : constant U64 := U64'Last - 1;

   ------------------------------------------------------------------
   --  Region register access (width-exact overlays per region)
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

   --  notify_off_multiplier from the devmgr config message.
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

   type Byte_Array is array (Natural range 0 .. 4095) of U8
     with Volatile_Components;

   Data_Page : Byte_Array
     with Address => To_Addr (DMA_VA + 3 * 4096);

   Hex : constant String := "0123456789abcdef";

   Result   : U64;
   DMA_Cap  : U64;
   Desc_PA  : U64;
   Avail_PA : U64;
   Used_PA  : U64;
   Data_PA  : U64;
   Q        : Virtio.Queues.Queue;
   D        : Virtio.U16;
   Head     : Virtio.U16;
   Written  : Virtio.U32;
   ISR_Bits : Virtio.U32;
   ISR      : Virtio.U32;
   Ntfn_Cap : U64;
   Spins    : Natural;
   All_Zero : Boolean;
   Line     : String (1 .. 34);

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
         Debug_Put_Line ("virtio-rng map " & Name & " failed");
         Process_Exit;
      end if;
   end Map_Region;

begin
   Akernel_User.Console.Set_Endpoint (Console_EP);

   Map_Region (Common_Cap, Common_VA, "common");
   Map_Region (Notify_Cap, Notify_VA, "notify");
   Map_Region (ISR_Cap,    ISR_VA,    "isr");

   --  Devmgr driver config message (notify multiplier, IRQ source,
   --  PCI device id); answered with status 0.
   Result := IPC_Recv (Svc_EP);
   if Result /= IPC_Ok or else Message.Label /= Driver_Config_Label then
      Debug_Put_Line ("virtio-rng config message missing");
      Process_Exit;
   end if;
   Notify_Mult := Message.Words (0);
   Message.Words := (others => 0);
   if IPC_Reply /= IPC_Ok then
      Debug_Put_Line ("virtio-rng config reply failed");
      Process_Exit;
   end if;

   if Dev.Num_Queues = 0 then
      Debug_Put_Line ("virtio-rng no queues");
      Process_Exit;
   end if;

   Dev.Reset;
   Dev.Set_Status (Virtio.Status_Acknowledge);
   Dev.Add_Status (Virtio.Status_Driver);
   Dev.Set_Driver_Features (0);
   Dev.Add_Status (Virtio.Status_Features_Ok);

   if (Dev.Status and Virtio.Status_Features_Ok) = 0 then
      Debug_Put_Line ("virtio-rng features rejected");
      Process_Exit;
   end if;

   --  DMA memory: one 4-page object, mapped locally, PAs queried
   --  per page for the device-side addresses.
   DMA_Cap := Mem_Alloc (DMA_Pages);
   if DMA_Cap = Syscall_Failed then
      Debug_Put_Line ("virtio-rng dma alloc failed");
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
      Debug_Put_Line ("virtio-rng dma map failed");
      Process_Exit;
   end if;

   Desc_PA  := Mem_Object_PA (DMA_Cap, 0);
   Avail_PA := Mem_Object_PA (DMA_Cap, 1);
   Used_PA  := Mem_Object_PA (DMA_Cap, 2);
   Data_PA  := Mem_Object_PA (DMA_Cap, 3);
   if Desc_PA = 0 or else Avail_PA = 0
     or else Used_PA = 0 or else Data_PA = 0
   then
      Debug_Put_Line ("virtio-rng dma pa query failed");
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

   --  IRQ binding: the line signals a thread-bound notification;
   --  IPC_Recv wakes with a synthetic Notification_Label message,
   --  the resident loop drains + acks. Required on shared INTx
   --  sources: an unacked line holds the PLIC claim open and
   --  blocks every partner on the source.
   Ntfn_Cap := Ntfn_Create;
   if Ntfn_Cap = Syscall_Failed
     or else Ntfn_Bind_Thread (Ntfn_Cap) /= 0
     or else IRQ_Bind_Ntfn (IRQ_Cap, Ntfn_Cap, 1) /= 0
   then
      Debug_Put_Line ("virtio-rng ntfn setup failed");
      Process_Exit;
   end if;

   --  One entropy request: a single device-writable descriptor
   --  covering 16 bytes of the data page.
   D := Virtio.Queues.Alloc (Q);
   Virtio.Queues.Set_Buffer
     (Q, D, Data_PA, Entropy_Len, Device_Writes => True);
   Virtio.Queues.Submit (Q, D);
   Dev.Notify (0);

   Spins := 0;
   while not Virtio.Queues.Has_Completed (Q) loop
      Spins := Spins + 1;
      if Spins > 10_000 then
         Debug_Put_Line ("virtio-rng completion timeout");
         Process_Exit;
      end if;
      Yield;
   end loop;

   Virtio.Queues.Pop (Q, Head, Written);

   --  Drain + ack the completion interrupt (ISR captured first,
   --  the self-test below asserts on it). The ack completes the
   --  PLIC claim; without it the claimed-but-uncompleted source
   --  would never deliver again — fatal now that PCI INTx sources
   --  are SHARED (source 35 also serves the GPU at dev 7).
   ISR_Bits := Dev.Interrupt_Status;
   if ISR_Bits /= 0 then
      Dev.ACK_Interrupt (ISR_Bits);
   end if;

   Result := IRQ_Ack (IRQ_Cap);

   All_Zero := True;
   for I in 0 .. Natural (Entropy_Len) - 1 loop
      if Data_Page (I) /= 0 then
         All_Zero := False;
         exit;
      end if;
   end loop;

   if Written = Entropy_Len and then not All_Zero and then ISR_Bits /= 0 then
      Akernel_User.Console.Put_Line ("PASS virtio-rng entropy ok");
   else
      Akernel_User.Console.Put_Line ("FAIL virtio-rng entropy bad data");
   end if;

   Line (1 .. 2) := "  ";
   for I in 0 .. Natural (Entropy_Len) - 1 loop
      Line (3 + I * 2) :=
        Hex (1 + Natural (Data_Page (I) / 16));
      Line (4 + I * 2) :=
        Hex (1 + Natural (Data_Page (I) mod 16));
   end loop;
   Akernel_User.Console.Put_Line ("virtio-rng entropy: " & Line);

   Virtio.Queues.Free (Q, D);

   --  Resident as the future entropy server. The Recv loop
   --  doubles as the IRQ drain: a shared INTx source pokes every
   --  registered line, so stray notifications arrive whenever a
   --  line partner (GPU) raises interrupts. No reply cap rides a
   --  synthetic notification message.
   loop
      Result := IPC_Recv (Svc_EP);
      if Result /= IPC_Ok then
         Debug_Put_Line ("virtio-rng recv failed");
         Process_Exit;
      end if;

      if Message.Label = Notification_Label then
         ISR := Dev.Interrupt_Status;
         if ISR /= 0 then
            Dev.ACK_Interrupt (ISR);
         end if;

         Result := IRQ_Ack (IRQ_Cap);
      else
         --  No service yet: unknown op status, like blk's 3.
         Message.Words (0) := 3;
         Message.Words (1) := 0;
         if IPC_Reply /= IPC_Ok then
            Debug_Put_Line ("virtio-rng reply failed");
            Process_Exit;
         end if;
      end if;
   end loop;
end Virtio_RNG;
