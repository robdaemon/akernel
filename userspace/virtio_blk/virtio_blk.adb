with System;
with System.Storage_Elements;
with Interfaces;
with Akernel_User.Console;
with Akernel_User.Syscalls;
with Virtio;
with Virtio.PCI;
with Virtio.Queues;

--  Virtio block driver over the PCI transport (virtio-blk-pci,
--  transitional id 1af4:1001 or modern 1041). Spawned by init's
--  device manager when the PCI bus scan matches a System/Drivers
--  pci line of class 2. Fixed 7-handle PCI driver ABI (grant
--  order): 1 = console endpoint (Send), 2 = common-cfg MMIO cap,
--  3 = notify MMIO cap, 4 = ISR MMIO cap, 5 = device-cfg MMIO cap,
--  6 = IRQ cap, 7 = block service endpoint (Receive). The first
--  message on the service endpoint is the devmgr's driver config
--  (notify_off_multiplier in word 0, IRQ source in word 1, PCI
--  device id in word 2), answered with a status-0 reply.
--  Completions are IRQ-driven over INTx: the ISR register read
--  clears the virtio interrupt cause, IRQ_Ack completes the PLIC
--  claim, and the IRQ line signals a thread-bound notification
--  object that Ntfn_Wait blocks on.
--
--  Boot self-test against the generated disk image (Makefile
--  disk.img, 2048 sectors):
--    sector 0      = "AKBLKIMG" then 0xA5 fill
--    sector s >= 1 = byte j of (s + j) mod 256
--  then a write/readback round-trip on sector 3. Afterwards the
--  driver serves the block protocol on handle 7:
--    Op 0 info:  -> (status, capacity in sectors)
--    Op 1 read:  (sector, count<=8) + buffer memory-object cap in
--                slot 0 (Manage right; the driver only queries its
--                first frame's PA and DMAs straight into it)
--    Op 2 write: same, buffer -> device
--    Op 4 flush: no words; write-back cache -> device, then a
--                VIRTIO_BLK_T_FLUSH when the feature negotiated
--  Replies carry (status, 0); status 0 = ok, 1 = io error,
--  3 = bad arguments.
--
--  Write-back sector cache (milestone 48): 64 slots x 512 B in a
--  DMA-capable object. WRITES copy client data into slots (the
--  client buffer mapped one page at Buf_Win_VA) and reply
--  immediately — no device op; repeated writes to the same
--  sector (FAT metadata bursts) coalesce. READS DMA miss runs
--  straight into the client buffer like before and CPU-copy only
--  dirty / previously-written hit sectors from slots, so
--  streaming reads stay uncached and correct data always wins.
--  Dirty slots reach the device (a) on LRU eviction, (b) at the
--  top of the service loop whenever any are pending —
--  write-behind: a quiet system is a flushed system, so the
--  harness killing qemu loses nothing — and (c) on Op 4, which
--  additionally issues VIRTIO_BLK_T_FLUSH when feature bit 9
--  negotiated. The server is the sole accessor of its device,
--  so the cache is trivially coherent.

procedure Virtio_Blk is
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
   DMA_VA    : constant U64 := 16#5004_0000#;
   --  DMA object layout: page 0 descriptors, page 1 avail ring,
   --  page 2 used ring, page 3 request header + status byte,
   --  page 4 sector data buffer.
   DMA_Pages : constant U64 := 5;

   Sector_Size : constant := 512;

   --  Virtio-blk request types (virtio 1.2 §5.2).
   Req_Read  : constant Virtio.U32 := 0;
   Req_Write : constant Virtio.U32 := 1;
   Req_Flush : constant Virtio.U32 := 4;

   --  VIRTIO_BLK_F_FLUSH (feature bit 9) fits the 32-bit
   --  transitional feature word.
   Feat_Flush : constant Virtio.U32 := 2 ** 9;

   --  Block protocol labels (shared with System/Fileserver).
   Op_Info  : constant U64 := 0;
   Op_Read  : constant U64 := 1;
   Op_Write : constant U64 := 2;
   Op_Flush : constant U64 := 4;  --  3 = partmgr's Part_Query

   --  Write-back cache: 64 slots of one sector in 8 pages.
   Cache_Slots : constant := 64;
   Cache_Pages : constant U64 := 8;
   Cache_VA    : constant U64 := 16#5005_0000#;
   --  Per-op mapping window for the client's buffer cap (Count
   --  <= 8 sectors = one page).
   Buf_Win_VA  : constant U64 := 16#5006_0000#;

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

   type Byte_Array is array (Natural range 0 .. 4095) of U8
     with Volatile_Components;

   Data_Page : Byte_Array
     with Address => To_Addr (DMA_VA + 4 * 4096);

   --  Request header page: words 0..1 = type/reserved, words 2..3 =
   --  sector (U64 little-endian), status byte at offset 16.
   type Word_Array is array (Natural range 0 .. 7) of Virtio.U32
     with Volatile_Components;

   Req_Words : Word_Array
     with Address => To_Addr (DMA_VA + 3 * 4096);

   Status_Byte : U8
     with Volatile, Address => To_Addr (DMA_VA + 3 * 4096 + 16);

   ------------------------------------------------------------------

   Result   : U64;
   Reply_H  : U64;  --  reply cap of the request being served (m47)
   DMA_Cap  : U64;
   Ntfn_Cap : U64;
   Bits     : U64;
   ISR      : Virtio.U32;
   Capacity : U64;
   Q        : Virtio.Queues.Queue;
   Desc_PA  : U64;
   Avail_PA : U64;
   Used_PA  : U64;
   Req_PA   : U64;
   Data_PA  : U64;
   Head     : Virtio.U16;
   Written  : Virtio.U32;
   Ok       : Boolean;
   Pattern_Image : Boolean;
   Have_Flush : Boolean;

   --  Write-back cache state (milestone 48). Slot data lives in
   --  the cache DMA object; these arrays are the metadata. LRU
   --  by a global age tick; eviction writes a dirty victim back
   --  first.
   Cache_Cap     : U64;
   Cache_Page_PA : array (0 .. Natural (Cache_Pages) - 1) of U64 :=
     (others => 0);
   Slot_Valid    : array (0 .. Cache_Slots - 1) of Boolean :=
     (others => False);
   Slot_Dirty    : array (0 .. Cache_Slots - 1) of Boolean :=
     (others => False);
   Slot_Sector   : array (0 .. Cache_Slots - 1) of U64 :=
     (others => 0);
   Slot_Age      : array (0 .. Cache_Slots - 1) of U64 :=
     (others => 0);
   Age_Tick      : U64 := 0;

   type Cache_Array is
     array (U64 range 0 .. Cache_Pages * 4096 - 1) of U8
     with Volatile_Components;
   Cache_Mem : Cache_Array with Address => To_Addr (Cache_VA);

   Buf_Win : Byte_Array with Address => To_Addr (Buf_Win_VA);

   --  Issue one request (3-descriptor chain: header read-only,
   --  data in/out per Op, status byte writable) and block on the
   --  IRQ notification until it completes. Buf_PA is the physical
   --  address of Len bytes of payload. Returns the device status
   --  byte (0 = OK).
   function Do_Request
     (Op     : Virtio.U32;
      Sector : U64;
      Buf_PA : U64;
      Len    : Virtio.U32) return U8 is
      H : constant Virtio.U16 := Virtio.Queues.Alloc (Q);
      D : constant Virtio.U16 := Virtio.Queues.Alloc (Q);
      S : constant Virtio.U16 := Virtio.Queues.Alloc (Q);
      Spins : Natural;
   begin
      Req_Words (0) := Op;
      Req_Words (1) := 0;
      Req_Words (2) := Virtio.U32 (Sector and 16#FFFF_FFFF#);
      Req_Words (3) := Virtio.U32 (Sector / 16#1_0000_0000#);
      Status_Byte := 16#FF#;

      Virtio.Queues.Set_Buffer (Q, H, Req_PA, 16, Device_Writes => False);
      Virtio.Queues.Chain_Next (Q, H, D);
      Virtio.Queues.Set_Buffer
        (Q, D, Buf_PA, Len,
         Device_Writes => Op = Req_Read);
      Virtio.Queues.Chain_Next (Q, D, S);
      Virtio.Queues.Set_Buffer (Q, S, Req_PA + 16, 1, Device_Writes => True);
      Virtio.Queues.Submit (Q, H);
      Dev.Notify (0);

      --  Interrupt-driven wait: read the ISR register (clears the
      --  virtio interrupt cause at the device, dropping INTx),
      --  complete the PLIC claim (IRQ_Ack — without it the PLIC
      --  gateways stay blocked and no further interrupt from this
      --  source is delivered), then block on the notification.
      --  An IRQ arriving between Has_Completed and Ntfn_Wait leaves
      --  bits pending, which the wait consumes immediately — no
      --  lost wakeup. IRQ_Ack on a non-pending line returns 2,
      --  harmless.
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
            Debug_Put_Line ("virtio-blk completion timeout");
            Process_Exit;
         end if;

         Bits := Ntfn_Wait (Ntfn_Cap);
      end loop;

      Virtio.Queues.Pop (Q, Head, Written);
      Virtio.Queues.Free (Q, Head);
      return Status_Byte;
   end Do_Request;

   --  VIRTIO_BLK_T_FLUSH: header + status only, no data
   --  descriptor. Asks the device to push its own volatile
   --  buffers to stable storage.
   procedure Do_Device_Flush is
      H : constant Virtio.U16 := Virtio.Queues.Alloc (Q);
      S : constant Virtio.U16 := Virtio.Queues.Alloc (Q);
      Spins : Natural;
   begin
      Req_Words (0) := Req_Flush;
      Req_Words (1) := 0;
      Req_Words (2) := 0;
      Req_Words (3) := 0;
      Status_Byte := 16#FF#;

      Virtio.Queues.Set_Buffer (Q, H, Req_PA, 16, Device_Writes => False);
      Virtio.Queues.Chain_Next (Q, H, S);
      Virtio.Queues.Set_Buffer (Q, S, Req_PA + 16, 1, Device_Writes => True);
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
            Debug_Put_Line ("virtio-blk flush timeout");
            Process_Exit;
         end if;

         Bits := Ntfn_Wait (Ntfn_Cap);
      end loop;

      Virtio.Queues.Pop (Q, Head, Written);
      Virtio.Queues.Free (Q, Head);
   end Do_Device_Flush;

   ------------------------------------------------------------------
   --  Write-back cache
   ------------------------------------------------------------------

   function Slot_PA (S : Natural) return U64 is
     (Cache_Page_PA (S / 8) + U64 (S mod 8) * 512);

   --  Linear scan; 64 compares beat any IPC round-trip.
   function Find_Slot (Sector : U64) return Integer is
   begin
      for S in 0 .. Cache_Slots - 1 loop
         if Slot_Valid (S) and then Slot_Sector (S) = Sector then
            return S;
         end if;
      end loop;
      return -1;
   end Find_Slot;

   procedure Touch (S : Natural) is
   begin
      Age_Tick := Age_Tick + 1;
      Slot_Age (S) := Age_Tick;
   end Touch;

   --  Victim: first invalid slot, else the least recently used;
   --  a dirty victim is written back to the device first.
   --  Returns -1 when the write-back failed.
   function Alloc_Slot (Sector : U64) return Integer is
      Victim : Natural := 0;
   begin
      for S in 0 .. Cache_Slots - 1 loop
         if not Slot_Valid (S) then
            Victim := S;
            Slot_Valid (S)  := True;
            Slot_Dirty (S)  := False;
            Slot_Sector (S) := Sector;
            Touch (S);
            return S;
         end if;
      end loop;

      for S in 1 .. Cache_Slots - 1 loop
         if Slot_Age (S) < Slot_Age (Victim) then
            Victim := S;
         end if;
      end loop;

      if Slot_Dirty (Victim)
        and then Do_Request
          (Req_Write, Slot_Sector (Victim), Slot_PA (Victim), 512) /= 0
      then
         Debug_Put_Line ("virtio-blk cache eviction write failed");
         return -1;
      end if;

      Slot_Dirty (Victim)  := False;
      Slot_Sector (Victim) := Sector;
      Touch (Victim);
      return Victim;
   end Alloc_Slot;

   --  Push every dirty slot to the device and mark clean (the
   --  slot stays valid — a correct cached copy). Force_Device
   --  (explicit Op_Flush) also issues VIRTIO_BLK_T_FLUSH even
   --  with a clean cache. Returns True on success.
   function Flush_Dirty (Force_Device : Boolean) return Boolean is
      Any : Boolean := False;
   begin
      for S in 0 .. Cache_Slots - 1 loop
         if Slot_Valid (S) and then Slot_Dirty (S) then
            Any := True;
            exit;
         end if;
      end loop;

      if not Any and then not Force_Device then
         return True;
      end if;

      for S in 0 .. Cache_Slots - 1 loop
         if Slot_Valid (S) and then Slot_Dirty (S) then
            if Do_Request
              (Req_Write, Slot_Sector (S), Slot_PA (S), 512) /= 0
            then
               return False;
            end if;
            Slot_Dirty (S) := False;
         end if;
      end loop;

      --  Device flush only on EXPLICIT sync: the idle
      --  write-behind must not pay a VIRTIO_BLK_T_FLUSH per
      --  write (the probe measured one flush request per
      --  absorbed sector — 2x the round-trips write-through
      --  would have cost). QEMU's write() lands in the host
      --  page cache, visible to the post-suite fsck, so the
      --  loss window stays bounded without it.
      if Force_Device and then Have_Flush then
         Do_Device_Flush;
      end if;
      return True;
   end Flush_Dirty;

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
         Debug_Put_Line ("virtio-blk map " & Name & " failed");
         Process_Exit;
      end if;
   end Map_Region;

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
      Debug_Put_Line ("virtio-blk config message missing");
      Process_Exit;
   end if;
   Notify_Mult := Message.Words (0);

   --  MSI-X hand-off from the device manager: Words(3) non-zero and
   --  Caps(0) carries the dedicated vector IRQ cap.
   if Message.Words (3) /= 0 and then Message.Caps (0) /= 0 then
      IRQ_Cap := Message.Caps (0);
      Dev.Enable_MSIX (0);
      Akernel_User.Console.Put_Line ("PASS virtio-blk msix enabled");
   end if;

   Message.Words := (others => 0);
   Message.Caps := (others => 0);  --  m75: replies transfer caps
   if IPC_Reply (Reply_H) /= IPC_Ok then
      Debug_Put_Line ("virtio-blk config reply failed");
      Process_Exit;
   end if;

   if Dev.Num_Queues = 0 then
      Debug_Put_Line ("virtio-blk no queues");
      Process_Exit;
   end if;

   --  Capacity lives at device-cfg offset 0 (U64 sectors).
   Capacity := U64 (Cfg32 (0)) or U64 (Cfg32 (1)) * 16#1_0000_0000#;

   Dev.Reset;
   Dev.Set_Status (Virtio.Status_Acknowledge);
   Dev.Add_Status (Virtio.Status_Driver);
   Have_Flush := (Dev.Device_Features and Feat_Flush) /= 0;
   Dev.Set_Driver_Features ((if Have_Flush then Feat_Flush else 0));
   Dev.Add_Status (Virtio.Status_Features_Ok);

   if (Dev.Status and Virtio.Status_Features_Ok) = 0 then
      Debug_Put_Line ("virtio-blk features rejected");
      Process_Exit;
   end if;

   if Have_Flush then
      Akernel_User.Console.Put_Line
        ("PASS virtio-blk flush feature negotiated");
   else
      Akernel_User.Console.Put_Line
        ("FAIL virtio-blk flush feature absent");
   end if;

   --  IRQ-driven completions: fresh notification object bound to
   --  this thread (without the binding Signal cannot wake a
   --  Ntfn_Wait blocked thread — it only records bits), IRQ line
   --  bound to the notification (badge 1).
   Ntfn_Cap := Ntfn_Create;
   if Ntfn_Cap = Syscall_Failed then
      Debug_Put_Line ("virtio-blk ntfn create failed");
      Process_Exit;
   end if;

   Result := Ntfn_Bind_Thread (Ntfn_Cap);
   if Result /= 0 then
      Debug_Put_Line ("virtio-blk ntfn bind thread failed");
      Process_Exit;
   end if;

   Result := IRQ_Bind_Ntfn (IRQ_Cap, Ntfn_Cap, Badge => 1);
   if Result /= 0 then
      Debug_Put_Line ("virtio-blk irq bind failed");
      Process_Exit;
   end if;

   DMA_Cap := Mem_Alloc (DMA_Pages);
   if DMA_Cap = Syscall_Failed then
      Debug_Put_Line ("virtio-blk dma alloc failed");
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
      Debug_Put_Line ("virtio-blk dma map failed");
      Process_Exit;
   end if;

   Desc_PA  := Mem_Object_PA (DMA_Cap, 0);
   Avail_PA := Mem_Object_PA (DMA_Cap, 1);
   Used_PA  := Mem_Object_PA (DMA_Cap, 2);
   Req_PA   := Mem_Object_PA (DMA_Cap, 3);
   Data_PA  := Mem_Object_PA (DMA_Cap, 4);
   if Desc_PA = 0 or else Avail_PA = 0 or else Used_PA = 0
     or else Req_PA = 0 or else Data_PA = 0
   then
      Debug_Put_Line ("virtio-blk dma pa query failed");
      Process_Exit;
   end if;

   --  Write-back cache object (milestone 48): 8 pages of slot
   --  data, mapped into our AS for CPU copies and DMA'd from
   --  during write-backs.
   Cache_Cap := Mem_Alloc (Cache_Pages);
   if Cache_Cap = Syscall_Failed then
      Debug_Put_Line ("virtio-blk cache alloc failed");
      Process_Exit;
   end if;

   Result := Mem_Map
     (Address_Space => Address_Space_Cap,
      Cap           => Cache_Cap,
      VA            => Cache_VA,
      Offset        => 0,
      Length        => Cache_Pages * 4096,
      Flags         => 3);
   if Result /= 0 then
      Debug_Put_Line ("virtio-blk cache map failed");
      Process_Exit;
   end if;

   for P in 0 .. Natural (Cache_Pages) - 1 loop
      Cache_Page_PA (P) := Mem_Object_PA (Cache_Cap, U64 (P));
   end loop;
   if Cache_Page_PA (0) = 0
     or else Cache_Page_PA (Natural (Cache_Pages) - 1) = 0
   then
      Debug_Put_Line ("virtio-blk cache pa query failed");
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
   --  Self-test against the disk image
   ------------------------------------------------------------------

   --  1. Sector 0: the legacy pattern image ("AKBLKIMG") runs the
   --  full pattern + write/readback suite; a real filesystem image
   --  gets read-only checks only — test writes would corrupt
   --  filesystem metadata.
   if Do_Request (Req_Read, 0, Data_PA, Sector_Size) /= 0 then
      Fail ("virtio-blk read sector 0 io error");
   end if;

   Pattern_Image :=
     Data_Page (0) = 16#41# and then  --  'A'
     Data_Page (1) = 16#4B# and then  --  'K'
     Data_Page (2) = 16#42# and then  --  'B'
     Data_Page (3) = 16#4C# and then  --  'L'
     Data_Page (4) = 16#4B# and then  --  'K'
     Data_Page (5) = 16#49# and then  --  'I'
     Data_Page (6) = 16#4D# and then  --  'M'
     Data_Page (7) = 16#47#;          --  'G'

   if Pattern_Image then
      Ok := True;
      for J in 8 .. Sector_Size - 1 loop
         if Data_Page (J) /= 16#A5# then
            Ok := False;
            exit;
         end if;
      end loop;

      if Ok then
         Akernel_User.Console.Put_Line ("PASS virtio-blk read sector ok");
      else
         Fail ("virtio-blk read sector bad data");
      end if;

      --  2. Pattern sector: byte j of sector s = (s + j) mod 256.
      if Do_Request (Req_Read, 7, Data_PA, Sector_Size) /= 0 then
         Fail ("virtio-blk read sector 7 io error");
      end if;

      Ok := True;
      for J in 0 .. Sector_Size - 1 loop
         if Data_Page (J) /= U8 ((7 + J) mod 256) then
            Ok := False;
            exit;
         end if;
      end loop;

      if Ok then
         Akernel_User.Console.Put_Line ("PASS virtio-blk pattern sector ok");
      else
         Fail ("virtio-blk pattern sector bad data");
      end if;

      --  3. Write/readback round-trip on sector 3 (0xC3 fill).
      for J in 0 .. Sector_Size - 1 loop
         Data_Page (J) := 16#C3#;
      end loop;

      if Do_Request (Req_Write, 3, Data_PA, Sector_Size) /= 0 then
         Fail ("virtio-blk write sector 3 io error");
      end if;

      for J in 0 .. Sector_Size - 1 loop
         Data_Page (J) := 0;
      end loop;

      if Do_Request (Req_Read, 3, Data_PA, Sector_Size) /= 0 then
         Fail ("virtio-blk readback sector 3 io error");
      end if;

      Ok := True;
      for J in 0 .. Sector_Size - 1 loop
         if Data_Page (J) /= 16#C3# then
            Ok := False;
            exit;
         end if;
      end loop;

      if Ok then
         Akernel_User.Console.Put_Line ("PASS virtio-blk write readback ok");
      else
         Fail ("virtio-blk write readback bad data");
      end if;

      if Capacity = 2048 then
         Akernel_User.Console.Put_Line ("PASS virtio-blk capacity ok");
      else
         Akernel_User.Console.Put_Line ("FAIL virtio-blk capacity bad");
      end if;
   else
      --  Filesystem image: the read above succeeded, nothing else
      --  is safe to assert sector-by-sector and nothing is safe to
      --  write.
      Akernel_User.Console.Put_Line ("PASS virtio-blk read sector ok");

      if Capacity = 147456 then  --  72 MiB image (FAT32 + m82b BeFS)
         Akernel_User.Console.Put_Line ("PASS virtio-blk capacity ok");
      else
         Akernel_User.Console.Put_Line ("FAIL virtio-blk capacity bad");
      end if;
   end if;

   ------------------------------------------------------------------
   --  Block service loop
   ------------------------------------------------------------------

   Akernel_User.Console.Put_Line ("virtio-blk service online");

   declare
      Sector  : U64;
      Count   : U64;
      Buf_Cap : U64;
      Buf_PA  : U64;
   begin
      loop
         --  Write-behind: a burst of writes coalesces in the
         --  cache; before parking on the next request, push the
         --  dirty slots out. A quiet system is a flushed system,
         --  so a harness kill of qemu loses nothing.
         if not Flush_Dirty (Force_Device => False) then
            Debug_Put_Line ("virtio-blk idle flush failed");
         end if;

         Result := IPC_Recv (Svc_EP, Reply_H);
         if Result /= IPC_Ok then
            Debug_Put_Line ("virtio-blk recv failed");
            Process_Exit;
         end if;

         if Message.Label = Notification_Label then
            --  Stray IRQ while idle: drain it so the PLIC line is
            --  free for the next real completion.
            ISR := Dev.Interrupt_Status;
            if ISR /= 0 then
               Dev.ACK_Interrupt (ISR);
            end if;

            Result := IRQ_Ack (IRQ_Cap);

         elsif Message.Label = Op_Info then
            Message.Words (0) := 0;
            Message.Words (1) := Capacity;
            Message.Caps := (others => 0);  --  m75
            if IPC_Reply (Reply_H) /= IPC_Ok then
               Debug_Put_Line ("virtio-blk reply failed");
            end if;

         elsif Message.Label = Op_Flush then
            --  Explicit sync (fat32's Op_Sync hook, milestone 22
            --  -> 48): write back every dirty slot, then the
            --  device flush when negotiated.
            Message.Words (0) :=
              (if Flush_Dirty (Force_Device => True) then 0 else 1);
            Message.Words (1) := 0;
            Message.Caps := (others => 0);  --  m75
            if IPC_Reply (Reply_H) /= IPC_Ok then
               Debug_Put_Line ("virtio-blk reply failed");
            end if;

         elsif Message.Label = Op_Read then
            Sector  := Message.Words (0);
            Count   := Message.Words (1);
            Buf_Cap := Message.Caps (0);
            --  m75: replies transfer caps; detach the received
            --  buffer cap from the buffer so no reply bounces it.
            Message.Caps := (others => 0);

            if Buf_Cap = 0 or else Count = 0 or else Count > 8
              or else Sector + Count > Capacity
            then
               Message.Words (0) := 3;  --  bad arguments
               Message.Words (1) := 0;
               if IPC_Reply (Reply_H) /= IPC_Ok then
                  Debug_Put_Line ("virtio-blk reply failed");
               end if;
            else
               Buf_PA := Mem_Object_PA (Buf_Cap, 0);
               if Buf_PA = 0 then
                  Message.Words (0) := 3;
                  Message.Words (1) := 0;
                  if IPC_Reply (Reply_H) /= IPC_Ok then
                     Debug_Put_Line ("virtio-blk reply failed");
                  end if;
               else
                  --  Miss runs DMA straight into the client
                  --  buffer (streaming stays uncached); hit
                  --  sectors are CPU-copied from their slots
                  --  over the window afterwards (a dirty slot
                  --  is newer than the device).
                  declare
                     Hit      : array (0 .. 7) of Boolean :=
                       (others => False);
                     Hit_Slot : array (0 .. 7) of Integer :=
                       (others => -1);
                     Any_Hit  : Boolean := False;
                     Run_From : Integer := -1;
                     Rd_St    : U8 := 0;
                  begin
                     for I in 0 .. Natural (Count) - 1 loop
                        Hit_Slot (I) := Find_Slot (Sector + U64 (I));
                        Hit (I) := Hit_Slot (I) >= 0;
                        Any_Hit := Any_Hit or else Hit (I);
                     end loop;

                     for I in 0 .. Natural (Count) - 1 loop
                        if not Hit (I) and then Run_From < 0 then
                           Run_From := I;
                        elsif Hit (I) and then Run_From >= 0 then
                           if Rd_St = 0 then
                              Rd_St := Do_Request
                                (Req_Read,
                                 Sector + U64 (Run_From),
                                 Buf_PA + U64 (Run_From) * 512,
                                 Virtio.U32 (I - Run_From) * 512);
                           end if;
                           Run_From := -1;
                        end if;
                     end loop;
                     if Run_From >= 0 and then Rd_St = 0 then
                        Rd_St := Do_Request
                          (Req_Read,
                           Sector + U64 (Run_From),
                           Buf_PA + U64 (Run_From) * 512,
                           Virtio.U32 (Natural (Count) - Run_From) * 512);
                     end if;

                     if Rd_St = 0 and then Any_Hit then
                        --  Flags 3 = RW: the kernel rejects
                        --  write-ONLY mappings ((Flags and 3)
                        --  = 2).
                        Result := Mem_Map
                          (Address_Space => Address_Space_Cap,
                           Cap           => Buf_Cap,
                           VA            => Buf_Win_VA,
                           Offset        => 0,
                           Length        => 4096,
                           Flags         => 3);
                        if Result /= 0 then
                           Debug_Put_Line
                             ("virtio-blk read window map failed");
                           Rd_St := 1;
                        else
                           for I in 0 .. Natural (Count) - 1 loop
                              if Hit (I) then
                                 Touch (Hit_Slot (I));
                                 for J in 0 .. 511 loop
                                    Buf_Win (I * 512 + J) :=
                                      Cache_Mem
                                        (U64 (Hit_Slot (I)) * 512
                                         + U64 (J));
                                 end loop;
                              end if;
                           end loop;
                           Result := Mem_Unmap
                             (Address_Space => Address_Space_Cap,
                              VA            => Buf_Win_VA,
                              Length        => 4096);
                           if Result /= 0 then
                              Debug_Put_Line
                                ("virtio-blk window unmap failed");
                           end if;
                        end if;
                     end if;

                     Message.Words (0) := (if Rd_St = 0 then 0 else 1);
                     Message.Words (1) := 0;
                     if IPC_Reply (Reply_H) /= IPC_Ok then
                        Debug_Put_Line ("virtio-blk reply failed");
                     end if;
                  end;
               end if;
            end if;

            --  The transferred buffer cap is consumed by the
            --  request; delete it or leak a cap-table slot per RPC.
            if Buf_Cap /= 0 and then Cap_Delete (Buf_Cap) /= 0 then
               Debug_Put_Line ("virtio-blk buffer cap delete failed");
            end if;

         elsif Message.Label = Op_Write then
            Sector  := Message.Words (0);
            Count   := Message.Words (1);
            Buf_Cap := Message.Caps (0);
            --  m75: replies transfer caps; detach the received
            --  buffer cap from the buffer so no reply bounces it.
            Message.Caps := (others => 0);

            if Buf_Cap = 0 or else Count = 0 or else Count > 8
              or else Sector + Count > Capacity
            then
               Message.Words (0) := 3;  --  bad arguments
               Message.Words (1) := 0;
               if IPC_Reply (Reply_H) /= IPC_Ok then
                  Debug_Put_Line ("virtio-blk reply failed");
               end if;
            else
               --  Write-back: copy the sectors into cache slots
               --  through the window and reply — the device
               --  sees them only at eviction, the loop-top
               --  write-behind, or an explicit flush.
               Result := Mem_Map
                 (Address_Space => Address_Space_Cap,
                  Cap           => Buf_Cap,
                  VA            => Buf_Win_VA,
                  Offset        => 0,
                  Length        => 4096,
                  Flags         => 1);
               if Result /= 0 then
                  Message.Words (0) := 1;
                  Message.Words (1) := 0;
                  if IPC_Reply (Reply_H) /= IPC_Ok then
                     Debug_Put_Line ("virtio-blk reply failed");
                  end if;
               else
                  declare
                     Wr_St : U8 := 0;
                     S     : Integer;
                  begin
                     for I in 0 .. Natural (Count) - 1 loop
                        S := Find_Slot (Sector + U64 (I));
                        if S < 0 then
                           S := Alloc_Slot (Sector + U64 (I));
                        end if;
                        if S < 0 then
                           Wr_St := 1;
                           exit;
                        end if;
                        for J in 0 .. 511 loop
                           Cache_Mem (U64 (S) * 512 + U64 (J)) :=
                             Buf_Win (I * 512 + J);
                        end loop;
                        Slot_Dirty (S) := True;
                        Touch (S);
                     end loop;

                     Result := Mem_Unmap
                       (Address_Space => Address_Space_Cap,
                        VA            => Buf_Win_VA,
                        Length        => 4096);
                     if Result /= 0 then
                        Debug_Put_Line
                          ("virtio-blk window unmap failed");
                     end if;

                     Message.Words (0) :=
                       (if Wr_St = 0 then 0 else 1);
                     Message.Words (1) := 0;
                     if IPC_Reply (Reply_H) /= IPC_Ok then
                        Debug_Put_Line ("virtio-blk reply failed");
                     end if;
                  end;
               end if;
            end if;

            --  The transferred buffer cap is consumed by the
            --  request; delete it or leak a cap-table slot per RPC.
            if Buf_Cap /= 0 and then Cap_Delete (Buf_Cap) /= 0 then
               Debug_Put_Line ("virtio-blk buffer cap delete failed");
            end if;

         else
            Message.Words (0) := 3;
            Message.Words (1) := 0;
            Message.Caps := (others => 0);  --  m75
            if IPC_Reply (Reply_H) /= IPC_Ok then
               Debug_Put_Line ("virtio-blk reply failed");
            end if;
         end if;
      end loop;
   end;
end Virtio_Blk;
