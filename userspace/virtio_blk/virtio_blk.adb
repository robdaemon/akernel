with System;
with System.Storage_Elements;
with Interfaces;
with Akernel_User.Console;
with Akernel_User.Syscalls;
with Virtio;
with Virtio.MMIO;
with Virtio.Queues;

--  Virtio block driver (device id 2 over the MMIO transport).
--  Spawned by init's device manager when a virtio,mmio DTB node
--  probes to class 2. Handle ABI (grant order): 1 = console
--  endpoint (Send), 2 = device MMIO cap, 3 = IRQ cap, 4 = block
--  service endpoint (Receive). Unlike the rng driver, completions
--  are IRQ-driven: the IRQ line signals a thread-bound notification
--  object and Ntfn_Wait blocks on it (the InterruptStatus register
--  is ACKed and the PLIC claim completed with IRQ_Ack after every
--  wait so the level-triggered line can fire again).
--
--  Boot self-test against the generated disk image (Makefile
--  disk.img, 2048 sectors):
--    sector 0      = "AKBLKIMG" then 0xA5 fill
--    sector s >= 1 = byte j of (s + j) mod 256
--  then a write/readback round-trip on sector 3. Afterwards the
--  driver serves the block protocol on handle 4:
--    Op 0 info:  -> (status, capacity in sectors)
--    Op 1 read:  (sector, count<=8) + buffer memory-object cap in
--                slot 0 (Manage right; the driver only queries its
--                first frame's PA and DMAs straight into it)
--    Op 2 write: same, buffer -> device
--  Replies carry (status, 0); status 0 = ok, 1 = io error,
--  3 = bad arguments.

procedure Virtio_Blk is
   use Akernel_User.Syscalls;
   use type U64;
   use type Virtio.U16;
   use type Virtio.U32;
   use type Interfaces.Unsigned_8;

   subtype U8 is Interfaces.Unsigned_8;

   Console_EP : constant U64 := 1;
   MMIO_Cap   : constant U64 := 2;
   IRQ_Cap    : constant U64 := 3;
   Svc_EP     : constant U64 := 4;

   MMIO_VA : constant U64 := 16#5000_0000#;
   DMA_VA  : constant U64 := 16#5004_0000#;
   --  DMA object layout: page 0 descriptors, page 1 avail ring,
   --  page 2 used ring, page 3 request header + status byte,
   --  page 4 sector data buffer.
   DMA_Pages : constant U64 := 5;

   Sector_Size : constant := 512;

   --  Virtio-blk request types (virtio 1.2 §5.2).
   Req_Read  : constant Virtio.U32 := 0;
   Req_Write : constant Virtio.U32 := 1;

   --  Block protocol labels (shared with System/Fileserver).
   Op_Info  : constant U64 := 0;
   Op_Read  : constant U64 := 1;
   Op_Write : constant U64 := 2;

   ------------------------------------------------------------------
   --  Device register access over the mapped MMIO page
   ------------------------------------------------------------------

   type Reg_File is array (U64 range 0 .. 1023) of Virtio.U32
     with Volatile_Components;

   Regs : Reg_File
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (MMIO_VA));

   function Reg_Read (Offset : U64) return Virtio.U32 is
   begin
      return Regs (Offset / 4);
   end Reg_Read;

   procedure Reg_Write (Offset : U64; Value : Virtio.U32) is
   begin
      Regs (Offset / 4) := Value;
   end Reg_Write;

   package Dev is new Virtio.MMIO (Reg_Read, Reg_Write);

   ------------------------------------------------------------------

   type Byte_Array is array (Natural range 0 .. 4095) of U8
     with Volatile_Components;

   Data_Page : Byte_Array
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (DMA_VA + 4 * 4096));

   --  Request header page: words 0..1 = type/reserved, words 2..3 =
   --  sector (U64 little-endian), status byte at offset 16.
   type Word_Array is array (Natural range 0 .. 7) of Virtio.U32
     with Volatile_Components;

   Req_Words : Word_Array
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (DMA_VA + 3 * 4096));

   Status_Byte : U8
     with Volatile, Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address
         (DMA_VA + 3 * 4096 + 16));

   ------------------------------------------------------------------

   Result   : U64;
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

      --  Interrupt-driven wait: ACK any pending virtio interrupt
      --  (keeps the level-triggered PLIC line deasserted when idle),
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

   procedure Fail (S : String) is
   begin
      Akernel_User.Console.Put_Line ("FAIL " & S);
      Process_Exit;
   end Fail;

begin
   Akernel_User.Console.Set_Endpoint (Console_EP);

   Result := Map_MMIO
     (Address_Space => Address_Space_Cap,
      Cap           => MMIO_Cap,
      VA            => MMIO_VA,
      Offset        => 0,
      Length        => 4096,
      Flags         => 3);

   if Result /= 0 then
      Debug_Put_Line ("virtio-blk map mmio failed");
      Process_Exit;
   end if;

   if not Dev.Magic_Ok then
      Debug_Put_Line ("virtio-blk bad magic");
      Process_Exit;
   end if;

   if Dev.Version = 1 then
      Debug_Put_Line ("virtio-blk version 1 (legacy)");
      Process_Exit;
   end if;

   if Dev.Version /= 2 then
      Debug_Put_Line ("virtio-blk bad version");
      Process_Exit;
   end if;

   if Dev.Device_ID /= Virtio.Device_Block then
      Debug_Put_Line ("virtio-blk bad device id");
      Process_Exit;
   end if;

   --  Capacity lives in the device config space at 0x100 (U64).
   Capacity := U64 (Regs (16#100# / 4))
     or U64 (Regs (16#104# / 4)) * 16#1_0000_0000#;

   Dev.Reset;
   Dev.Set_Status (Virtio.Status_Acknowledge);
   Dev.Add_Status (Virtio.Status_Driver);
   Dev.Set_Driver_Features (0);
   Dev.Add_Status (Virtio.Status_Features_Ok);

   if (Dev.Status and Virtio.Status_Features_Ok) = 0 then
      Debug_Put_Line ("virtio-blk features rejected");
      Process_Exit;
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

   Virtio.Queues.Initialize
     (Q     => Q,
      Desc  => System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address (DMA_VA)),
      Avail => System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address (DMA_VA + 4096)),
      Used  => System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address (DMA_VA + 2 * 4096)),
      Num   => 8);

   Dev.Queue_Select (0);
   Dev.Queue_Setup
     (Num      => 8,
      Desc_PA  => Desc_PA,
      Avail_PA => Avail_PA,
      Used_PA  => Used_PA);
   Dev.Add_Status (Virtio.Status_Driver_Ok);

   ------------------------------------------------------------------
   --  Self-test against the generated disk image
   ------------------------------------------------------------------

   --  1. Signature sector: "AKBLKIMG" then 0xA5 fill.
   if Do_Request (Req_Read, 0, Data_PA, Sector_Size) /= 0 then
      Fail ("virtio-blk read sector 0 io error");
   end if;

   Ok :=
     Data_Page (0) = 16#41# and then  --  'A'
     Data_Page (1) = 16#4B# and then  --  'K'
     Data_Page (2) = 16#42# and then  --  'B'
     Data_Page (3) = 16#4C# and then  --  'L'
     Data_Page (4) = 16#4B# and then  --  'K'
     Data_Page (5) = 16#49# and then  --  'I'
     Data_Page (6) = 16#4D# and then  --  'M'
     Data_Page (7) = 16#47#;          --  'G'

   if Ok then
      for J in 8 .. Sector_Size - 1 loop
         if Data_Page (J) /= 16#A5# then
            Ok := False;
            exit;
         end if;
      end loop;
   end if;

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

   ------------------------------------------------------------------
   --  Block service loop
   ------------------------------------------------------------------

   Akernel_User.Console.Put_Line ("virtio-blk service online");

   declare
      Sector  : U64;
      Count   : U64;
      Buf_Cap : U64;
      Buf_PA  : U64;
      Dev_St  : U8;
   begin
      loop
         Result := IPC_Recv (Svc_EP);
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
            if IPC_Reply /= IPC_Ok then
               Debug_Put_Line ("virtio-blk reply failed");
            end if;

         elsif Message.Label = Op_Read or else Message.Label = Op_Write then
            Sector  := Message.Words (0);
            Count   := Message.Words (1);
            Buf_Cap := Message.Caps (0);

            if Buf_Cap = 0 or else Count = 0 or else Count > 8
              or else Sector + Count > Capacity
            then
               Message.Words (0) := 3;  --  bad arguments
               Message.Words (1) := 0;
               if IPC_Reply /= IPC_Ok then
                  Debug_Put_Line ("virtio-blk reply failed");
               end if;
            else
               Buf_PA := Mem_Object_PA (Buf_Cap, 0);
               if Buf_PA = 0 then
                  Message.Words (0) := 3;
                  Message.Words (1) := 0;
                  if IPC_Reply /= IPC_Ok then
                     Debug_Put_Line ("virtio-blk reply failed");
                  end if;
               else
                  Dev_St := Do_Request
                    (Op     => (if Message.Label = Op_Read
                                then Req_Read else Req_Write),
                     Sector => Sector,
                     Buf_PA => Buf_PA,
                     Len    => Virtio.U32 (Count) * Sector_Size);
                  Message.Words (0) := (if Dev_St = 0 then 0 else 1);
                  Message.Words (1) := 0;
                  if IPC_Reply /= IPC_Ok then
                     Debug_Put_Line ("virtio-blk reply failed");
                  end if;
               end if;
            end if;

         else
            Message.Words (0) := 3;
            Message.Words (1) := 0;
            if IPC_Reply /= IPC_Ok then
               Debug_Put_Line ("virtio-blk reply failed");
            end if;
         end if;
      end loop;
   end;
end Virtio_Blk;
