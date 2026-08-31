with System;
with System.Storage_Elements;
with Interfaces;
with Akernel_User.Console;
with Akernel_User.Files;
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
--  Fid 0 is kept for the driver's lifetime; file operations walk
--  clones off it per op because the akernel fs protocol is
--  stateless (every op carries a full path, volume-stripped).
--
--  Host: volume protocol (m79b, the Akernel_User.Files wire ops,
--  dispatched by label 1..18 on the service endpoint): Stat/Open
--  (Twalk + Tgetattr), Read (walk + Tlopen O_RDONLY + Tread
--  chunks, fat32 bounds semantics: offset >= size is
--  Out_Of_Range), ReadDir (walk + Tlopen O_DIRECTORY + Treaddir
--  skip-to-index; "." and ".." hidden; entry size from a real
--  Stat), Volume_Info (Tstatfs), Sync/Close no-op Ok. Write-side
--  ops land in M79c and answer Bad_Args until then. ReadDir and
--  Stat/Open on the root ("" path) hit fid 0 directly — an attach
--  fid is never opened, so it stays walkable.
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

   --  Short selector for the fs wire-protocol constants (no
   --  use-visibility: the package also declares a U64 subtype).
   package Files renames Akernel_User.Files;

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
   T_Statfs  : constant U8 := 8;
   R_Statfs  : constant U8 := 9;
   T_Lopen   : constant U8 := 12;
   R_Lopen   : constant U8 := 13;
   T_Lcreate : constant U8 := 14;
   R_Lcreate : constant U8 := 15;
   T_Getattr : constant U8 := 24;
   R_Getattr : constant U8 := 25;
   T_Setattr : constant U8 := 26;
   R_Setattr : constant U8 := 27;
   T_Readdir : constant U8 := 40;
   R_Readdir : constant U8 := 41;
   T_Mkdir   : constant U8 := 72;
   R_Mkdir   : constant U8 := 73;
   T_Renameat : constant U8 := 74;
   R_Renameat : constant U8 := 75;
   T_Unlinkat : constant U8 := 76;
   R_Unlinkat : constant U8 := 77;
   R_Lerror  : constant U8 := 7;
   T_Version : constant U8 := 100;
   R_Version : constant U8 := 101;
   T_Attach  : constant U8 := 104;
   R_Attach  : constant U8 := 105;
   T_Walk    : constant U8 := 110;
   R_Walk    : constant U8 := 111;
   T_Read    : constant U8 := 116;
   R_Read    : constant U8 := 117;
   T_Write   : constant U8 := 118;
   R_Write   : constant U8 := 119;
   T_Clunk   : constant U8 := 120;
   R_Clunk   : constant U8 := 121;

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

   --  Linux errnos the volume server maps onto protocol statuses
   --  (Map_Errno): ENOENT/ENOTDIR -> Not_Found, transport ->
   --  Not_Ready, everything else (EACCES, EISDIR, E2BIG, ...)
   --  -> Bad_Args.
   Enoent  : constant Virtio.U32 := 2;
   E2big   : constant Virtio.U32 := 7;
   Enotdir : constant Virtio.U32 := 20;

   --  Linux open(2) flags used here.
   O_Rdonly    : constant Virtio.U32 := 0;
   O_Wronly    : constant Virtio.U32 := 1;
   O_Rdwr      : constant Virtio.U32 := 2;
   O_Creat     : constant Virtio.U32 := 16#40#;
   O_Trunc     : constant Virtio.U32 := 16#200#;
   O_Directory : constant Virtio.U32 := 16#1_0000#;

   --  AT_REMOVEDIR for Tunlinkat; P9_SETATTR_SIZE for Tsetattr.
   At_Removedir : constant Virtio.U32 := 16#200#;
   Setattr_Size : constant Virtio.U32 := 16#08#;

   --  Per-op scratch fids (walk targets; the process is
   --  single-threaded so two suffice). Fid 0 is the attach root.
   --  ReadDir stats the matched entry WHILE its directory fid is
   --  open, so the entry stat must use a different fid (a 9P
   --  newfid must be unused).
   Walk_Fid : constant Virtio.U32 := 1;
   Aux_Fid  : constant Virtio.U32 := 2;

   --  Fixed VA window for the per-op client buffer cap (8 pages,
   --  32 KiB — the Akernel_User.Files buffer geometry), mapped,
   --  copied, unmapped and cap-deleted on every Read.
   Buf_Win_VA    : constant U64 := 16#5100_0000#;
   Cli_Buf_Bytes : constant U64 := 8 * 4096;

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

   --  Per-request payload cap for Tread/Treaddir: the smaller of
   --  the client buffer geometry and what fits one negotiated
   --  message. Set after Tversion (Msize >= 4096 guaranteed by the
   --  bring-up check, so this is always positive).
   Io_Chunk : U64 := 0;

   function Shl (Value : U64; Amount : Natural) return U64
     renames Interfaces.Shift_Left;

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

   --  Advance the parse cursor past N unwanted reply bytes.
   procedure Skip (N : U64) is
   begin
      Rsp_Pos := Rsp_Pos + N;
   end Skip;

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

   ------------------------------------------------------------------
   --  Host: volume server (Akernel_User.Files wire ops)
   ------------------------------------------------------------------

   --  Per-op client buffer overlay (valid while mapped).
   type Cli_Bytes is
     array (U64 range 0 .. Cli_Buf_Bytes - 1) of U8
     with Volatile_Components;

   Cli_Buf : Cli_Bytes with Address => To_Addr (Buf_Win_VA);

   --  Map a server-side errno (or Transport_Error) onto a protocol
   --  status.
   function Map_Errno (Err : Virtio.U32) return U64 is
   begin
      if Err = 0 then
         return Files.Status_Ok;
      elsif Err = Enoent or else Err = Enotdir then
         return Files.Status_Not_Found;
      elsif Err = Transport_Error then
         return Files.Status_Not_Ready;
      else
         return Files.Status_Bad_Args;
      end if;
   end Map_Errno;

   --  Unpack a NUL-padded path from message words First .., at
   --  most Max_Len chars (48 for Stat/Open/Rename words 0..5,
   --  32 elsewhere).
   function Path_Of (First : Natural; Max_Len : Natural) return String is
      Name : String (1 .. 48) := (others => Character'Val (0));
      Len  : Natural := 0;
   begin
      for P in 0 .. Max_Len - 1 loop
         declare
            Ch : constant Character :=
              Character'Val (Natural
                ((Message.Words (First + P / 8)
                    / Shl (1, (P mod 8) * 8)) and 16#FF#));
         begin
            exit when Ch = Character'Val (0);
            Len := Len + 1;
            Name (Len) := Ch;
         end;
      end loop;
      return Name (1 .. Len);
   end Path_Of;

   --  Walk Path ('/'-separated, volume-stripped, "" = clone the
   --  root) from Root_Fid onto Fid. Returns 0, a server errno, or
   --  Transport_Error. 9P walks are capped at 16 elements
   --  (P9_MAXWELEM); longer paths are rejected E2BIG (the fs
   --  protocol's 48-char paths can only exceed it with
   --  pathological one-character names). A partial Rwalk (nwqid
   --  short of nwname) means an element did not resolve: ENOENT.
   function Walk_To (Path : String; Fid : Virtio.U32) return Virtio.U32 is
      Elems : Natural := 0;
      I     : Natural := Path'First;
      Err   : Virtio.U32;
   begin
      while I <= Path'Last loop
         if Path (I) /= '/' then
            Elems := Elems + 1;
            while I <= Path'Last and then Path (I) /= '/' loop
               I := I + 1;
            end loop;
         else
            I := I + 1;
         end if;
      end loop;
      if Elems > 16 then
         return E2big;
      end if;

      Begin_Req (T_Walk);
      Put32 (Root_Fid);
      Put32 (Fid);
      Put16 (Virtio.U16 (Elems));
      I := Path'First;
      while I <= Path'Last loop
         if Path (I) /= '/' then
            declare
               S : constant Natural := I;
            begin
               while I <= Path'Last and then Path (I) /= '/' loop
                  I := I + 1;
               end loop;
               Put_Str (Path (S .. I - 1));
            end;
         else
            I := I + 1;
         end if;
      end loop;

      Err := Round_Trip (R_Walk);
      if Err /= 0 then
         return Err;
      end if;
      if Get16 /= Virtio.U16 (Elems) then
         return Enoent;  --  partial walk: element did not resolve
      end if;
      return 0;
   end Walk_To;

   --  Best-effort fid cleanup.
   procedure Clunk (Fid : Virtio.U32) is
   begin
      Begin_Req (T_Clunk);
      Put32 (Fid);
      if Round_Trip (R_Clunk) /= 0 then
         Debug_Put_Line ("virtio-9p clunk failed");
      end if;
   end Clunk;

   --  Tgetattr (P9_GETATTR_BASIC) on an open-or-walked fid.
   function Getattr
     (Fid    : Virtio.U32;
      Size   : out U64;
      Is_Dir : out Boolean) return Virtio.U32
   is
      Err  : Virtio.U32;
      Mode : Virtio.U32;
   begin
      Size   := 0;
      Is_Dir := False;
      Begin_Req (T_Getattr);
      Put32 (Fid);
      Put64 (Getattr_Basic);
      Err := Round_Trip (R_Getattr);
      if Err /= 0 then
         return Err;
      end if;
      --  valid[8] qid[13] mode[4] uid[4] gid[4] nlink[8] rdev[8]
      --  size[8] — only mode and size are consumed.
      Skip (8);                     --  valid
      Skip (1);                     --  qid type
      Skip (4);                     --  qid version
      Skip (8);                     --  qid path
      Mode := Get32;
      Is_Dir := (Mode and S_Ifmt) = S_Ifdir;
      Skip (4);                     --  uid
      Skip (4);                     --  gid
      Skip (8);                     --  nlink
      Skip (8);                     --  rdev
      Size := Get64;
      return 0;
   end Getattr;

   --  Stat a volume-stripped path ("" = the share root, answered
   --  from the attach fid without a walk) using Fid as the walk
   --  scratch (must be an unused fid — see Walk_Fid/Aux_Fid).
   function Stat_Path
     (Path   : String;
      Size   : out U64;
      Is_Dir : out Boolean;
      Fid    : Virtio.U32 := Walk_Fid) return U64
   is
      Err : Virtio.U32;
   begin
      if Path'Length = 0 then
         Err := Getattr (Root_Fid, Size, Is_Dir);
      else
         Err := Walk_To (Path, Fid);
         if Err = 0 then
            Err := Getattr (Fid, Size, Is_Dir);
            Clunk (Fid);
         end if;
      end if;
      return Map_Errno (Err);
   end Stat_Path;

   --  Reply helpers. Every reply zeroes caps (m75: caps transfer
   --  in replies) and unused words (fileserver hygiene rule).
   procedure Reply2 (Status, W1 : U64) is
   begin
      Message.Words := (others => 0);
      Message.Words (0) := Status;
      Message.Words (1) := W1;
      Message.Caps := (others => 0);
      if IPC_Reply (Reply_H) /= IPC_Ok then
         Debug_Put_Line ("virtio-9p reply failed");
      end if;
   end Reply2;

   --  Op_Stat/Op_Open reply: (status, size, 0, 0, is_dir) — word 4
   --  carries is_dir since milestone 64.
   procedure Reply_Stat (Status : U64; Size : U64; Is_Dir : Boolean) is
   begin
      Message.Words := (others => 0);
      Message.Words (0) := Status;
      Message.Words (1) := Size;
      Message.Words (4) := (if Is_Dir then 1 else 0);
      Message.Caps := (others => 0);
      if IPC_Reply (Reply_H) /= IPC_Ok then
         Debug_Put_Line ("virtio-9p reply failed");
      end if;
   end Reply_Stat;

   procedure Handle_Stat_Or_Open is
      Path   : constant String := Path_Of (0, 48);
      Size   : U64;
      Is_Dir : Boolean;
      Status : U64;
   begin
      Status := Stat_Path (Path, Size, Is_Dir);
      if Status /= Files.Status_Ok then
         Size := 0;
         Is_Dir := False;
      end if;
      Reply_Stat (Status, Size, Is_Dir);
   end Handle_Stat_Or_Open;

   --  Op_Read: stat for bounds (fat32 semantics: offset >= size is
   --  Out_Of_Range; directories are Bad_Args), then walk + lopen +
   --  Tread chunks straight into the client buffer. The per-op
   --  buffer cap is mapped, copied, unmapped and cap-deleted
   --  exactly once, on every exit path.
   procedure Handle_Read is
      Offset : constant U64 := Message.Words (0);
      Length : constant U64 := Message.Words (1);
      Buf    : constant U64 := Message.Caps (0);
      Path   : constant String := Path_Of (2, 32);
      Size   : U64 := 0;
      Is_Dir : Boolean := False;
      Status : U64;
      Count  : U64 := 0;
      Mapped : Boolean := False;
      Err    : Virtio.U32;
   begin
      if Buf = 0 then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      Status := Stat_Path (Path, Size, Is_Dir);
      if Status = Files.Status_Ok then
         if Is_Dir then
            Status := Files.Status_Bad_Args;
         elsif Offset >= Size then
            Status := Files.Status_Out_Of_Range;
         else
            Count := U64'Min (Length, Size - Offset);
            Count := U64'Min (Count, Cli_Buf_Bytes);

            Err := Walk_To (Path, Walk_Fid);
            if Err /= 0 then
               Status := Map_Errno (Err);
               Count := 0;
            else
               Begin_Req (T_Lopen);
               Put32 (Walk_Fid);
               Put32 (O_Rdonly);
               Err := Round_Trip (R_Lopen);
               if Err /= 0 then
                  Status := Map_Errno (Err);
                  Count := 0;
               else
                  declare
                     Iounit : Virtio.U32;
                     Got    : U64 := 0;
                     Chunk  : U64;
                     N      : U64;
                  begin
                     --  Rlopen payload: qid[13] iounit[4].
                     Skip (13);
                     Iounit := Get32;

                     if Mem_Map
                          (Address_Space => Address_Space_Cap,
                           Cap           => Buf,
                           VA            => Buf_Win_VA,
                           Offset        => 0,
                           Length        => Cli_Buf_Bytes,
                           Flags         => 3) = 0
                     then
                        Mapped := True;
                        while Got < Count loop
                           Chunk := U64'Min (Count - Got, Io_Chunk);
                           if Iounit /= 0 then
                              Chunk := U64'Min (Chunk, U64 (Iounit));
                           end if;
                           Begin_Req (T_Read);
                           Put32 (Walk_Fid);
                           Put64 (Offset + Got);
                           Put32 (Virtio.U32 (Chunk));
                           Err := Round_Trip (R_Read);
                           exit when Err /= 0;
                           N := U64 (Get32);
                           if N = 0 or else N > Chunk
                             or else Rsp_Pos + N > Rsp_End
                           then
                              exit;  --  EOF or malformed reply
                           end if;
                           for J in 0 .. N - 1 loop
                              Cli_Buf (Got + J) := Rx_Buf (Rsp_Pos + J);
                           end loop;
                           Got := Got + N;
                           exit when N < Chunk;  --  short read = EOF
                        end loop;
                        Count := Got;
                        if Err /= 0 and then Got = 0 then
                           Status := Map_Errno (Err);
                        end if;
                     else
                        Status := Files.Status_Not_Ready;
                        Count := 0;
                     end if;
                  end;
               end if;
               Clunk (Walk_Fid);
            end if;
         end if;
      end if;

      if Mapped
        and then Mem_Unmap
          (Address_Space => Address_Space_Cap,
           VA            => Buf_Win_VA,
           Length        => Cli_Buf_Bytes) /= 0
      then
         Debug_Put_Line ("virtio-9p buffer unmap failed");
      end if;
      --  Buffer caps transferred per op are deleted per op.
      if Cap_Delete (Buf) /= 0 then
         Debug_Put_Line ("virtio-9p buffer cap delete failed");
      end if;
      Reply2 (Status, Count);
   end Handle_Read;

   --  Op_ReadDir (stateless, by-index): open the directory and
   --  Treaddir from offset 0, skipping to the requested index
   --  ("." and ".." are hidden). Entry size comes from a real
   --  Stat of the full path (the dirent carries none). Host
   --  names longer than the 24-char reply field are truncated.
   procedure Handle_Read_Dir is
      Path  : constant String := Path_Of (0, 32);
      Index : constant U64 := Message.Words (4);
      Err   : Virtio.U32;
      Seen  : U64 := 0;
      Off   : U64 := 0;
      Found : Boolean := False;
      EDir  : Boolean := False;
      ESize : U64 := 0;
      EName : String (1 .. 24) := (others => Character'Val (0));
      ELen  : Natural := 0;
   begin
      Err := Walk_To (Path, Walk_Fid);
      if Err /= 0 then
         Reply2 (Map_Errno (Err), 0);
         return;
      end if;
      Begin_Req (T_Lopen);
      Put32 (Walk_Fid);
      Put32 (O_Rdonly or O_Directory);
      Err := Round_Trip (R_Lopen);
      if Err /= 0 then
         Clunk (Walk_Fid);
         Reply2 (Map_Errno (Err), 0);
         return;
      end if;

      declare
         N      : U64;
         P_End  : U64;
         D_Off  : U64 := 0;
         Qtype  : U8;
         Dtype  : U8;
         Nlen   : Natural;
         C      : Character;
      begin
         while not Found loop
            Begin_Req (T_Readdir);
            Put32 (Walk_Fid);
            Put64 (Off);
            Put32 (Virtio.U32 (Io_Chunk));
            Err := Round_Trip (R_Readdir);
            exit when Err /= 0;
            N := U64 (Get32);
            exit when N = 0;  --  end of directory
            if Rsp_Pos + N > Rsp_End then
               Err := Transport_Error;
               exit;
            end if;
            P_End := Rsp_Pos + N;

            while Rsp_Pos < P_End loop
               --  dirent: qid[13] offset[8] type[1] name[s]
               Qtype := Get8;
               Skip (12);
               D_Off := Get64;
               Dtype := Get8;
               Nlen := Natural (Get16);
               if Rsp_Pos + U64 (Nlen) > P_End then
                  Err := Transport_Error;
                  exit;
               end if;
               declare
                  NM   : String (1 .. 48);
                  NL   : Natural := 0;
                  Keep : Natural := 0;
               begin
                  for J in 1 .. Nlen loop
                     C := Character'Val (Get8);
                     if NL < NM'Last then
                        NL := NL + 1;
                        NM (NL) := C;
                     end if;
                  end loop;
                  if NM (1 .. NL) /= "." and then NM (1 .. NL) /= ".." then
                     if Seen = Index then
                        Found := True;
                        EDir  := Dtype = 4
                          or else (Qtype and Qid_Dir) /= 0;
                        Keep  := Natural'Min (NL, EName'Length);
                        ELen  := Keep;
                        EName := (others => Character'Val (0));
                        EName (1 .. Keep) := NM (1 .. Keep);
                        declare
                           Full : constant String :=
                             (if Path'Length = 0
                              then NM (1 .. NL)
                              else Path & "/" & NM (1 .. NL));
                           S2   : U64;
                           D2   : Boolean;
                        begin
                           --  Aux_Fid: the directory's Walk_Fid is
                           --  open here, and a 9P newfid must be
                           --  unused.
                           if Stat_Path (Full, S2, D2, Aux_Fid)
                             = Files.Status_Ok
                           then
                              ESize := S2;
                           end if;
                        end;
                        exit;
                     end if;
                     Seen := Seen + 1;
                  end if;
               end;
               exit when Err = Transport_Error;
            end loop;
            exit when Err /= 0;
            Off := D_Off;
            if Seen > 1_000_000 then
               exit;  --  pathological host directory: give up
            end if;
         end loop;
      end;

      Clunk (Walk_Fid);

      if Found then
         Message.Words := (others => 0);
         Message.Words (0) := Files.Status_Ok;
         Message.Words (1) := ESize;
         Message.Words (2) := (if EDir then 1 else 0);
         for P in 1 .. ELen loop
            Message.Words (3 + (P - 1) / 8) :=
              Message.Words (3 + (P - 1) / 8)
                or Shl (U64 (Character'Pos (EName (P))),
                        ((P - 1) mod 8) * 8);
         end loop;
         Message.Caps := (others => 0);
         if IPC_Reply (Reply_H) /= IPC_Ok then
            Debug_Put_Line ("virtio-9p reply failed");
         end if;
      else
         --  Exhausted without a hit: protocol end-of-enumeration
         --  is Not_Found; a real error maps itself.
         if Err = 0 then
            Reply2 (Files.Status_Not_Found, 0);
         else
            Reply2 (Map_Errno (Err), 0);
         end if;
      end if;
   end Handle_Read_Dir;

   --  Op_Volume_Info: Tstatfs on the root fid ->
   --  (status, total bytes, free bytes, block size).
   procedure Handle_Volume_Info is
      Err     : Virtio.U32;
      Bsize   : Virtio.U64;
      Blocks  : Virtio.U64;
      Bavail  : Virtio.U64;
      Namelen : Virtio.U64;
   begin
      Begin_Req (T_Statfs);
      Put32 (Root_Fid);
      Err := Round_Trip (R_Statfs);
      if Err /= 0 then
         Reply2 (Map_Errno (Err), 0);
         return;
      end if;
      Skip (4);                     --  type
      Bsize  := Virtio.U64 (Get32);
      Blocks := Get64;
      Skip (8);                     --  bfree (bavail reported)
      Bavail := Get64;
      Skip (8);                     --  files
      Skip (8);                     --  ffree
      Skip (8);                     --  fsid
      Namelen := Virtio.U64 (Get32);
      if Bsize = 0 or else Bsize > 16#1_0000_0000# or else Namelen = 0 then
         Reply2 (Files.Status_Not_Ready, 0);
         return;
      end if;
      Message.Words := (others => 0);
      Message.Words (0) := Files.Status_Ok;
      Message.Words (1) := Blocks * Bsize;
      Message.Words (2) := Bavail * Bsize;
      Message.Words (3) := Bsize;
      Message.Caps := (others => 0);
      if IPC_Reply (Reply_H) /= IPC_Ok then
         Debug_Put_Line ("virtio-9p reply failed");
      end if;
   end Handle_Volume_Info;

   --  Split Path into parent (Path (Path'First .. + Parent_Len),
   --  length 0 = root) and final component. Name_Len = 0 marks a
   --  malformed path (trailing slash).
   procedure Split_Path
     (Path       : String;
      Parent_Len : out Natural;
      Name_First : out Natural;
      Name_Len   : out Natural)
   is
      Last_Slash : Natural := 0;
   begin
      for I in Path'Range loop
         if Path (I) = '/' then
            Last_Slash := I;
         end if;
      end loop;
      if Last_Slash = 0 then
         Parent_Len := 0;
         Name_First := Path'First;
      else
         Parent_Len := Last_Slash - Path'First;
         Name_First := Last_Slash + 1;
      end if;
      if Name_First > Path'Last then
         Name_Len := 0;
      else
         Name_Len := Path'Last - Name_First + 1;
      end if;
   end Split_Path;

   --  Op_Write (m79c): arbitrary-offset writes; creates the file
   --  when missing and the parent resolves (fat32 semantics),
   --  rejects sparse writes (offset > size -> Out_Of_Range) and
   --  directories (Bad_Args). The per-op buffer cap is mapped,
   --  copied, unmapped and cap-deleted exactly once on every exit.
   procedure Handle_Write is
      Offset : constant U64 := Message.Words (0);
      Length : constant U64 := Message.Words (1);
      Buf    : constant U64 := Message.Caps (0);
      Path   : constant String := Path_Of (2, 32);
      Size   : U64 := 0;
      Is_Dir : Boolean := False;
      Status : U64 := Files.Status_Ok;
      Count  : U64 := 0;
      Mapped : Boolean := False;
      Held   : Boolean := False;  --  Walk_Fid is live
      Opened : Boolean := False;
      Iounit : Virtio.U32 := 0;
      Err    : Virtio.U32;
   begin
      if Buf = 0 then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      Err := Walk_To (Path, Walk_Fid);
      if Err = Enoent or else Err = Enotdir then
         --  Create: walk the parent, Tlcreate the final component
         --  (the fid becomes the new open file).
         declare
            Parent_Len : Natural;
            Name_First : Natural;
            Name_Len   : Natural;
         begin
            Split_Path (Path, Parent_Len, Name_First, Name_Len);
            if Name_Len = 0 then
               Status := Files.Status_Bad_Args;
               Err    := Transport_Error;
            else
               Err := Walk_To
                 (Path (Path'First .. Path'First + Parent_Len - 1),
                  Walk_Fid);
               if Err = 0 then
                  Held := True;
                  Begin_Req (T_Lcreate);
                  Put32 (Walk_Fid);
                  Put_Str (Path (Name_First .. Name_First + Name_Len - 1));
                  Put32 (O_Rdwr or O_Creat or O_Trunc);
                  Put32 (8#644#);
                  Put32 (0);  --  gid (security_model=none ignores)
                  Err := Round_Trip (R_Lcreate);
                  if Err = 0 then
                     Opened := True;
                     Skip (13);           --  qid
                     Iounit := Get32;
                  end if;
               end if;
            end if;
         end;
      elsif Err = 0 then
         Held := True;
         Err := Getattr (Walk_Fid, Size, Is_Dir);
         if Err /= 0 then
            null;  --  mapped below
         elsif Is_Dir then
            Status := Files.Status_Bad_Args;
            Err    := Transport_Error;
         elsif Offset > Size then
            --  No sparse writes (fat32 semantics).
            Status := Files.Status_Out_Of_Range;
            Err    := Transport_Error;
         else
            Begin_Req (T_Lopen);
            Put32 (Walk_Fid);
            Put32 (O_Wronly);
            Err := Round_Trip (R_Lopen);
            if Err = 0 then
               Opened := True;
               Skip (13);                 --  qid
               Iounit := Get32;
            end if;
         end if;
      end if;

      if Opened then
         if Mem_Map
              (Address_Space => Address_Space_Cap,
               Cap           => Buf,
               VA            => Buf_Win_VA,
               Offset        => 0,
               Length        => Cli_Buf_Bytes,
               Flags         => 3) = 0
         then
            Mapped := True;
            declare
               Chunk : U64;
               N     : U64;
            begin
               while Count < Length loop
                  Chunk := U64'Min (Length - Count, Io_Chunk);
                  if Iounit /= 0 then
                     Chunk := U64'Min (Chunk, U64 (Iounit));
                  end if;
                  Begin_Req (T_Write);
                  Put32 (Walk_Fid);
                  Put64 (Offset + Count);
                  Put32 (Virtio.U32 (Chunk));
                  for J in 0 .. Chunk - 1 loop
                     Put8 (Cli_Buf (Count + J));
                  end loop;
                  Err := Round_Trip (R_Write);
                  exit when Err /= 0;
                  N := U64 (Get32);
                  if N = 0 or else N > Chunk then
                     Err := Transport_Error;  --  no forward progress
                     exit;
                  end if;
                  Count := Count + N;
               end loop;
            end;
            if Err /= 0 then
               if Count = 0 then
                  Status := Map_Errno (Err);
               end if;
               --  Partial write: report Ok with the short count.
            end if;
         else
            Status := Files.Status_Not_Ready;
         end if;
      elsif Status = Files.Status_Ok then
         Status := Map_Errno (Err);
      end if;

      if Mapped
        and then Mem_Unmap
          (Address_Space => Address_Space_Cap,
           VA            => Buf_Win_VA,
           Length        => Cli_Buf_Bytes) /= 0
      then
         Debug_Put_Line ("virtio-9p buffer unmap failed");
      end if;
      if Held then
         Clunk (Walk_Fid);
      end if;
      --  Buffer caps transferred per op are deleted per op.
      if Cap_Delete (Buf) /= 0 then
         Debug_Put_Line ("virtio-9p buffer cap delete failed");
      end if;
      Reply2 (Status, Count);
   end Handle_Write;

   --  Op_Delete / Op_Rmdir (m79c): Tunlinkat on the parent fid,
   --  flags 0 (file) / AT_REMOVEDIR (empty directory). Host
   --  errnos do the type policing: a directory via Op_Delete is
   --  EISDIR, a non-empty directory via Op_Rmdir is ENOTEMPTY —
   --  both land as Bad_Args.
   procedure Handle_Unlink (Directory : Boolean) is
      Path       : constant String := Path_Of (0, 48);
      Parent_Len : Natural;
      Name_First : Natural;
      Name_Len   : Natural;
      Err        : Virtio.U32;
   begin
      Split_Path (Path, Parent_Len, Name_First, Name_Len);
      if Name_Len = 0 then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;
      Err := Walk_To
        (Path (Path'First .. Path'First + Parent_Len - 1), Walk_Fid);
      if Err = 0 then
         Begin_Req (T_Unlinkat);
         Put32 (Walk_Fid);
         Put_Str (Path (Name_First .. Name_First + Name_Len - 1));
         Put32 ((if Directory then At_Removedir else 0));
         Err := Round_Trip (R_Unlinkat);
         Clunk (Walk_Fid);
      end if;
      Reply2 (Map_Errno (Err), 0);
   end Handle_Unlink;

   --  Op_Mkdir (m79c): Tmkdir on the parent fid, mode 0755.
   procedure Handle_Mkdir is
      Path       : constant String := Path_Of (0, 48);
      Parent_Len : Natural;
      Name_First : Natural;
      Name_Len   : Natural;
      Err        : Virtio.U32;
   begin
      Split_Path (Path, Parent_Len, Name_First, Name_Len);
      if Name_Len = 0 then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;
      Err := Walk_To
        (Path (Path'First .. Path'First + Parent_Len - 1), Walk_Fid);
      if Err = 0 then
         Begin_Req (T_Mkdir);
         Put32 (Walk_Fid);
         Put_Str (Path (Name_First .. Name_First + Name_Len - 1));
         Put32 (8#755#);
         Put32 (0);  --  gid
         Err := Round_Trip (R_Mkdir);
         Clunk (Walk_Fid);
      end if;
      Reply2 (Map_Errno (Err), 0);
   end Handle_Mkdir;

   --  Op_Truncate (m79c): Tsetattr SIZE 0 on the walked fid.
   procedure Handle_Truncate is
      Path : constant String := Path_Of (0, 48);
      Err  : Virtio.U32;
   begin
      Err := Walk_To (Path, Walk_Fid);
      if Err = 0 then
         Begin_Req (T_Setattr);
         Put32 (Walk_Fid);
         Put32 (Setattr_Size);
         Put32 (0);        --  mode
         Put32 (0);        --  uid
         Put32 (0);        --  gid
         Put64 (0);        --  size
         Put64 (0);        --  atime sec/nsec
         Put64 (0);
         Put64 (0);        --  mtime sec/nsec
         Put64 (0);
         Err := Round_Trip (R_Setattr);
         Clunk (Walk_Fid);
      end if;
      Reply2 (Map_Errno (Err), 0);
   end Handle_Truncate;

   --  Op_Rename (m79c): FROM path in words 0..5, cap0 = the
   --  client buffer holding the bare NUL-terminated TO path (the
   --  VFS stripped both volume prefixes and rejected cross-volume
   --  renames). Trenameat between the two parent fids; house
   --  semantics: TO must not exist (Bad_Args), missing FROM or
   --  either parent is Not_Found.
   procedure Handle_Rename is
      Path : constant String := Path_Of (0, 48);
      Buf  : constant U64 := Message.Caps (0);
      Err  : Virtio.U32;
      To   : String (1 .. 255);
      To_Len : Natural := 0;
      F_Parent_Len : Natural;
      F_Name_First : Natural;
      F_Name_Len   : Natural;
      T_Parent_Len : Natural;
      T_Name_First : Natural;
      T_Name_Len   : Natural;
      T_Size : U64;
      T_Dir  : Boolean;
   begin
      if Buf = 0 then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      --  Pull the TO path out of the transferred buffer, then
      --  release the cap like every other per-op buffer.
      if Mem_Map
           (Address_Space => Address_Space_Cap,
            Cap           => Buf,
            VA            => Buf_Win_VA,
            Offset        => 0,
            Length        => Cli_Buf_Bytes,
            Flags         => 3) = 0
      then
         for I in U64 (0) .. Cli_Buf_Bytes - 1 loop
            exit when Cli_Buf (I) = 0 or else To_Len = To'Last;
            To_Len := To_Len + 1;
            To (To_Len) := Character'Val (Cli_Buf (I));
         end loop;
         if Mem_Unmap
              (Address_Space => Address_Space_Cap,
               VA            => Buf_Win_VA,
               Length        => Cli_Buf_Bytes) /= 0
         then
            Debug_Put_Line ("virtio-9p buffer unmap failed");
         end if;
      end if;
      if Cap_Delete (Buf) /= 0 then
         Debug_Put_Line ("virtio-9p buffer cap delete failed");
      end if;

      if To_Len = 0 then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      --  TO must not exist (fat32 semantics).
      if Stat_Path (To (1 .. To_Len), T_Size, T_Dir)
        = Files.Status_Ok
      then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      Split_Path (Path, F_Parent_Len, F_Name_First, F_Name_Len);
      Split_Path (To (1 .. To_Len),
                  T_Parent_Len, T_Name_First, T_Name_Len);
      if F_Name_Len = 0 or else T_Name_Len = 0 then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      Err := Walk_To
        (Path (Path'First .. Path'First + F_Parent_Len - 1),
         Walk_Fid);
      if Err = 0 then
         Err := Walk_To
           (To (1 .. T_Parent_Len), Aux_Fid);
         if Err /= 0 then
            Clunk (Walk_Fid);
         end if;
      end if;
      if Err = 0 then
         Begin_Req (T_Renameat);
         Put32 (Walk_Fid);
         Put_Str (Path (F_Name_First .. F_Name_First + F_Name_Len - 1));
         Put32 (Aux_Fid);
         Put_Str (To (T_Name_First .. T_Name_First + T_Name_Len - 1));
         Err := Round_Trip (R_Renameat);
         Clunk (Walk_Fid);
         Clunk (Aux_Fid);
      end if;
      Reply2 (Map_Errno (Err), 0);
   end Handle_Rename;

   --  fs wire-op dispatch (label, never badge — forwarded ops can
   --  carry pid badges; nothing here assumes badge 0).
   procedure Handle_File_Op is
      L : constant U64 := Message.Label;
   begin
      if L = Files.Op_Stat or else L = Files.Op_Open then
         Handle_Stat_Or_Open;
      elsif L = Files.Op_Read then
         Handle_Read;
      elsif L = Files.Op_Write then
         Handle_Write;
      elsif L = Files.Op_ReadDir then
         Handle_Read_Dir;
      elsif L = Files.Op_Volume_Info then
         Handle_Volume_Info;
      elsif L = Files.Op_Delete then
         Handle_Unlink (Directory => False);
      elsif L = Files.Op_Rmdir then
         Handle_Unlink (Directory => True);
      elsif L = Files.Op_Mkdir then
         Handle_Mkdir;
      elsif L = Files.Op_Truncate then
         Handle_Truncate;
      elsif L = Files.Op_Rename then
         Handle_Rename;
      elsif L = Files.Op_Sync or else L = Files.Op_Close then
         Reply2 (Files.Status_Ok, 0);
      else
         --  Set_Name/Add_Block/Add_FS/Assign* are fs-internal and
         --  never forwarded.
         Reply2 (Files.Status_Bad_Args, 0);
      end if;
   end Handle_File_Op;

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
      Io_Chunk := U64'Min (Cli_Buf_Bytes, U64 (Msize) - 24);

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
   --  Service loop: IRQ notifications (drain stragglers) plus the
   --  Host: volume protocol (fs wire ops 1..18, forwarded by the
   --  file server).
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
      elsif Message.Label >= Files.Op_Stat
        and then Message.Label <= Files.Op_Close
      then
         Handle_File_Op;
      else
         Reply2 (Files.Status_Bad_Args, 0);
      end if;
   end loop;
end Virtio_9p;
