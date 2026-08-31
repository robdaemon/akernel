with System;
with System.Storage_Elements;
with Interfaces;
with Akernel_User.Console;
with Akernel_User.Syscalls;
with Virtio;
with Virtio.PCI;
with Virtio.Queues;

--  Virtio 9P driver over the PCI transport (virtio-9p-pci,
--  transitional id 1af4:1009 or modern 1049): exports a host
--  directory into the guest as the Host: volume. Spawned by init's
--  device manager when the PCI bus scan matches a System/Drivers
--  pci line of class 9; when QEMU is launched without -fsdev/-device
--  virtio-9p-pci the device is simply absent and nothing here runs
--  (runtime opt-in via qemu args, no guest-side configuration).
--  Fixed 7-handle PCI driver ABI (grant order): 1 = console
--  endpoint (Send), 2 = common-cfg MMIO cap, 3 = notify MMIO cap,
--  4 = ISR MMIO cap, 5 = device-cfg MMIO cap, 6 = IRQ cap, 7 =
--  service endpoint (Receive). The first message on the service
--  endpoint is the devmgr's driver config (notify_off_multiplier
--  in word 0, IRQ source in word 1, PCI device id in word 2,
--  MSI-X offer in word 3), answered with a status-0 reply.
--
--  The device has a single virtqueue carrying 9P2000.L request/
--  reply exchanges. Every RPC is a two-descriptor chain (the
--  request buffer the device reads, then the reply buffer the
--  device writes), submitted synchronously: one outstanding
--  request at a time, tag 0 (NOTAG for Tversion), completions
--  poll-drained with a bounded spin + Yield loop (the virtio_net
--  Transmit pattern — QEMU's 9p used-ring interrupts are a
--  convenience, not the wakeup mechanism). All 9P integers are
--  little-endian, native on this target.
--
--  9P2000.L session: Tversion (msize 36864, "9P2000.L") then
--  Tattach (fid 0 = the share root, afid NOFID, uname "akernel",
--  aname "/", n_uname NONUNAME) then a root Tgetattr self-test.
--  Fid 0 is kept for the driver's lifetime; file operations
--  (M79b/M79c) walk clones off it per op because the akernel fs
--  protocol is stateless (every op carries a full path).
--
--  DMA object layout (21 pages): pages 0..2 queue rings
--  (desc/avail/used), pages 3..11 request buffer (36 KiB, msize
--  covers a 32 KiB fs buffer-cap payload plus header), pages
--  12..20 reply buffer (36 KiB).

procedure Virtio_9p is
   use Akernel_User.Syscalls;
   use type U64;
   use type Virtio.U8;
   use type Virtio.U16;
   use type Virtio.U32;
   use type Virtio.U64;
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
   --  DMA object: pages 0..2 rings, 3..11 request, 12..20 reply.
   DMA_VA      : constant U64 := 16#5004_0000#;
   DMA_Pages   : constant U64 := 21;
   Tx_Page_Off : constant U64 := 3;
   Rx_Page_Off : constant U64 := 12;
   Buf_Bytes   : constant U64 := 9 * 4096;

   Queue_Num : constant Virtio.U16 := 16;

   --  VIRTIO_9P_F_MOUNT_TAG (feature bit 0): the mount tag string
   --  lives in the device config (tag_len u16 at offset 0, tag
   --  bytes at offset 2). Fits word-0 negotiation.
   Feat_Mount_Tag : constant Virtio.U32 := 1;

   --  9P2000.L message types (reply = request + 1, except errors).
   T_Version : constant U8 := 100;
   R_Version : constant U8 := 101;
   T_Attach  : constant U8 := 104;
   R_Attach  : constant U8 := 105;
   R_Lerror  : constant U8 := 7;
   T_Getattr : constant U8 := 24;
   R_Getattr : constant U8 := 25;

   No_Fid   : constant Virtio.U32 := 16#FFFF_FFFF#;  --  P9_NOFID
   No_Uname : constant Virtio.U32 := 16#FFFF_FFFF#;  --  P9_NONUNAME
   No_Tag   : constant Virtio.U16 := 16#FFFF#;       --  Tversion tag

   --  Returned by Round_Trip for transport-level failures (reply
   --  header malformed, wrong type, timeout) — never a Linux errno.
   Transport_Error : constant Virtio.U32 := 16#FFFF_FFFF#;

   --  P9_GETATTR_BASIC / mode fields used by the self-test.
   Getattr_Basic : constant Virtio.U64 := 16#7FF#;
   Getattr_Mode  : constant Virtio.U64 := 16#001#;
   S_Ifmt        : constant Virtio.U32 := 16#F000#;
   S_Ifdir       : constant Virtio.U32 := 16#4000#;
   Qid_Dir       : constant U8 := 16#80#;

   Msize_Offer : constant Virtio.U32 := Virtio.U32 (Buf_Bytes);

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

   type Byte_File is array (U64 range 0 .. Buf_Bytes - 1) of U8
     with Volatile_Components;

   Tx_Buf : Byte_File
     with Address => To_Addr (DMA_VA + Tx_Page_Off * 4096);
   Rx_Buf : Byte_File
     with Address => To_Addr (DMA_VA + Rx_Page_Off * 4096);

   ------------------------------------------------------------------

   Result   : U64;
   Reply_H  : U64;  --  reply cap of the request being served (m47)
   DMA_Cap  : U64;
   Ntfn_Cap : U64;
   ISR      : Virtio.U32;
   Req_Q    : Virtio.Queues.Queue;

   Ring_PA : array (0 .. 2) of U64 := (others => 0);
   Tx_PA   : U64 := 0;
   Rx_PA   : U64 := 0;

   Msize    : Virtio.U32 := 0;  --  negotiated
   Root_Fid : constant Virtio.U32 := 0;

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
         Debug_Put_Line ("virtio-9p map " & Name & " failed");
         Process_Exit;
      end if;
   end Map_Region;

   --  IRQ housekeeping during a synchronous wait: clear the virtio
   --  cause and complete the PLIC claim (skipped for the virtual
   --  MSI source). The reply itself is found by polling the used
   --  ring, not via the notification.
   procedure Service_Irq is
   begin
      ISR := Dev.Interrupt_Status;
      if ISR /= 0 then
         Dev.ACK_Interrupt (ISR);
      end if;
      Result := IRQ_Ack (IRQ_Cap);
   end Service_Irq;

   ------------------------------------------------------------------
   --  9P request building (little-endian, native)
   ------------------------------------------------------------------

   Req_Len : U64;      --  build cursor into Tx_Buf
   Req_Tag : Virtio.U16;

   procedure Begin_Req (Msg : U8; Tag : Virtio.U16 := 0) is
   begin
      Tx_Buf (0) := 0;  --  size patched by Round_Trip
      Tx_Buf (1) := 0;
      Tx_Buf (2) := 0;
      Tx_Buf (3) := 0;
      Tx_Buf (4) := Msg;
      Tx_Buf (5) := U8 (Tag mod 256);
      Tx_Buf (6) := U8 (Tag / 256);
      Req_Len := 7;
      Req_Tag := Tag;
   end Begin_Req;

   procedure Put8 (V : U8) is
   begin
      Tx_Buf (Req_Len) := V;
      Req_Len := Req_Len + 1;
   end Put8;

   procedure Put16 (V : Virtio.U16) is
   begin
      Put8 (U8 (V mod 256));
      Put8 (U8 (V / 256));
   end Put16;

   procedure Put32 (V : Virtio.U32) is
   begin
      Put16 (Virtio.U16 (V mod 65536));
      Put16 (Virtio.U16 (V / 65536));
   end Put32;

   procedure Put64 (V : Virtio.U64) is
   begin
      Put32 (Virtio.U32 (V mod 16#1_0000_0000#));
      Put32 (Virtio.U32 (V / 16#1_0000_0000#));
   end Put64;

   --  9P string: u16 length, then bytes (no NUL).
   procedure Put_Str (S : String) is
   begin
      Put16 (Virtio.U16 (S'Length));
      for C of S loop
         Put8 (Character'Pos (C));
      end loop;
   end Put_Str;

   ------------------------------------------------------------------
   --  9P reply parsing
   ------------------------------------------------------------------

   Rsp_Pos : U64;      --  parse cursor into Rx_Buf
   Rsp_End : U64;      --  reply size field (validated)

   function Get8 return U8 is
      V : constant U8 := Rx_Buf (Rsp_Pos);
   begin
      Rsp_Pos := Rsp_Pos + 1;
      return V;
   end Get8;

   function Get16 return Virtio.U16 is
      Lo : constant Virtio.U16 := Virtio.U16 (Get8);
   begin
      return Lo + Virtio.U16 (Get8) * 256;
   end Get16;

   function Get32 return Virtio.U32 is
      Lo : constant Virtio.U32 := Virtio.U32 (Get16);
   begin
      return Lo + Virtio.U32 (Get16) * 65536;
   end Get32;

   function Get64 return Virtio.U64 is
      Lo : constant Virtio.U64 := Virtio.U64 (Get32);
   begin
      return Lo + Virtio.U64 (Get32) * 16#1_0000_0000#;
   end Get64;

   ------------------------------------------------------------------
   --  Synchronous RPC: submit the built request, poll-drain the
   --  used ring for the reply. Returns 0 when the reply has the
   --  expected type (Rsp_Pos parked at the payload), the Rlerror
   --  ecode when the server answered with an error, or
   --  Transport_Error for header/timeout failures.
   ------------------------------------------------------------------

   function Round_Trip (Expect : U8) return Virtio.U32 is
      H       : constant Virtio.U16 := Virtio.Queues.Alloc (Req_Q);
      D       : constant Virtio.U16 := Virtio.Queues.Alloc (Req_Q);
      Spins   : Natural;
      Head    : Virtio.U16;
      Written : Virtio.U32 := 0;
      Size    : Virtio.U32;
      Rtype   : U8;
      Rtag    : Virtio.U16;
   begin
      if H = Virtio.No_Desc or else D = Virtio.No_Desc then
         return Transport_Error;
      end if;

      Size := Virtio.U32 (Req_Len);
      Tx_Buf (0) := U8 (Size mod 256);
      Tx_Buf (1) := U8 ((Size / 256) mod 256);
      Tx_Buf (2) := U8 ((Size / 65536) mod 256);
      Tx_Buf (3) := U8 (Size / 16#1_000_000#);

      Virtio.Queues.Set_Buffer
        (Req_Q, H, Tx_PA, Size, Device_Writes => False);
      Virtio.Queues.Chain_Next (Req_Q, H, D);
      Virtio.Queues.Set_Buffer
        (Req_Q, D, Rx_PA, Virtio.U32 (Buf_Bytes), Device_Writes => True);
      Virtio.Queues.Submit (Req_Q, H);
      Dev.Notify (0);

      Spins := 0;
      while not Virtio.Queues.Has_Completed (Req_Q) loop
         Service_Irq;

         Spins := Spins + 1;
         if Spins > 1_000_000 then
            Virtio.Queues.Free (Req_Q, H);
            return Transport_Error;
         end if;

         --  Host-side completion lands in wall-clock time, not CPU
         --  time; drop to the bottom of the run queue between polls.
         if Spins mod 1_000 = 0 then
            Yield;
         end if;
      end loop;

      Virtio.Queues.Pop (Req_Q, Head, Written);
      Virtio.Queues.Free (Req_Q, Head);

      --  Reply header: size[4] type[1] tag[2].
      if Written < 7 then
         return Transport_Error;
      end if;
      Rsp_Pos := 0;
      Size    := Get32;
      Rtype   := Get8;
      Rtag    := Get16;
      if U64 (Size) < 7 or else Size > Written
        or else Rtag /= Req_Tag
      then
         return Transport_Error;
      end if;
      Rsp_End := U64 (Size);

      if Rtype = R_Lerror then
         return Get32;  --  Linux errno
      end if;
      if Rtype /= Expect then
         return Transport_Error;
      end if;
      return 0;
   end Round_Trip;

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
      Debug_Put_Line ("virtio-9p config message missing");
      Process_Exit;
   end if;
   Notify_Mult := Message.Words (0);

   --  MSI-X hand-off from the device manager: Words(3) non-zero and
   --  Caps(0) carries the dedicated vector IRQ cap.
   if Message.Words (3) /= 0 and then Message.Caps (0) /= 0 then
      IRQ_Cap := Message.Caps (0);
      Dev.Enable_MSIX (0);
      Akernel_User.Console.Put_Line ("PASS virtio-9p msix enabled");
   end if;

   Message.Words := (others => 0);
   Message.Caps := (others => 0);  --  m75: replies transfer caps
   if IPC_Reply (Reply_H) /= IPC_Ok then
      Debug_Put_Line ("virtio-9p config reply failed");
      Process_Exit;
   end if;

   if Dev.Num_Queues < 1 then
      Debug_Put_Line ("virtio-9p request queue missing");
      Process_Exit;
   end if;

   Dev.Reset;
   Dev.Set_Status (Virtio.Status_Acknowledge);
   Dev.Add_Status (Virtio.Status_Driver);

   --  Only feature bit 0 (mount tag in the device config) is
   --  negotiated; word 0 suffices for the transitional device.
   if (Dev.Device_Features and Feat_Mount_Tag) /= 0 then
      Dev.Set_Driver_Features (Feat_Mount_Tag);
   else
      Dev.Set_Driver_Features (0);
   end if;
   Dev.Add_Status (Virtio.Status_Features_Ok);

   if (Dev.Status and Virtio.Status_Features_Ok) = 0 then
      Debug_Put_Line ("virtio-9p features rejected");
      Process_Exit;
   end if;

   --  IRQ bookkeeping (completions are polled; the notification
   --  exists so a stray IRQ wakes the service loop instead of
   --  latching).
   Ntfn_Cap := Ntfn_Create;
   if Ntfn_Cap = Syscall_Failed then
      Debug_Put_Line ("virtio-9p ntfn create failed");
      Process_Exit;
   end if;

   Result := Ntfn_Bind_Thread (Ntfn_Cap);
   if Result /= 0 then
      Debug_Put_Line ("virtio-9p ntfn bind thread failed");
      Process_Exit;
   end if;

   Result := IRQ_Bind_Ntfn (IRQ_Cap, Ntfn_Cap, Badge => 1);
   if Result /= 0 then
      Debug_Put_Line ("virtio-9p irq bind failed");
      Process_Exit;
   end if;

   DMA_Cap := Mem_Alloc (DMA_Pages);
   if DMA_Cap = Syscall_Failed then
      Debug_Put_Line ("virtio-9p dma alloc failed");
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
      Debug_Put_Line ("virtio-9p dma map failed");
      Process_Exit;
   end if;

   for P in 0 .. 2 loop
      Ring_PA (P) := Mem_Object_PA (DMA_Cap, U64 (P));
   end loop;
   Tx_PA := Mem_Object_PA (DMA_Cap, Tx_Page_Off);
   Rx_PA := Mem_Object_PA (DMA_Cap, Rx_Page_Off);
   if Ring_PA (0) = 0 or else Tx_PA = 0 or else Rx_PA = 0 then
      Debug_Put_Line ("virtio-9p dma pa query failed");
      Process_Exit;
   end if;

   Virtio.Queues.Initialize
     (Q     => Req_Q,
      Desc  => To_Addr (DMA_VA),
      Avail => To_Addr (DMA_VA + 4096),
      Used  => To_Addr (DMA_VA + 2 * 4096),
      Num   => Queue_Num);

   Dev.Queue_Select (0);
   Dev.Queue_Setup
     (Num      => Virtio.U32 (Queue_Num),
      Desc_PA  => Ring_PA (0),
      Avail_PA => Ring_PA (1),
      Used_PA  => Ring_PA (2));
   Dev.Add_Status (Virtio.Status_Driver_Ok);

   --  Mount tag from the device config (tag_len u16 at offset 0,
   --  tag bytes at offset 2): a boot-log convenience.
   declare
      Tag_Len : constant U64 :=
        U64 (Cfg8 (0)) + U64 (Cfg8 (1)) * 256;
      Tag     : String (1 .. 64);
      Keep    : Natural := 0;
   begin
      for I in 1 .. Tag_Len loop
         exit when Keep = Tag'Last;
         Keep := Keep + 1;
         Tag (Keep) := Character'Val (Cfg8 (1 + I));
      end loop;
      Akernel_User.Console.Put_Line
        ("virtio-9p mount tag '" & Tag (1 .. Keep) & "'");
   end;

   ------------------------------------------------------------------
   --  9P2000.L session bring-up + self-test
   ------------------------------------------------------------------

   declare
      Err : Virtio.U32;
   begin
      --  Version negotiation (tag NOTAG per spec).
      Begin_Req (T_Version, No_Tag);
      Put32 (Msize_Offer);
      Put_Str ("9P2000.L");
      Err := Round_Trip (R_Version);
      if Err /= 0 then
         Fail ("virtio-9p version negotiation failed");
      end if;
      Msize := Get32;
      declare
         Want : constant String := "9P2000.L";
         Vlen : constant Virtio.U16 := Get16;
         Ok   : Boolean := Vlen = 8;
      begin
         for I in 1 .. Natural (Vlen) loop
            if I <= 8 then
               Ok := Ok
                 and then Character'Val (Get8) = Want (I);
            else
               Err := Virtio.U32 (Get8);  --  drain over-long string
            end if;
         end loop;
         if not Ok then
            Fail ("virtio-9p server is not 9P2000.L");
         end if;
      end;
      if Msize < 4096 or else Msize > Msize_Offer then
         Fail ("virtio-9p msize out of range");
      end if;

      --  Attach: fid 0 = share root, no auth, numeric-less uname.
      Begin_Req (T_Attach);
      Put32 (Root_Fid);
      Put32 (No_Fid);
      Put_Str ("akernel");
      Put_Str ("/");
      Put32 (No_Uname);
      Err := Round_Trip (R_Attach);
      if Err /= 0 then
         Fail ("virtio-9p attach failed");
      end if;
      if (Get8 and Qid_Dir) = 0 then
         Fail ("virtio-9p root is not a directory");
      end if;

      --  Root getattr: proves attribute reads and that the export
      --  is a directory (S_IFDIR in the mode field).
      Begin_Req (T_Getattr);
      Put32 (Root_Fid);
      Put64 (Getattr_Basic);
      Err := Round_Trip (R_Getattr);
      if Err /= 0 then
         Fail ("virtio-9p getattr failed");
      end if;
      declare
         Valid : constant Virtio.U64 := Get64;
         Mode  : Virtio.U32;
      begin
         Err := Virtio.U32 (Get8);   --  qid type (already checked)
         Err := Virtio.U32 (Get32);  --  qid version
         Err := Virtio.U32 (Get64);  --  qid path
         Mode := Get32;
         if (Valid and Getattr_Mode) = 0
           or else (Mode and S_Ifmt) /= S_Ifdir
         then
            Fail ("virtio-9p root mode is not a directory");
         end if;
      end;

      Akernel_User.Console.Put_Line ("PASS virtio-9p attach ok");
   end;

   ------------------------------------------------------------------
   --  Service loop (M79a: no file ops yet — everything but IRQ
   --  notifications is answered bad-arguments; M79b/M79c add the
   --  Host: volume protocol here)
   ------------------------------------------------------------------

   Akernel_User.Console.Put_Line ("virtio-9p online");

   loop
      Result := IPC_Recv (Svc_EP, Reply_H);
      if Result /= IPC_Ok then
         Debug_Put_Line ("virtio-9p recv failed");
         Process_Exit;
      end if;

      if Message.Label = Notification_Label then
         --  IRQ notification (synthetic message, NO reply cap):
         --  ack and drain any straggler completion.
         declare
            Head    : Virtio.U16;
            Written : Virtio.U32;
         begin
            Service_Irq;
            while Virtio.Queues.Has_Completed (Req_Q) loop
               Virtio.Queues.Pop (Req_Q, Head, Written);
               Virtio.Queues.Free (Req_Q, Head);
            end loop;
         end;
      else
         Message.Words (0) := 3;  --  bad arguments
         Message.Words (1) := 0;
         Message.Caps := (others => 0);  --  m75
         if IPC_Reply (Reply_H) /= IPC_Ok then
            Debug_Put_Line ("virtio-9p reply failed");
         end if;
      end if;
   end loop;
end Virtio_9p;
