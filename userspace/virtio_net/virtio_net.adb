with System;
with System.Storage_Elements;
with System.Machine_Code;
with Interfaces;
with Akernel_User.Console;
with Akernel_User.Syscalls;
with Virtio;
with Virtio.PCI;
with Virtio.Queues;

--  Virtio network driver over the PCI transport (virtio-net-pci,
--  transitional id 1af4:1000 or modern 1040). Spawned by init's
--  device manager when the PCI bus scan matches a System/Drivers
--  pci line of class 1. Fixed 7-handle PCI driver ABI (grant
--  order): 1 = console endpoint (Send), 2 = common-cfg MMIO cap,
--  3 = notify MMIO cap, 4 = ISR MMIO cap, 5 = device-cfg MMIO cap,
--  6 = IRQ cap, 7 = frame service endpoint (Receive). The first
--  message on the service endpoint is the devmgr's driver config
--  (notify_off_multiplier in word 0, IRQ source in word 1, PCI
--  device id in word 2, MSI-X offer in word 3), answered with a
--  status-0 reply.
--
--  No feature negotiation beyond VIRTIO_NET_F_MAC: the driver
--  feature word 0 carries nothing above bit 31, so a transitional
--  device runs in legacy mode and every packet carries the 10-byte
--  legacy virtio_net_hdr (no checksum offloads, no GSO, no
--  mergeable rx buffers — one descriptor per packet).
--
--  Two split queues: RX = 0, TX = 1, Num = 16 each. RX buffers are
--  pre-posted 2048-byte slots (descriptor id == slot index, repost
--  on Pop, the virtio_input eventq model); received frames are
--  published into a ring shared with System/Netserv (registered
--  once via Op_Set_Rx) which is then signalled on bit 0.
--
--  Frame service protocol on handle 7 (replies carry (status, ...)
--  with status 0 = ok, 3 = bad arguments):
--    Op 0 info:    -> (status, mac bytes 0..3, mac bytes 4..5, mtu)
--    Op 1 tx:      word0 = frame length (<= 1514), frame memory
--                  object cap in slot 0 (first page DMA'd directly
--                  as the second descriptor of the chain, our
--                  10-byte header staging page is the first)
--    Op 2 set-rx:  cap0 = RX ring memory object (mapped here for
--                  the driver's lifetime), cap1 = netserv
--                  notification cap (Signal right), word0 = ring
--                  bytes. Single registration; a second call is
--                  bad arguments.
--
--  RX ring layout inside the registered object: word 0 = head
--  (driver-written), word 1 = tail (consumer-written), word 2 =
--  dropped-frame counter, word 3 = slot count; slots of 2048 bytes
--  start at offset 4096, each slot = u16 length then frame bytes.
--
--  Boot self-test: transmit a crafted ARP request for the slirp
--  gateway 10.0.2.2 (static guest 10.0.2.15) and wait for the
--  reply — proves MAC config, TX, RX and IRQ delivery end-to-end
--  before the service loop starts.

procedure Virtio_Net is
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
   IRQ_Cap    : U64 := 6;
   Svc_EP     : constant U64 := 7;

   Common_VA : constant U64 := 16#5000_0000#;
   Notify_VA : constant U64 := 16#5000_1000#;
   ISR_VA    : constant U64 := 16#5000_2000#;
   Cfg_VA    : constant U64 := 16#5000_3000#;
   --  DMA object layout: pages 0..2 RX rings (desc/avail/used),
   --  pages 3..5 TX rings, pages 6..13 RX slots (16 x 2048 B),
   --  page 14 TX staging (10-byte legacy header at offset 0,
   --  self-test frame at offset 16).
   DMA_VA    : constant U64 := 16#5004_0000#;
   DMA_Pages : constant U64 := 15;
   --  Persistent map of the netserv RX ring object (16-page
   --  window; the protocol caps the ring at that size).
   Ring_VA     : constant U64 := 16#5005_0000#;
   Ring_Window : constant U64 := 16#10000#;

   Queue_Num : constant Virtio.U16 := 16;

   Rx_Slot_Size : constant := 2048;
   Rx_Slots     : constant := 16;
   Rx_Slot_Pages : constant := Rx_Slots * Rx_Slot_Size / 4096;  --  8

   --  Legacy virtio_net_hdr.  Guaranteed by the negotiation in
   --  the driver entry: only feature word 0 is ever offered, so a
   --  spec-compliant device runs the legacy datapath (the boot
   --  line there says so explicitly); a modern-only device would
   --  have rejected FEATURES_OK.
   Hdr_Len : constant := 10;
   MTU     : constant := 1500;

   --  VIRTIO_NET_F_MAC (feature bit 5) fits the word-0 feature
   --  negotiation Virtio.PCI supports.
   Feat_MAC : constant Virtio.U32 := 2 ** 5;

   --  VIRTIO_F_VERSION_1: hi-word bit 0, read for the boot-time
   --  datapath diagnostic only (never negotiated).
   Feat_Version_1 : constant Virtio.U32 := 2 ** 0;

   --  Frame service protocol labels (shared with System/Netserv).
   Op_Info  : constant U64 := 0;
   Op_Tx    : constant U64 := 1;
   Op_Set_Rx : constant U64 := 2;

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
   Cfg8     : U8_File  with Address => To_Addr (Cfg_VA);

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

   --  notify_off_multiplier from the devmgr config message; raw
   --  queue_notify_off values are scaled by it.
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
   --  DMA object overlays
   ------------------------------------------------------------------

   --  RX slots: byte view of pages 6..13.
   type Byte_Array is
     array (U64 range 0 .. Rx_Slot_Pages * 4096 - 1) of U8
     with Volatile_Components;

   Rx_Slot_Mem : Byte_Array
     with Address => To_Addr (DMA_VA + 6 * 4096);

   --  TX staging page: legacy header at 0..9, self-test frame
   --  staging at 16.. .
   type Page_Array is array (U64 range 0 .. 4095) of U8
     with Volatile_Components;

   Tx_Staging : Page_Array
     with Address => To_Addr (DMA_VA + 14 * 4096);

   ------------------------------------------------------------------
   --  RX ring overlays (netserv-shared object at Ring_VA)
   ------------------------------------------------------------------

   type Ring_Words is array (U64 range 0 .. 7) of U64
     with Volatile_Components;

   Ring_Hdr : Ring_Words with Address => To_Addr (Ring_VA);

   type Ring_Slot_Mem is array (U64 range 0 .. Ring_Window - 4097) of U8
     with Volatile_Components;

   Ring_Data : Ring_Slot_Mem with Address => To_Addr (Ring_VA + 4096);

   ------------------------------------------------------------------

   Result   : U64;
   Reply_H  : U64;  --  reply cap of the request being served (m47)
   DMA_Cap  : U64;
   Ntfn_Cap : U64;
   Bits     : U64;
   ISR      : Virtio.U32;
   Rx_Q     : Virtio.Queues.Queue;
   Tx_Q     : Virtio.Queues.Queue;
   Tx_Busy  : Boolean := False;

   Rx_Ring_PA : array (0 .. 2) of U64 := (others => 0);
   Tx_Ring_PA : array (0 .. 2) of U64 := (others => 0);
   Rx_Page_PA : array (0 .. Rx_Slot_Pages - 1) of U64 := (others => 0);
   Tx_Page_PA : U64 := 0;

   Our_Mac : array (0 .. 5) of U8 := (others => 0);

   --  RX ring registration state (single consumer, netserv).
   Ring_Live : Boolean := False;
   Ring_Cap  : U64 := 0;
   Ring_Ntfn : U64 := 0;
   Ring_Slot_Count : U64 := 0;

   function Rx_Slot_PA (Slot : Natural) return U64 is
     (Rx_Page_PA (Slot / 2) + U64 (Slot mod 2) * 2048);

   procedure Fail (S : String) is
   begin
      Akernel_User.Console.Put_Line ("FAIL " & S);
      Process_Exit;
   end Fail;

   --  Map one region cap at VA, one page.
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
         Debug_Put_Line ("virtio-net map " & Name & " failed");
         Process_Exit;
      end if;
   end Map_Region;

   --  Publish one received frame (already stripped of the virtio
   --  header) into the netserv ring; drop-new with a counter when
   --  the ring is full or absent.
   procedure Publish (Slot : Natural; Frame_Len : Natural) is
      Dst : U64;
   begin
      if not Ring_Live then
         return;
      end if;

      if Ring_Hdr (0) - Ring_Hdr (1) >= Ring_Slot_Count then
         Ring_Hdr (2) := Ring_Hdr (2) + 1;
         return;
      end if;

      Dst := (Ring_Hdr (0) mod Ring_Slot_Count) * 2048;
      Ring_Data (Dst) := U8 (Frame_Len mod 256);
      Ring_Data (Dst + 1) := U8 (Frame_Len / 256);
      for J in 0 .. Frame_Len - 1 loop
         Ring_Data (Dst + 2 + U64 (J)) :=
           Rx_Slot_Mem (U64 (Slot) * 2048 + Hdr_Len + U64 (J));
      end loop;
      Ring_Hdr (0) := Ring_Hdr (0) + 1;
   end Publish;

   --  Drain completed RX descriptors: publish frames and repost
   --  the slot. Returns True when at least one frame reached the
   --  ring (the caller signals netserv once per batch).
   function Drain_Rx return Boolean is
      Head    : Virtio.U16;
      Written : Virtio.U32;
      Got     : Boolean := False;
   begin
      while Virtio.Queues.Has_Completed (Rx_Q) loop
         Virtio.Queues.Pop (Rx_Q, Head, Written);

         if Written >= Virtio.U32 (Hdr_Len + 14) then
            Publish (Natural (Head), Natural (Written) - Hdr_Len);
            Got := Got or else Ring_Live;
         elsif Ring_Live then
            --  Runt frame: count it (the ring header is unmapped
            --  until Op_Set_Rx, so never touch it before then).
            Ring_Hdr (2) := Ring_Hdr (2) + 1;
         end if;

         --  Repost the same descriptor (descriptor id == slot).
         Virtio.Queues.Set_Buffer
           (Rx_Q, Head, Rx_Slot_PA (Natural (Head)),
            Rx_Slot_Size, Device_Writes => True);
         Virtio.Queues.Submit (Rx_Q, Head);
      end loop;
      return Got;
   end Drain_Rx;

   --  Drain TX completions (single outstanding chain at a time).
   procedure Drain_Tx is
      Head    : Virtio.U16;
      Written : Virtio.U32;
   begin
      while Virtio.Queues.Has_Completed (Tx_Q) loop
         Virtio.Queues.Pop (Tx_Q, Head, Written);
         Virtio.Queues.Free (Tx_Q, Head);
         Tx_Busy := False;
      end loop;
   end Drain_Tx;

   --  Common IRQ service: clear the virtio cause, complete the
   --  PLIC claim (skipped for the virtual MSI source), drain both
   --  queues, signal netserv when frames were published.
   procedure Handle_Interrupt is
      Got : Boolean;
   begin
      ISR := Dev.Interrupt_Status;
      if ISR /= 0 then
         Dev.ACK_Interrupt (ISR);
      end if;

      Result := IRQ_Ack (IRQ_Cap);

      Got := Drain_Rx;
      Drain_Tx;

      if Got then
         System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
         Result := Ntfn_Signal (Ring_Ntfn, 1);
      end if;
   end Handle_Interrupt;

   --  Transmit one frame: two-descriptor chain (our zeroed legacy
   --  header, then the caller's buffer DMA'd directly). Polls the
   --  used ring until the chain completes; RX keeps being drained
   --  during the wait. QEMU's virtio-net suppresses TX-completion
   --  interrupts (tx mitigation: signalled_used_valid stays false),
   --  so waiting on the IRQ notification here can sleep forever —
   --  the m72a/m72b wedge: one slow completion hung the driver,
   --  starved RX, and backed up the whole netserv/fs chain.
   procedure Transmit (Buf_PA : U64; Frame_Len : U64) is
      H : constant Virtio.U16 := Virtio.Queues.Alloc (Tx_Q);
      D : constant Virtio.U16 := Virtio.Queues.Alloc (Tx_Q);
      Spins : Natural;
   begin
      Virtio.Queues.Set_Buffer
        (Tx_Q, H, Tx_Page_PA, Hdr_Len, Device_Writes => False);
      Virtio.Queues.Chain_Next (Tx_Q, H, D);
      Virtio.Queues.Set_Buffer
        (Tx_Q, D, Buf_PA, Virtio.U32 (Frame_Len),
         Device_Writes => False);
      Tx_Busy := True;
      Virtio.Queues.Submit (Tx_Q, H);
      Dev.Notify (1);

      Spins := 0;
      while Tx_Busy loop
         Handle_Interrupt;

         exit when not Tx_Busy;

         Spins := Spins + 1;
         if Spins > 1_000_000 then
            Fail ("virtio-net tx completion timeout");
         end if;

         --  The completion lands in wall-clock time, not CPU time;
         --  drop to the bottom of the run queue between polls.
         if Spins mod 1_000 = 0 then
            Yield;
         end if;
      end loop;
   end Transmit;

begin
   Akernel_User.Console.Set_Endpoint (Console_EP);

   Map_Region (Common_Cap, Common_VA, "common");
   Map_Region (Notify_Cap, Notify_VA, "notify");
   Map_Region (ISR_Cap,    ISR_VA,    "isr");
   Map_Region (Cfg_Cap,    Cfg_VA,    "cfg");

   --  Devmgr driver config message (notify multiplier, IRQ source,
   --  PCI device id); answered with status 0.
   Result := IPC_Recv (Svc_EP, Reply_H);
   if Result /= IPC_Ok or else Message.Label /= Driver_Config_Label then
      Debug_Put_Line ("virtio-net config message missing");
      Process_Exit;
   end if;
   Notify_Mult := Message.Words (0);

   --  MSI-X hand-off from the device manager: Words(3) non-zero and
   --  Caps(0) carries the dedicated vector IRQ cap.
   if Message.Words (3) /= 0 and then Message.Caps (0) /= 0 then
      IRQ_Cap := Message.Caps (0);
      Dev.Enable_MSIX (0);
      Akernel_User.Console.Put_Line ("PASS virtio-net msix enabled");
   end if;

   Message.Words := (others => 0);
   Message.Caps := (others => 0);  --  m75: replies transfer caps
   if IPC_Reply (Reply_H) /= IPC_Ok then
      Debug_Put_Line ("virtio-net config reply failed");
      Process_Exit;
   end if;

   if Dev.Num_Queues < 2 then
      Debug_Put_Line ("virtio-net queue pair missing");
      Process_Exit;
   end if;

   Dev.Reset;
   Dev.Set_Status (Virtio.Status_Acknowledge);
   Dev.Add_Status (Virtio.Status_Driver);

   --  MAC: device config offset 0..5 when VIRTIO_NET_F_MAC
   --  negotiates, else a locally administered fallback ("AKNET").
   if (Dev.Device_Features and Feat_MAC) /= 0 then
      Dev.Set_Driver_Features (Feat_MAC);
   else
      Dev.Set_Driver_Features (0);
   end if;
   Dev.Add_Status (Virtio.Status_Features_Ok);

   if (Dev.Status and Virtio.Status_Features_Ok) = 0 then
      Debug_Put_Line ("virtio-net features rejected");
      Process_Exit;
   end if;

   --  m77: make the datapath mode loud.  Only feature word 0 was
   --  offered above, so a spec-compliant device now runs the
   --  legacy datapath and Hdr_Len = 10 holds; a modern-only
   --  device would have rejected FEATURES_OK and we would not be
   --  here.  Report whether the device offered VIRTIO_F_VERSION_1
   --  so a future QEMU config change is visible in the boot log.
   if (Dev.Device_Features_Hi and Feat_Version_1) /= 0 then
      Akernel_User.Console.Put_Line
        ("virtio-net legacy datapath (modern offered, not negotiated),"
         & " virtio_net_hdr 10 bytes");
   else
      Akernel_User.Console.Put_Line
        ("virtio-net legacy datapath, virtio_net_hdr 10 bytes");
   end if;

   if (Dev.Device_Features and Feat_MAC) /= 0 then
      for I in 0 .. 5 loop
         Our_Mac (I) := U8 (Cfg8 (U64 (I)));
      end loop;
   else
      Our_Mac := (16#02#, 16#41#, 16#4B#, 16#4E#, 16#45#, 16#54#);
   end if;

   --  IRQ-driven completions: fresh notification object bound to
   --  this thread, IRQ line bound to the notification (badge 1).
   Ntfn_Cap := Ntfn_Create;
   if Ntfn_Cap = Syscall_Failed then
      Debug_Put_Line ("virtio-net ntfn create failed");
      Process_Exit;
   end if;

   Result := Ntfn_Bind_Thread (Ntfn_Cap);
   if Result /= 0 then
      Debug_Put_Line ("virtio-net ntfn bind thread failed");
      Process_Exit;
   end if;

   Result := IRQ_Bind_Ntfn (IRQ_Cap, Ntfn_Cap, Badge => 1);
   if Result /= 0 then
      Debug_Put_Line ("virtio-net irq bind failed");
      Process_Exit;
   end if;

   DMA_Cap := Mem_Alloc (DMA_Pages);
   if DMA_Cap = Syscall_Failed then
      Debug_Put_Line ("virtio-net dma alloc failed");
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
      Debug_Put_Line ("virtio-net dma map failed");
      Process_Exit;
   end if;

   for P in 0 .. 2 loop
      Rx_Ring_PA (P) := Mem_Object_PA (DMA_Cap, U64 (P));
      Tx_Ring_PA (P) := Mem_Object_PA (DMA_Cap, U64 (3 + P));
   end loop;
   for P in 0 .. Rx_Slot_Pages - 1 loop
      Rx_Page_PA (P) := Mem_Object_PA (DMA_Cap, U64 (6 + P));
   end loop;
   Tx_Page_PA := Mem_Object_PA (DMA_Cap, 14);
   if Rx_Ring_PA (0) = 0 or else Tx_Ring_PA (0) = 0
     or else Rx_Page_PA (0) = 0 or else Tx_Page_PA = 0
   then
      Debug_Put_Line ("virtio-net dma pa query failed");
      Process_Exit;
   end if;

   --  The TX header staging is a constant zeroed legacy
   --  virtio_net_hdr (no offload, no GSO).
   for I in 0 .. Hdr_Len - 1 loop
      Tx_Staging (U64 (I)) := 0;
   end loop;

   Virtio.Queues.Initialize
     (Q     => Rx_Q,
      Desc  => To_Addr (DMA_VA),
      Avail => To_Addr (DMA_VA + 4096),
      Used  => To_Addr (DMA_VA + 2 * 4096),
      Num   => Queue_Num);
   Virtio.Queues.Initialize
     (Q     => Tx_Q,
      Desc  => To_Addr (DMA_VA + 3 * 4096),
      Avail => To_Addr (DMA_VA + 4 * 4096),
      Used  => To_Addr (DMA_VA + 5 * 4096),
      Num   => Queue_Num);

   Dev.Queue_Select (0);
   Dev.Queue_Setup
     (Num      => Virtio.U32 (Queue_Num),
      Desc_PA  => Rx_Ring_PA (0),
      Avail_PA => Rx_Ring_PA (1),
      Used_PA  => Rx_Ring_PA (2));
   Dev.Queue_Select (1);
   Dev.Queue_Setup
     (Num      => Virtio.U32 (Queue_Num),
      Desc_PA  => Tx_Ring_PA (0),
      Avail_PA => Tx_Ring_PA (1),
      Used_PA  => Tx_Ring_PA (2));
   Dev.Add_Status (Virtio.Status_Driver_Ok);

   --  Pre-post every RX buffer (descriptor id == slot index).
   for Slot in 0 .. Rx_Slots - 1 loop
      Virtio.Queues.Set_Buffer
        (Rx_Q, Virtio.U16 (Slot), Rx_Slot_PA (Slot),
         Rx_Slot_Size, Device_Writes => True);
      Virtio.Queues.Submit (Rx_Q, Virtio.U16 (Slot));
   end loop;
   Dev.Notify (0);

   ------------------------------------------------------------------
   --  Self-test: ARP the slirp gateway, expect the reply
   ------------------------------------------------------------------

   declare
      F : U64 := 16;  --  frame base in the TX staging page
      Spins : Natural;
      Found : Boolean := False;
      Frame : U64;

      procedure Put (Offset : U64; Value : U8) is
      begin
         Tx_Staging (F + Offset) := Value;
      end Put;
   begin
      --  Ethernet: broadcast dst, our src, ethertype ARP.
      for I in 0 .. 5 loop
         Put (U64 (I), 16#FF#);
         Put (U64 (6 + I), Our_Mac (I));
      end loop;
      Put (12, 16#08#);
      Put (13, 16#06#);
      --  ARP: htype 1, ptype IPv4, hlen 6, plen 4, oper request.
      Put (14, 16#00#);  Put (15, 16#01#);
      Put (16, 16#08#);  Put (17, 16#00#);
      Put (18, 16#06#);  Put (19, 16#04#);
      Put (20, 16#00#);  Put (21, 16#01#);
      for I in 0 .. 5 loop
         Put (U64 (22 + I), Our_Mac (I));
         Put (U64 (32 + I), 16#00#);
      end loop;
      Put (28, 10);  Put (29, 0);  Put (30, 2);  Put (31, 15);
      Put (38, 10);  Put (39, 0);  Put (40, 2);  Put (41, 2);

      Transmit (Tx_Page_PA + 16, 42);

      --  Wait for the ARP reply (oper 2 from 10.0.2.2 naming us).
      Spins := 0;
      loop
         Handle_Interrupt;

         --  Handle_Interrupt -> Drain_Rx publishes only when the
         --  ring is live; during the self-test frames stay in the
         --  RX slots, so scan them here instead.
         Found := False;
         for Slot in 0 .. Rx_Slots - 1 loop
            Frame := U64 (Slot) * 2048 + Hdr_Len;
            if Rx_Slot_Mem (Frame + 12) = 16#08#
              and then Rx_Slot_Mem (Frame + 13) = 16#06#
              and then Rx_Slot_Mem (Frame + 21) = 16#02#
              and then Rx_Slot_Mem (Frame + 28) = 10
              and then Rx_Slot_Mem (Frame + 31) = 2
              and then Rx_Slot_Mem (Frame + 38) = 10
              and then Rx_Slot_Mem (Frame + 41) = 15
            then
               Found := True;
               exit;
            end if;
         end loop;
         exit when Found;

         Spins := Spins + 1;
         if Spins > 1_000 then
            Fail ("virtio-net arp self-test timeout");
         end if;

         Bits := Ntfn_Wait (Ntfn_Cap);
      end loop;

      Akernel_User.Console.Put_Line ("PASS virtio-net arp reply ok");
   end;

   ------------------------------------------------------------------
   --  Frame service loop
   ------------------------------------------------------------------

   Akernel_User.Console.Put_Line ("virtio-net service online");

   declare
      Frame_Len : U64;
      Buf_Cap   : U64;
      Buf_PA    : U64;
      Ring_Bytes : U64;
      Status    : U64;
   begin
      loop
         Result := IPC_Recv (Svc_EP, Reply_H);
         if Result /= IPC_Ok then
            Debug_Put_Line ("virtio-net recv failed");
            Process_Exit;
         end if;

         if Message.Label = Notification_Label then
            --  IRQ notification (synthetic message, NO reply cap):
            --  drain both queues, publish, ack.
            Handle_Interrupt;

         elsif Message.Label = Op_Info then
            Message.Words (0) := 0;
            Message.Words (1) :=
              U64 (Our_Mac (0))
              or U64 (Our_Mac (1)) * 16#100#
              or U64 (Our_Mac (2)) * 16#10000#
              or U64 (Our_Mac (3)) * 16#100_0000#;
            Message.Words (2) :=
              U64 (Our_Mac (4)) or U64 (Our_Mac (5)) * 16#100#;
            Message.Words (3) := MTU;
            Message.Caps := (others => 0);  --  m75
            if IPC_Reply (Reply_H) /= IPC_Ok then
               Debug_Put_Line ("virtio-net reply failed");
            end if;

         elsif Message.Label = Op_Tx then
            Frame_Len := Message.Words (0);
            Buf_Cap   := Message.Caps (0);
            --  m75: detach the received buffer cap so no reply
            --  bounces it back to the caller.
            Message.Caps := (others => 0);

            if Buf_Cap = 0 or else Frame_Len < 14
              or else Frame_Len > MTU + 14
            then
               Message.Words (0) := 3;  --  bad arguments
               Message.Words (1) := 0;
               if IPC_Reply (Reply_H) /= IPC_Ok then
                  Debug_Put_Line ("virtio-net reply failed");
               end if;
             else
                Buf_PA := Mem_Object_PA (Buf_Cap, 0);
                if Buf_PA = 0 then
                   Status := 3;
                else
                   Transmit (Buf_PA, Frame_Len);
                   Status := 0;
                end if;
               Message.Words (0) := Status;
               Message.Words (1) := 0;
               if IPC_Reply (Reply_H) /= IPC_Ok then
                  Debug_Put_Line ("virtio-net reply failed");
               end if;
            end if;

            --  The transferred buffer cap is consumed by the
            --  request; delete it or leak a cap-table slot per RPC.
            if Buf_Cap /= 0 and then Cap_Delete (Buf_Cap) /= 0 then
               Debug_Put_Line ("virtio-net buffer cap delete failed");
            end if;

         elsif Message.Label = Op_Set_Rx then
            Ring_Bytes := Message.Words (0);

            if Ring_Live
              or else Message.Caps (0) = 0
              or else Message.Caps (1) = 0
              or else Ring_Bytes < 4096 + 2048
              or else Ring_Bytes > Ring_Window
              or else Ring_Bytes mod 4096 /= 0
            then
               Message.Words (0) := 3;  --  bad arguments
               Message.Words (1) := 0;
               Message.Caps := (others => 0);  --  m75
               if IPC_Reply (Reply_H) /= IPC_Ok then
                  Debug_Put_Line ("virtio-net reply failed");
               end if;
            else
               Ring_Cap  := Message.Caps (0);
               Ring_Ntfn := Message.Caps (1);
               --  m75: replies transfer caps; detach the received
               --  ring caps from the buffer.
               Message.Caps := (others => 0);

               Result := Mem_Map
                 (Address_Space => Address_Space_Cap,
                  Cap           => Ring_Cap,
                  VA            => Ring_VA,
                  Offset        => 0,
                  Length        => Ring_Bytes,
                  Flags         => 3);
               if Result /= 0 then
                  if Cap_Delete (Ring_Cap) /= 0
                    or else Cap_Delete (Ring_Ntfn) /= 0
                  then
                     Debug_Put_Line ("virtio-net ring cap cleanup");
                  end if;
                  Ring_Cap  := 0;
                  Ring_Ntfn := 0;
                  Message.Words (0) := 1;
                  Message.Words (1) := 0;
                  if IPC_Reply (Reply_H) /= IPC_Ok then
                     Debug_Put_Line ("virtio-net reply failed");
                  end if;
               else
                  Ring_Slot_Count := (Ring_Bytes - 4096) / 2048;
                  Ring_Hdr (0) := 0;  --  head
                  Ring_Hdr (1) := 0;  --  tail
                  Ring_Hdr (2) := 0;  --  dropped
                  Ring_Hdr (3) := Ring_Slot_Count;
                  Ring_Live := True;
                  Message.Words (0) := 0;
                  Message.Words (1) := Ring_Slot_Count;
                  if IPC_Reply (Reply_H) /= IPC_Ok then
                     Debug_Put_Line ("virtio-net reply failed");
                  end if;
                  Akernel_User.Console.Put_Line
                    ("virtio-net rx ring online");
               end if;
            end if;

         else
            Message.Words (0) := 3;
            Message.Words (1) := 0;
            Message.Caps := (others => 0);  --  m75
            if IPC_Reply (Reply_H) /= IPC_Ok then
               Debug_Put_Line ("virtio-net reply failed");
            end if;
         end if;
      end loop;
   end;
end Virtio_Net;
