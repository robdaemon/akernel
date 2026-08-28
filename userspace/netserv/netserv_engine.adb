with Interfaces;
with System;
with System.Machine_Code;
with System.Storage_Elements;
with Akernel_User.Console;
with Akernel_User.Syscalls;
with Akernel_User.Files;

--  Netserv (milestones 71b/71c/72): the IPv4 network stack server.
--  Sits between Drivers/VirtioNet (frame protocol: Op_Info /
--  Op_Tx / Op_Set_Rx ring+ntfn) and network clients. m71b/m71c
--  built the protocol surface on a hand-rolled ARP/IPv4/ICMP/UDP
--  engine; m72b swapped the internals for vendored lwIP 2.2.1
--  (NO_SYS raw API) while keeping every client-visible protocol
--  byte-identical: the ring pairs, ops 20..25/40, badges, the
--  Net: volume files, and the error semantics all behave exactly
--  as m71c specified. The lwIP boundary lives in
--  userspace/lwip/port/aknet_glue.c:
--
--  - one netif, netmask /0 (the m71c stack had no routing and
--    ARPed every destination directly; a /0 mask makes lwIP's
--    ip4_route do the same — slirp's network is flat),
--  - linkoutput marshals pbufs into the TX staging page and calls
--    aknet_frame_tx (below) for the driver Op_Tx,
--  - the hairpin (dst == our own address) is intercepted at the IP
--    layer in the glue's netif->output wrapper (lwIP keeps no ARP
--    entry for ourselves) and fed back into ip4_input,
--  - UDP sockets are udp_pcbs keyed by socket id; ping sockets and
--    Op_Ping share one raw ICMP pcb,
--  - the m71c sticky "ARP resolve failed" error has no lwIP
--    counterpart, so a small pending-resolve tracker (2 s deadline,
--    checked on the ticker tick) reproduces it,
--  - lwIP timers run off a ticker thread that signals the bound
--    notification bit 2 every 50 ms; the service loop then calls
--    sys_check_timeouts and the pending tracker.
--
--  Grant layout (manifest "program 10 System/Netserv console fs
--  netdev net_server net_register"):
--    1 = console Send, 2 = file server Send (ENV:Net.* config
--    overrides), 3 = netdev Send (the class-1 driver's frame
--    service, kept by the device manager), 4 = net_server Receive
--    (this server's service endpoint; the net token grants clients
--    its Send side), 5 = net_register Send+Transfer (used once to
--    self-register the Net: volume at the end of bring-up — the
--    Receive-only handle 4 cannot mint a Send cap for the fs).
--
--  Static config: 10.0.2.15 with gateway 10.0.2.2 and DNS
--  10.0.2.3 (QEMU slirp), overridable via ENV:Net.Address /
--  ENV:Net.Gateway / ENV:Net.DNS (dotted decimal) at boot and
--  via the writable Net: files at runtime (address/gateway writes
--  reprogram the netif).
--
--  Op_Ping (label 40): word0 = target IPv4 packed big-endian in
--  the low 32 bits (10.0.2.2 = 16#0A00_0202#) -> (status, rtt);
--  status 0 ok, 1 no reply (ARP or echo timeout), 3 bad args.
--  RTT is in Read_Time ticks (10 MHz). Pinging our own address
--  short-circuits ok/0. The handler sends an echo request over
--  the shared raw pcb and waits for the reply by poll-draining
--  the RX ring (bounded by a wall-clock deadline); other requests
--  queue on the endpoint meanwhile.
--
--  Sockets (m71c): Op_Socket=20 on the raw service cap (badge 0)
--  — words (domain, type, proto), cap0 = a two-page ring-pair
--  memobj, cap1 = the client's ntfn — replies (status, socket
--  id); caps do not travel in IPC replies in this kernel, so the
--  client mints its own cap on the service endpoint with badge =
--  socket id and the ops then ride that mint: Op_Bind=21 (word0
--  = port, 0 = ephemeral -> assigned), Op_Connect=22 (word0 =
--  IPv4 BE low 32, word1 = port: default peer + RX filter),
--  Op_Kick=23 (one-way send: TX ring dirty), Op_Poll=24 ->
--  (status, rx level, tx free, sticky error), Op_Close=25.
--  Ring-pair layout: page 0 = RX ring (server produces), page 1
--  = TX ring (client produces); each ring is word0 head / word1
--  tail / word2 dropped / word3 reserved, 4 slots of 1008 bytes
--  at offset 64: len:u16, flags:u16, addr:u32, port:u32, up to
--  996 payload bytes. The server signals the client ntfn bit 0
--  on RX enqueue, bit 1 when the sticky error word is set. UDP
--  to a closed local port draws an ICMP port-unreachable off the
--  wire (lwIP's udp_input sends it) — or, for a hairpin (dst =
--  our own address), an Ada-side precheck sets the sender's error
--  word instead (m71c semantics). ICMP ping sockets (proto 1):
--  the client queues an echo request message, netserv overwrites
--  the ident with the socket id, recomputes the checksum, owns
--  the IP header, and matches echo replies back by ident. Badges
--  are not authority here: any holder of the net cap can mint any
--  badge (the pid badges the file server forwards are equally
--  self-asserted); the table merely demultiplexes.
--
--  RX ring (shared with the driver, mapped here RW): word0 head
--  (driver), word1 tail (us), word2 dropped, word3 slot count;
--  2048-byte slots at offset 4096, slot = u16 little-endian
--  length then frame bytes.

package body Netserv_Engine is
   subtype U64 is Interfaces.Unsigned_64;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U16 is Interfaces.Unsigned_16;
   subtype U8  is Interfaces.Unsigned_8;
   subtype Int is Interfaces.Integer_32;
   use type U64;
   use type U32;
   use type U16;
   use type U8;
   use type Int;
   use type System.Address;

   package Syscalls renames Akernel_User.Syscalls;
   package Console renames Akernel_User.Console;
   package Files renames Akernel_User.Files;

    Console_EP : constant U64 := 1;
    FS_Cap     : constant U64 := 2;
    Netdev_EP  : constant U64 := 3;
    Svc_EP     : constant U64 := 4;
    Reg_Cap    : constant U64 := 5;

    --  Driver frame protocol (mirror of virtio_net handle 7).
    Drv_Op_Info   : constant U64 := 0;
    Drv_Op_Tx     : constant U64 := 1;
    Drv_Op_Set_Rx : constant U64 := 2;

    --  Client-facing ops on the service endpoint (file protocol
    --  labels 0..18 are answered for the Net: volume).
    Op_Socket  : constant U64 := 20;
    Op_Bind    : constant U64 := 21;
    Op_Connect : constant U64 := 22;
    Op_Kick    : constant U64 := 23;
    Op_Poll    : constant U64 := 24;
    Op_Close   : constant U64 := 25;
    Op_Ping    : constant U64 := 40;

    AF_INET    : constant U64 := 2;
    SOCK_DGRAM : constant U64 := 2;

    Status_Ok        : constant U64 := 0;
    Status_Not_Found : constant U64 := 1;
    Status_Not_Ready : constant U64 := 2;
    Status_Bad_Args  : constant U64 := 3;
    Status_Out_Of_Range : constant U64 := 4;

   --  Op_Ping statuses: 0 ok, 1 no reply, 3 bad args (shared with
   --  the file protocol above).
   Ping_No_Reply : constant U64 := 1;

   --  Time base: Read_Time ticks at 10 MHz (runtime convention).
   Tick_Hz      : constant U64 := 10_000_000;
   Arp_Timeout  : constant U64 := 2 * Tick_Hz;
   Ping_Timeout : constant U64 := 5 * Tick_Hz;

    --  Fixed VA windows (below the IPC buffer at 16#6FFF_0000#,
    --  clear of the Files client buffer at 16#4400_0000#):
    --  16#5400_0000# driver RX ring (5 pages), 16#5410_0000# TX
    --  staging (1 page), 16#5420_0000# + (id-1)*1 MiB the eight
    --  socket ring pairs (2 pages each), 16#54A0_0000# the Net:
    --  volume client-buffer window (8 pages). m72b adds the
    --  ticker thread at 16#54B0_0000# (stack) / 16#54C0_0000#
    --  (IPC buffer) / 16#54D0_0000# (TLS).
    Ring_VA    : constant U64 := 16#5400_0000#;
    Ring_Pages : constant U64 := 5;   --  4 KiB header + 8 slots
    Ring_Bytes : constant U64 := Ring_Pages * Syscalls.Page_Size;
    Tx_VA      : constant U64 := 16#5410_0000#;
    Sock_VA_Base   : constant U64 := 16#5420_0000#;
    Sock_VA_Stride : constant U64 := 16#10_0000#;
    Buf_Win_VA     : constant U64 := 16#54A0_0000#;
    Buf_Bytes      : constant U64 := 8 * Syscalls.Page_Size;
    Ticker_Stack_Top : constant U64 := 16#54B0_1000#;
    Ticker_IPC_VA    : constant U64 := 16#54C0_0000#;
    Ticker_TLS_VA    : constant U64 := 16#54D0_0000#;

    --  Bound-notification signal bits: bit 0 = driver RX kick
    --  (virtio_net signals the value 1), bit 2 = 50 ms ticker.
    Signal_Rx   : constant U64 := 1;
    Signal_Tick : constant U64 := 4;

    Proto_Icmp : constant U8 := 1;
    Proto_Udp  : constant U8 := 17;

   function To_Addr (VA : U64) return System.Address is
     (System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (VA)));

   function To_VA (A : System.Address) return U64 is
     (U64 (System.Storage_Elements.To_Integer (A)));

    function Shr
      (Value : U64; Amount : Natural) return U64
      renames Interfaces.Shift_Right;

    function Shl
      (Value : U64; Amount : Natural) return U64
      renames Interfaces.Shift_Left;

   ------------------------------------------------------------------
   --  Shared-memory overlays
   ------------------------------------------------------------------

   type Byte_Span is array (U64 range <>) of U8
     with Volatile_Components;

   type Ring_Words is array (U64 range 0 .. 7) of U64
     with Volatile_Components;

   Ring_Hdr : Ring_Words with Address => To_Addr (Ring_VA);
   Ring_Mem : Byte_Span (0 .. Ring_Bytes - 1)
     with Address => To_Addr (Ring_VA);
   Tx_Mem   : Byte_Span (0 .. Syscalls.Page_Size - 1)
     with Address => To_Addr (Tx_VA);

   ------------------------------------------------------------------
   --  lwIP glue imports (userspace/lwip/port/aknet_glue.c; the
   --  library project is with'ed by netserv.gpr)
   ------------------------------------------------------------------

   procedure Lwip_Init
     with Import, Convention => C, External_Name => "lwip_init";

   procedure Aknet_Setup
     (Mac : System.Address; Ip : U32; Gw : U32; Mtu : U32)
     with Import, Convention => C, External_Name => "aknet_setup";

   procedure Aknet_Set_Addr (Ip : U32; Gw : U32)
     with Import, Convention => C, External_Name => "aknet_set_addr";

   function Aknet_Rx (Frame : System.Address; Len : U32) return Int
     with Import, Convention => C, External_Name => "aknet_rx";

   function Aknet_Udp_New (Id : U32) return System.Address
     with Import, Convention => C, External_Name => "aknet_udp_new";

   function Aknet_Udp_Bind
     (Pcb : System.Address; Port : U32) return Int
     with Import, Convention => C, External_Name => "aknet_udp_bind";

   function Aknet_Udp_Connect
     (Pcb : System.Address; Ip : U32; Port : U32) return Int
     with Import, Convention => C,
          External_Name => "aknet_udp_connect";

   function Aknet_Udp_Send
     (Pcb  : System.Address;
      Ip   : U32;
      Port : U32;
      Data : System.Address;
      Len  : U32) return Int
     with Import, Convention => C, External_Name => "aknet_udp_send";

   procedure Aknet_Udp_Del (Pcb : System.Address)
     with Import, Convention => C, External_Name => "aknet_udp_del";

   function Aknet_Raw_Icmp_New return System.Address
     with Import, Convention => C,
          External_Name => "aknet_raw_icmp_new";

   function Aknet_Raw_Send
     (Pcb  : System.Address;
      Ip   : U32;
      Data : System.Address;
      Len  : U32) return Int
     with Import, Convention => C, External_Name => "aknet_raw_send";

   function Aknet_Arp_Resolved (Ip : U32) return Int
     with Import, Convention => C,
          External_Name => "aknet_arp_resolved";

   function Aknet_Arp_Get
     (I : U32; Ip : System.Address; Mac : System.Address) return Int
     with Import, Convention => C, External_Name => "aknet_arp_get";

   procedure Aknet_Check_Timeouts
     with Import, Convention => C, External_Name => "aknet_timeouts";

   ------------------------------------------------------------------
   --  Configuration and state
   ------------------------------------------------------------------

   type Mac_Addr is array (0 .. 5) of U8;

   My_IP      : U32 := 16#0A00_020F#;  --  10.0.2.15
   Gateway_IP : U32 := 16#0A00_0202#;  --  10.0.2.2
   DNS_IP     : U32 := 16#0A00_0203#;  --  10.0.2.3
   Our_Mac    : Mac_Addr := (others => 0);
   MTU        : U64 := 1500;

   Reply_H    : U64;
   Ring_Cap   : U64;
   Tx_Cap     : U64;
   Tx_Mint    : U64;
   Ntfn_Cap   : U64;
   Ring_Slots : U64 := 0;

    --  Outstanding Op_Ping (the single-threaded loop guarantees at
    --  most one). The shared raw ICMP pcb also serves the ping
    --  sockets; replies are dispatched by ident (Ping_Ident is
    --  distinct from every socket id). m72b: the op no longer
    --  spins in the service loop; Ping_Reply_H stashes the client's
    --  one-shot reply cap until the raw callback lands or the
    --  timeout (Ping_Limit) expires.
    Ping_Pending : Boolean := False;
    Ping_Ident   : U32 := 16#4E41#;  --  "NA"
    Ping_Seq     : U32 := 0;
    Ping_Target  : U32 := 0;
    Ping_T0      : U64 := 0;
    Ping_Rtt     : U64 := 0;
    Ping_Reply_H : U64 := 0;
    Ping_Limit   : U64 := 0;
    Raw_Pcb      : System.Address := System.Null_Address;

    --  Counters surfaced via Net:status.
    Rx_Frames : U64 := 0;
    Tx_Frames : U64 := 0;

    --  Socket table (m71c): 8 slots is generous for a CLI box —
    --  ping holds one briefly, a future DNS resolver one. Ring
    --  pairs map at Sock_VA_Base + (id-1)*Sock_VA_Stride (2 pages
    --  each; the stride leaves room and keeps the windows
    --  literal). Ring_Cap/Ntfn_Cap are the transferred copies
    --  from Op_Socket, kept to pin the frames and the signal
    --  target; both are deleted (and the window unmapped) on
    --  Op_Close. Error is sticky until close: 1 = hairpin to a
    --  closed port, 2 = ARP resolve failed, 3 = usage error.
    --  Pcb is the lwIP udp_pcb for proto 17 (ping sockets share
    --  Raw_Pcb and keep Null_Address here).
    Max_Socks : constant := 8;

    type Sock_State is record
       Used       : Boolean := False;
       Proto      : U8 := 0;
       Bound      : Boolean := False;
       Connected  : Boolean := False;
       Local_Port : U32 := 0;
       Peer_IP    : U32 := 0;
       Peer_Port  : U32 := 0;
       Error      : U64 := 0;
       Ring_Cap   : U64 := 0;
       Ntfn_Cap   : U64 := 0;
       Pcb        : System.Address := System.Null_Address;
    end record;

    Socks      : array (1 .. Max_Socks) of Sock_State;
    Next_Ephem : U32 := 49152;

    --  Pending ARP resolves (m72b): lwIP queues an unresolved
    --  datagram on its ARP entry and reports nothing on failure,
    --  so the m71c "ARP resolve failed" sticky error (2 s
    --  deadline) is reproduced by this table, checked on every
    --  ticker wakeup.
    type Pend_Rec is record
       Used     : Boolean := False;
       Sock     : Natural := 0;
       Ip       : U32 := 0;
       Deadline : U64 := 0;
    end record;

    Pend : array (1 .. Max_Socks) of Pend_Rec;

    --  Socket ring-pair layout (per ring, page 0 = RX, 1 = TX).
    Sock_Slots       : constant U64 := 4;
    Sock_Slot_Size   : constant U64 := 1008;
    Sock_Slot_Base   : constant U64 := 64;
    Sock_Max_Payload : constant U64 := 996;
    Sock_Ring_Bytes  : constant U64 := 2 * Syscalls.Page_Size;

    --  TX scratch for ICMP ping-socket sends (the client's
    --  message must be mutated — type/code/ident/checksum —
    --  before the glue copies it into a pbuf).
    Sock_Buf : array (0 .. Sock_Max_Payload - 1) of U8;

    --  Op_Ping's echo request (8-byte header + 8-byte timestamp).
    Ping_Pkt : array (0 .. 15) of U8;

    --  Net:arp render scratch (glue out-params).
    Render_Ip  : aliased U32;
    Render_Mac : aliased Mac_Addr;

   function Sock_VA (Id : Natural) return U64 is
     (Sock_VA_Base + U64 (Id - 1) * Sock_VA_Stride);

   ------------------------------------------------------------------
   --  Small helpers
   ------------------------------------------------------------------

   procedure Fatal (S : String) is
   begin
      Console.Put_Line ("FAIL netserv " & S);
      Syscalls.Process_Exit (1);
   end Fatal;

    procedure Reply_To (Cap : U64; Status : U64; A1 : U64) is
    begin
       Syscalls.Message.Words := (others => 0);
       Syscalls.Message.Words (0) := Status;
       Syscalls.Message.Words (1) := A1;
       Syscalls.Message.Caps := (others => 0);
       if Syscalls.IPC_Reply (Cap) /= Syscalls.IPC_Ok then
          Console.Put_Line ("netserv reply failed");
       end if;
    end Reply_To;

    procedure Reply (Status : U64; A1 : U64) is
    begin
       Reply_To (Reply_H, Status, A1);
    end Reply;

    --  Op_Poll shape: (status, rx level, tx free, sticky error).
    procedure Reply4 (Status, A1, A2, A3 : U64) is
    begin
       Syscalls.Message.Words := (others => 0);
       Syscalls.Message.Words (0) := Status;
       Syscalls.Message.Words (1) := A1;
       Syscalls.Message.Words (2) := A2;
       Syscalls.Message.Words (3) := A3;
       Syscalls.Message.Caps := (others => 0);
       if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
          Console.Put_Line ("netserv reply failed");
       end if;
    end Reply4;

   procedure Fence is
   begin
      System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
   end Fence;

   function Dec (V : U32) return String is
      Digs : String (1 .. 10);
      Len  : Natural := 0;
      X    : U32 := V;
   begin
      if X = 0 then
         return "0";
      end if;
      while X /= 0 loop
         Len := Len + 1;
         Digs (Len) := Character'Val
           (Character'Pos ('0') + Natural (X mod 10));
         X := X / 10;
      end loop;
      return R : String (1 .. Len) do
         for I in 1 .. Len loop
            R (I) := Digs (Len - I + 1);
         end loop;
      end return;
   end Dec;

   function Ip_Image (V : U32) return String is
     (Dec (V / 2 ** 24) & "." & Dec ((V / 2 ** 16) mod 256) & "."
      & Dec ((V / 2 ** 8) mod 256) & "." & Dec (V mod 256));

   Hex_Digit : constant String := "0123456789abcdef";

   function Mac_Image (M : Mac_Addr) return String is
      S : String (1 .. 17);
   begin
      for I in 0 .. 5 loop
         S (I * 3 + 1) := Hex_Digit (Natural (M (I) / 16) + 1);
         S (I * 3 + 2) := Hex_Digit (Natural (M (I) mod 16) + 1);
         if I < 5 then
            S (I * 3 + 3) := ':';
         end if;
      end loop;
      return S;
   end Mac_Image;

   --  Dotted-decimal parse ("10.0.2.15", optional trailing
   --  CR/LF); False on any malformation.
   function Parse_IP (S : String; V : out U32) return Boolean is
      Parts : array (0 .. 3) of U32 := (others => 0);
      P     : Natural := 0;
      Dig   : Boolean := False;
   begin
      for C of S loop
         if C = '.' then
            if not Dig or else P = 3 then
               return False;
            end if;
            P := P + 1;
            Dig := False;
         elsif C in '0' .. '9' then
            Parts (P) := Parts (P) * 10
              + U32 (Character'Pos (C) - Character'Pos ('0'));
            if Parts (P) > 255 then
               return False;
            end if;
            Dig := True;
         elsif C = Character'Val (10) or else C = Character'Val (13) then
            exit;
         else
            return False;
         end if;
      end loop;
      if P /= 3 or else not Dig then
         return False;
      end if;
      V := Parts (0) * 2 ** 24 + Parts (1) * 2 ** 16
        + Parts (2) * 2 ** 8 + Parts (3);
      return True;
   end Parse_IP;

   --  ENV: override: read a dotted-decimal value, keep the
   --  default when the file is absent or unparsable.
   procedure Read_Env_IP (Name : String; Value : in out U32) is
      Buf   : String (1 .. 32);
      Size  : U64 := 0;
      Count : U64 := 0;
      V     : U32;
   begin
      if Files.Open (Name, Size) /= Files.Status_Ok then
         return;
      end if;
      Size := U64'Min (Size, U64 (Buf'Length));
      if Files.Read (Name, 0, Buf'Address, Size, Count)
           /= Files.Status_Ok
        or else Count = 0
      then
         return;
      end if;
      if Parse_IP (Buf (1 .. Natural (Count)), V) then
         Value := V;
      end if;
   end Read_Env_IP;

   --  Ones-complement checksum over Len bytes at VA Base
   --  (big-endian words; odd trailing byte padded with zero).
   --  m72b: only the locally-built ICMP echo requests still need
   --  this; lwIP checksums everything else.
   function Checksum (Base : U64; Len : Natural) return U32 is
      type Bytes is array (Natural range <>) of U8
        with Volatile_Components;
      B   : Bytes (0 .. Len - 1) with Address => To_Addr (Base);
      Sum : U32 := 0;
   begin
      for I in 0 .. Len / 2 - 1 loop
         Sum := Sum + U32 (B (2 * I)) * 256 + U32 (B (2 * I + 1));
      end loop;
      if Len mod 2 = 1 then
         Sum := Sum + U32 (B (Len - 1)) * 256;
      end if;
      while Sum > 16#FFFF# loop
         Sum := (Sum and 16#FFFF#) + Sum / 65536;
      end loop;
      return (not Sum) and 16#FFFF#;
   end Checksum;

   ------------------------------------------------------------------
   --  Transmit path: the glue's linkoutput copies the pbuf chain
   --  into the TX staging page (the driver DMAs page 0 of the
   --  transferred object directly) and calls back for the Op_Tx.
   ------------------------------------------------------------------

    --  Op_Tx: length in word0, staging object (Manage+Transfer
    --  mint, reused) in cap slot 0. Returns the driver status.
    function Send_Frame (Len : U64) return U64 is
    begin
       Syscalls.Message.Label := Drv_Op_Tx;
       Syscalls.Message.Words := (others => 0);
       Syscalls.Message.Words (0) := Len;
       Syscalls.Message.Caps := (0 => Tx_Mint, others => 0);
       if Syscalls.IPC_Call (Netdev_EP) /= Syscalls.IPC_Ok then
          return 1;
       end if;
       Tx_Frames := Tx_Frames + 1;
       return Syscalls.Message.Words (0);
    end Send_Frame;

   --  lwIP linkoutput callback: stage the frame, then transmit.
   function Aknet_Frame_Tx
     (Frame : System.Address; Len : U32) return Int
     with Export, Convention => C, External_Name => "aknet_frame_tx";

   function Aknet_Frame_Tx
     (Frame : System.Address; Len : U32) return Int
   is
      Src : Byte_Span (0 .. U64 (Len) - 1) with Address => Frame;
   begin
      if Len = 0 or else U64 (Len) > Syscalls.Page_Size then
         return 1;
      end if;
      for I in 0 .. U64 (Len) - 1 loop
         Tx_Mem (I) := Src (I);
      end loop;
      if Send_Frame (U64 (Len)) /= 0 then
         return 1;
      end if;
      return 0;
   end Aknet_Frame_Tx;

   ------------------------------------------------------------------
   --  Socket ring pairs (m71c). Page 0 of the socket's window is
   --  the RX ring (we produce, the client consumes); page 1 is
   --  the TX ring (the client produces, Op_Kick makes us drain).
   --  Slots: len:u16, flags:u16, addr:u32, port:u32, payload.
   --  Access goes through per-procedure overlays at the socket's
   --  VA (the windows are per-id literals).
   ------------------------------------------------------------------

   --  Copy Len bytes from Src_VA into socket Id's RX ring and
   --  signal the client (bit 0). A full ring bumps the dropped
   --  counter in word 2 and drops the datagram.
   procedure Enqueue_Rx
     (Id       : Natural;
      Src_IP   : U32;
      Src_Port : U32;
      Src_VA   : U64;
      Len      : U64)
   is
      VA   : constant U64 := Sock_VA (Id);
      N    : U64;
      Head : U64;
      Tail : U64;
      Slot : U64;
   begin
      declare
         Hdr : Ring_Words with Address => To_Addr (VA);
      begin
         Head := Hdr (0);
         Tail := Hdr (1);
      end;
      if Head - Tail >= Sock_Slots then
         declare
            Hdr : Ring_Words with Address => To_Addr (VA);
         begin
            Hdr (2) := Hdr (2) + 1;
         end;
         return;
      end if;
      --  Oversized wire datagrams truncate at the slot payload
      --  (recv semantics); the entry length reports what was
      --  actually stored.
      N := U64'Min (Len, Sock_Max_Payload);
      Slot := VA + Sock_Slot_Base + (Head mod Sock_Slots)
        * Sock_Slot_Size;
      declare
         Mem : Byte_Span (0 .. Sock_Slot_Size - 1)
           with Address => To_Addr (Slot);
         Src : Byte_Span (0 .. N - 1)
           with Address => To_Addr (Src_VA);
      begin
         Mem (0) := U8 (N mod 256);
         Mem (1) := U8 (N / 256);
         Mem (2) := 0;
         Mem (3) := 0;
         for I in 0 .. 3 loop
            Mem (4 + U64 (I)) :=
              U8 (Shr (U64 (Src_IP), (3 - I) * 8) and 16#FF#);
            Mem (8 + U64 (I)) :=
              U8 (Shr (U64 (Src_Port), (3 - I) * 8) and 16#FF#);
         end loop;
         for I in 0 .. N - 1 loop
            Mem (12 + I) := Src (I);
         end loop;
      end;
      Fence;
      declare
         Hdr : Ring_Words with Address => To_Addr (VA);
      begin
         Hdr (0) := Head + 1;
      end;
      if Syscalls.Ntfn_Signal (Socks (Id).Ntfn_Cap, 1) /= 0 then
         Console.Put_Line ("netserv socket signal failed");
      end if;
   end Enqueue_Rx;

   --  Bound UDP socket for a destination port; a connected
   --  socket only matches its peer.
   function Find_Udp_Rx
     (Dst_Port : U32; Src_IP : U32; Src_Port : U32) return Natural
   is
   begin
      for I in 1 .. Max_Socks loop
         if Socks (I).Used
           and then Socks (I).Proto = Proto_Udp
           and then Socks (I).Bound
           and then Socks (I).Local_Port = Dst_Port
           and then (not Socks (I).Connected
                     or else (Socks (I).Peer_IP = Src_IP
                              and then Socks (I).Peer_Port = Src_Port))
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Udp_Rx;

   --  Mark a socket failed and wake its client (bit 1).
   procedure Flag_Error (Id : Natural; Code : U64) is
   begin
      Socks (Id).Error := Code;
      if Syscalls.Ntfn_Signal (Socks (Id).Ntfn_Cap, 2) /= 0 then
         Console.Put_Line ("netserv error signal failed");
      end if;
   end Flag_Error;

   ------------------------------------------------------------------
   --  lwIP RX callbacks (called from the frame drain or, for
   --  hairpinned sends, synchronously out of Drain_Sock_Tx —
   --  always on this same thread).
   ------------------------------------------------------------------

   --  UDP datagram for socket Id (the pcb's recv arg).
   procedure Aknet_On_Udp_Rx
     (Id       : U32;
      Src_IP   : U32;
      Src_Port : U32;
      Data     : System.Address;
      Len      : U32)
     with Export, Convention => C,
          External_Name => "aknet_on_udp_rx";

   procedure Aknet_On_Udp_Rx
     (Id       : U32;
      Src_IP   : U32;
      Src_Port : U32;
      Data     : System.Address;
      Len      : U32)
   is
   begin
      if Id >= 1 and then Id <= U32 (Max_Socks)
        and then Socks (Natural (Id)).Used
        and then Socks (Natural (Id)).Proto = Proto_Udp
      then
         Enqueue_Rx (Natural (Id), Src_IP, Src_Port,
                     To_VA (Data), U64 (Len));
      end if;
   end Aknet_On_Udp_Rx;

   --  Raw ICMP message (the whole ICMP payload). Returns nonzero
   --  when consumed; echo requests (type 8) must fall through so
   --  lwIP's icmp_input answers them (m71c's echo responder).
   function Aknet_On_Icmp_Rx
     (Src_IP : U32; Data : System.Address; Len : U32) return Int
     with Export, Convention => C,
          External_Name => "aknet_on_icmp_rx";

   function Aknet_On_Icmp_Rx
     (Src_IP : U32; Data : System.Address; Len : U32) return Int
   is
      VA : constant U64 := To_VA (Data);
      Id : Natural;
   begin
      if Len < 8 or else Checksum (VA, Natural (Len)) /= 0 then
         return 0;
      end if;
      declare
         Mem   : Byte_Span (0 .. U64 (Len) - 1) with Address => Data;
         Ident : constant U32 := U32 (Mem (4)) * 256 + U32 (Mem (5));
         Seq   : constant U32 := U32 (Mem (6)) * 256 + U32 (Mem (7));
      begin
         if Mem (0) = 0 then
            --  Echo reply: complete the outstanding Op_Ping when
            --  ident/seq/sender match; otherwise the ident is a
            --  socket id (ping sockets mint ident = id) — deliver
            --  the whole ICMP message to that socket.
            if Ping_Pending
              and then Ident = Ping_Ident
              and then Seq = Ping_Seq
              and then Src_IP = Ping_Target
            then
               Ping_Rtt := Syscalls.Read_Time - Ping_T0;
               Ping_Pending := False;
               return 1;
            end if;
            Id := Natural (Ident);
            if Id in 1 .. Max_Socks
              and then Socks (Id).Used
              and then Socks (Id).Proto = Proto_Icmp
            then
               Enqueue_Rx (Id, Src_IP, 0, VA, U64 (Len));
               return 1;
            end if;
         end if;
         return 0;
      end;
   end Aknet_On_Icmp_Rx;

   ------------------------------------------------------------------
   --  Receive path: drain every published frame between tail and
   --  head into lwIP (ethernet_input demuxes ARP/IPv4; UDP and
   --  ICMP land in the callbacks above). Called from the
   --  notification wakeup and from Op_Ping's poll loop.
   ------------------------------------------------------------------

   procedure Drain_Ring is
      Head    : U64;
      Tail    : U64;
      Base    : U64;
      Len     : Natural;
   begin
      loop
         Head := Ring_Hdr (0);
         Tail := Ring_Hdr (1);
         exit when Tail = Head;
         --  The driver fences before signalling; pair it before
         --  reading the slot contents.
         System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
          Base := 4096 + (Tail mod Ring_Slots) * 2048;
          Len := Natural (Ring_Mem (Base))
            + Natural (Ring_Mem (Base + 1)) * 256;
          if Len >= 14 and then Len <= 2046 then
             Rx_Frames := Rx_Frames + 1;
             if Aknet_Rx (To_Addr (Ring_VA + Base + 2), U32 (Len))
                  /= 0
             then
                Console.Put_Line ("netserv rx drop");
             end if;
          end if;
          Ring_Hdr (1) := Tail + 1;
      end loop;
   end Drain_Ring;

   ------------------------------------------------------------------
   --  Pending-ARP tracker (see the state section): reproduces the
   --  m71c "resolve failed" sticky error on top of lwIP's silent
   --  ARP queueing.
   ------------------------------------------------------------------

   procedure Track_Pending (Id : Natural; Ip : U32) is
      Free : Natural := 0;
   begin
      for I in Pend'Range loop
         if Pend (I).Used
           and then Pend (I).Sock = Id
           and then Pend (I).Ip = Ip
         then
            Pend (I).Deadline := Syscalls.Read_Time + Arp_Timeout;
            return;
         elsif not Pend (I).Used and then Free = 0 then
            Free := I;
         end if;
      end loop;
      if Free /= 0 then
         Pend (Free) :=
           (Used     => True,
            Sock     => Id,
            Ip       => Ip,
            Deadline => Syscalls.Read_Time + Arp_Timeout);
      end if;
   end Track_Pending;

   procedure Check_Pending is
   begin
      for I in Pend'Range loop
         if Pend (I).Used then
            if Aknet_Arp_Resolved (Pend (I).Ip) /= 0 then
               Pend (I).Used := False;
            elsif Syscalls.Read_Time > Pend (I).Deadline then
               Pend (I).Used := False;
               if Pend (I).Sock >= 1
                 and then Pend (I).Sock <= Max_Socks
                 and then Socks (Pend (I).Sock).Used
               then
                  Flag_Error (Pend (I).Sock, 2);
               end if;
            end if;
         end if;
      end loop;
   end Check_Pending;

   procedure Scrub_Pending (Id : Natural) is
   begin
      for I in Pend'Range loop
         if Pend (I).Used and then Pend (I).Sock = Id then
            Pend (I).Used := False;
         end if;
      end loop;
   end Scrub_Pending;

   ------------------------------------------------------------------
   --  Socket TX (m71c): Op_Kick drains the socket's TX ring. The
   --  wire formats now come from lwIP; the hairpin closed-port
   --  precheck and the usage errors stay on this side.
   ------------------------------------------------------------------

   procedure Drain_Sock_Tx (Id : Natural) is
      VA   : constant U64 := Sock_VA (Id);
      Base : constant U64 := VA + Syscalls.Page_Size;
      Head : U64;
      Tail : U64;
      Slot : U64;
      Len  : U64;
      Dst_IP   : U32;
      Dst_Port : U32;
      Target   : Natural;
      Rc       : Int;
      Csum     : U32;
   begin
      loop
         declare
            Hdr : Ring_Words with Address => To_Addr (Base);
         begin
            Head := Hdr (0);
            Tail := Hdr (1);
         end;
         exit when Tail = Head;
         Fence;
         Slot := Base + Sock_Slot_Base + (Tail mod Sock_Slots)
           * Sock_Slot_Size;
         declare
            Mem : Byte_Span (0 .. Sock_Slot_Size - 1)
              with Address => To_Addr (Slot);
         begin
            Len := U64 (Mem (0)) + U64 (Mem (1)) * 256;
            Dst_IP := U32 (Mem (4)) * 2 ** 24
              + U32 (Mem (5)) * 2 ** 16
              + U32 (Mem (6)) * 2 ** 8 + U32 (Mem (7));
            Dst_Port := U32 (Mem (8)) * 2 ** 24
              + U32 (Mem (9)) * 2 ** 16
              + U32 (Mem (10)) * 2 ** 8 + U32 (Mem (11));
         end;
         --  Defensive: the client lib caps payloads at 996; a
         --  wild length must not overrun the buffers.
         if Len > Sock_Max_Payload then
            Len := Sock_Max_Payload;
         end if;

         if Socks (Id).Proto = Proto_Udp then
            if not Socks (Id).Bound then
               Flag_Error (Id, 3);
            else
               if Dst_IP = 0 and then Socks (Id).Connected then
                  Dst_IP := Socks (Id).Peer_IP;
               end if;
               if Dst_Port = 0 and then Socks (Id).Connected then
                  Dst_Port := Socks (Id).Peer_Port;
               end if;
               if Dst_IP = 0 or else Dst_Port = 0 then
                  Flag_Error (Id, 3);
               elsif Dst_IP = My_IP then
                  --  Hairpin: lwIP would answer a closed port
                  --  with an ICMP unreachable we cannot observe,
                  --  so the m71c sender-side error stays an
                  --  Ada-side precheck; an open port is delivered
                  --  through the stack (the glue loops the packet
                  --  back into ip4_input and the bound pcb's
                  --  callback enqueues synchronously).
                  Target := Find_Udp_Rx
                    (Dst_Port, My_IP, Socks (Id).Local_Port);
                  if Target = 0 then
                     Flag_Error (Id, 1);
                  else
                     Rc := Aknet_Udp_Send
                       (Socks (Id).Pcb, Dst_IP, Dst_Port,
                        To_Addr (Slot + 12), U32 (Len));
                     if Rc /= 0 then
                        Console.Put_Line ("netserv udp send failed");
                     end if;
                  end if;
               else
                  Rc := Aknet_Udp_Send
                    (Socks (Id).Pcb, Dst_IP, Dst_Port,
                     To_Addr (Slot + 12), U32 (Len));
                  if Rc /= 0 then
                     Console.Put_Line ("netserv udp send failed");
                  elsif Aknet_Arp_Resolved (Dst_IP) = 0 then
                     Track_Pending (Id, Dst_IP);
                  end if;
               end if;
            end if;
         else
            --  ICMP ping socket: the client queued an echo
            --  request message; we own type/code/ident/cksum.
            if Len < 8 then
               Flag_Error (Id, 3);
            else
               if Dst_IP = 0 and then Socks (Id).Connected then
                  Dst_IP := Socks (Id).Peer_IP;
               end if;
               if Dst_IP = 0 then
                  Flag_Error (Id, 3);
               else
                  declare
                     Mem : Byte_Span (0 .. Len - 1)
                       with Address => To_Addr (Slot + 12);
                  begin
                     for I in 0 .. Len - 1 loop
                        Sock_Buf (I) := Mem (I);
                     end loop;
                  end;
                  Sock_Buf (0) := 8;        --  echo request
                  Sock_Buf (1) := 0;
                  Sock_Buf (2) := 0;
                  Sock_Buf (3) := 0;
                  Sock_Buf (4) := U8 (U32 (Id) / 256);
                  Sock_Buf (5) := U8 (U32 (Id) mod 256);
                  Csum := Checksum (To_VA (Sock_Buf'Address),
                                    Natural (Len));
                  Sock_Buf (2) := U8 (Csum / 256);
                  Sock_Buf (3) := U8 (Csum mod 256);
                  Rc := Aknet_Raw_Send
                    (Raw_Pcb, Dst_IP, Sock_Buf'Address, U32 (Len));
                  if Rc /= 0 then
                     Console.Put_Line ("netserv icmp send failed");
                  elsif Dst_IP /= My_IP
                    and then Aknet_Arp_Resolved (Dst_IP) = 0
                  then
                     Track_Pending (Id, Dst_IP);
                  end if;
               end if;
            end if;
         end if;

         declare
            Hdr : Ring_Words with Address => To_Addr (Base);
         begin
            Hdr (1) := Tail + 1;
         end;
      end loop;
   end Drain_Sock_Tx;

   ------------------------------------------------------------------
   --  Socket ops (m71c). Op_Socket rides the raw service cap
   --  (badge 0); the rest arrive on the minted socket cap with
   --  Message.Badge = socket id.
   ------------------------------------------------------------------

   procedure Handle_Sock_Open is
      Dom  : constant U64 := Syscalls.Message.Words (0);
      Typ  : constant U64 := Syscalls.Message.Words (1);
      Pro  : constant U64 := Syscalls.Message.Words (2);
      Ring : constant U64 := Syscalls.Message.Caps (0);
      Ntf  : constant U64 := Syscalls.Message.Caps (1);
      Id   : Natural := 0;
      Pcb  : System.Address := System.Null_Address;
      R    : U64;
   begin
      if Dom /= AF_INET or else Typ /= SOCK_DGRAM
        or else (Pro /= U64 (Proto_Udp)
                 and then Pro /= U64 (Proto_Icmp))
        or else Ring = 0 or else Ntf = 0
      then
         if Ring /= 0 then
            R := Syscalls.Cap_Delete (Ring);
         end if;
         if Ntf /= 0 then
            R := Syscalls.Cap_Delete (Ntf);
         end if;
         Console.Put_Line ("netserv sock open: bad args");
         Reply (Status_Bad_Args, 0);
         return;
      end if;
      for I in 1 .. Max_Socks loop
         if not Socks (I).Used then
            Id := I;
            exit;
         end if;
      end loop;
      if Id = 0 then
         R := Syscalls.Cap_Delete (Ring);
         R := Syscalls.Cap_Delete (Ntf);
         Console.Put_Line ("netserv sock open: table full");
         Reply (Status_Not_Ready, 0);
         return;
      end if;

      --  UDP sockets get their lwIP pcb now (the recv arg is the
      --  socket id); ping sockets share the raw pcb.
      if Pro = U64 (Proto_Udp) then
         Pcb := Aknet_Udp_New (U32 (Id));
         if Pcb = System.Null_Address then
            R := Syscalls.Cap_Delete (Ring);
            R := Syscalls.Cap_Delete (Ntf);
            Console.Put_Line ("netserv sock open: pcb failed");
            Reply (Status_Not_Ready, 0);
            return;
         end if;
      end if;

      if Syscalls.Mem_Map
           (Syscalls.Address_Space_Cap, Ring, Sock_VA (Id), 0,
            Sock_Ring_Bytes, 3) /= 0
      then
         if Pcb /= System.Null_Address then
            Aknet_Udp_Del (Pcb);
         end if;
         R := Syscalls.Cap_Delete (Ring);
         R := Syscalls.Cap_Delete (Ntf);
         Console.Put_Line ("netserv sock open: map failed");
         Reply (Status_Not_Ready, 0);
         return;
      end if;

      --  Reset both ring headers (the client zeroed them, but
      --  the ring-pair protocol is ours).
      declare
         Rx_Hdr : Ring_Words with Address => To_Addr (Sock_VA (Id));
         Tx_Hdr : Ring_Words with Address =>
           To_Addr (Sock_VA (Id) + Syscalls.Page_Size);
      begin
         Rx_Hdr := (others => 0);
         Tx_Hdr := (others => 0);
      end;

      Scrub_Pending (Id);
      Socks (Id) := (Used     => True,
                     Proto    => U8 (Pro),
                     Ring_Cap => Ring,
                     Ntfn_Cap => Ntf,
                     Pcb      => Pcb,
                     others   => <>);
      --  Caps do not travel in replies; the id is the reply and
      --  the client mints its own badged cap on the endpoint.
      Reply (Status_Ok, U64 (Id));
   end Handle_Sock_Open;

   function Port_In_Use (P : U32; Except : Natural) return Boolean is
   begin
      for I in 1 .. Max_Socks loop
         if I /= Except
           and then Socks (I).Used
           and then Socks (I).Proto = Proto_Udp
           and then Socks (I).Bound
           and then Socks (I).Local_Port = P
         then
            return True;
         end if;
      end loop;
      return False;
   end Port_In_Use;

   procedure Handle_Sock_Bind (Id : Natural) is
      P    : constant U64 := Syscalls.Message.Words (0);
      Port : U32;
   begin
      if Socks (Id).Proto /= Proto_Udp or else P > 16#FFFF# then
         Reply (Status_Bad_Args, 0);
         return;
      end if;
      if P = 0 then
         --  Ephemeral: first free port from the rotating cursor.
         Port := Next_Ephem;
         for N in 0 .. 16#3FFF# loop
            exit when not Port_In_Use (Port, Id);
            Port := 49152 + (Port - 49152 + 1) mod 16#4000#;
            if N = 16#3FFF# then
               Reply (Status_Not_Ready, 0);
               return;
            end if;
         end loop;
         Next_Ephem := 49152 + (Port - 49152 + 1) mod 16#4000#;
      else
         Port := U32 (P);
         if Port_In_Use (Port, Id) then
            Reply (Status_Not_Ready, 0);
            return;
         end if;
      end if;
      if Aknet_Udp_Bind (Socks (Id).Pcb, Port) /= 0 then
         Reply (Status_Not_Ready, 0);
         return;
      end if;
      Socks (Id).Bound := True;
      Socks (Id).Local_Port := Port;
      Reply (Status_Ok, U64 (Port));
   end Handle_Sock_Bind;

   procedure Handle_Sock_Connect (Id : Natural) is
      IP64 : constant U64 := Syscalls.Message.Words (0);
      Port : constant U64 := Syscalls.Message.Words (1);
   begin
      if IP64 = 0 or else IP64 > 16#FFFF_FFFF#
        or else (Socks (Id).Proto = Proto_Udp
                 and then (Port = 0 or else Port > 16#FFFF#))
      then
         Reply (Status_Bad_Args, 0);
         return;
      end if;
      if Socks (Id).Proto = Proto_Udp
        and then Aknet_Udp_Connect
          (Socks (Id).Pcb, U32 (IP64), U32 (Port)) /= 0
      then
         Reply (Status_Not_Ready, 0);
         return;
      end if;
      Socks (Id).Connected := True;
      Socks (Id).Peer_IP := U32 (IP64);
      Socks (Id).Peer_Port := U32 (Port and 16#FFFF#);
      Reply (Status_Ok, 0);
   end Handle_Sock_Connect;

   procedure Handle_Sock_Poll (Id : Natural) is
      VA : constant U64 := Sock_VA (Id);
      Rx_Level : U64;
      Tx_Used  : U64;
   begin
      declare
         Hdr : Ring_Words with Address => To_Addr (VA);
      begin
         Rx_Level := Hdr (0) - Hdr (1);
      end;
      declare
         Hdr : Ring_Words with Address =>
           To_Addr (VA + Syscalls.Page_Size);
      begin
         Tx_Used := Hdr (0) - Hdr (1);
      end;
      Reply4 (Status_Ok, Rx_Level, Sock_Slots - Tx_Used,
              Socks (Id).Error);
   end Handle_Sock_Poll;

   procedure Handle_Sock_Close (Id : Natural) is
      R : U64;
   begin
      if Socks (Id).Pcb /= System.Null_Address then
         Aknet_Udp_Del (Socks (Id).Pcb);
      end if;
      Scrub_Pending (Id);
      R := Syscalls.Mem_Unmap
        (Syscalls.Address_Space_Cap, Sock_VA (Id), Sock_Ring_Bytes);
      R := Syscalls.Cap_Delete (Socks (Id).Ring_Cap);
      R := Syscalls.Cap_Delete (Socks (Id).Ntfn_Cap);
      Socks (Id) := (others => <>);
      Reply (Status_Ok, 0);
   end Handle_Sock_Close;

   ------------------------------------------------------------------
   --  Op_Ping (internal test op, m71b; m72b: over the shared raw
   --  ICMP pcb, replies matched by the raw callback)
   ------------------------------------------------------------------

   procedure Handle_Ping is
      Target : constant U64 := Syscalls.Message.Words (0);
      T      : U32;
      T0     : U64;
      Csum   : U32;
   begin
      if Target = 0 or else Target > 16#FFFF_FFFF# then
         Reply (Status_Bad_Args, 0);
         return;
      end if;
      T := U32 (Target);
      if T = My_IP then
         --  Loopback short-circuit (m71b).
         Reply (Status_Ok, 0);
         return;
      end if;
      if Ping_Pending then
         Reply (Status_Not_Ready, 0);
         return;
      end if;

      Ping_Seq := Ping_Seq + 1;
      Ping_Target := T;
      Ping_Pending := True;
      T0 := Syscalls.Read_Time;
      Ping_T0 := T0;
      Ping_Limit := T0 + Ping_Timeout;

      --  Echo request: 8-byte header + the send timestamp as the
      --  8-byte payload (big-endian).
      Ping_Pkt (0) := 8;
      Ping_Pkt (1) := 0;
      Ping_Pkt (2) := 0;
      Ping_Pkt (3) := 0;
      Ping_Pkt (4) := U8 (Ping_Ident / 256);
      Ping_Pkt (5) := U8 (Ping_Ident mod 256);
      Ping_Pkt (6) := U8 ((Ping_Seq / 256) and 16#FF#);
      Ping_Pkt (7) := U8 (Ping_Seq mod 256);
      for I in 0 .. 7 loop
         Ping_Pkt (8 + I) :=
           U8 (Shr (T0, (7 - I) * 8) and 16#FF#);
      end loop;
      Csum := Checksum (To_VA (Ping_Pkt'Address), 16);
      Ping_Pkt (2) := U8 (Csum / 256);
      Ping_Pkt (3) := U8 (Csum mod 256);

      if Aknet_Raw_Send (Raw_Pcb, T, Ping_Pkt'Address, 16) /= 0 then
         Ping_Pending := False;
         Reply (Ping_No_Reply, 0);
         return;
      end if;

      --  m72b: do not spin here waiting for the reply. A wait of
      --  up to Ping_Timeout kept netserv off its endpoint while
      --  clients' calls and one-way kicks piled up, and Receive's
      --  caller-first ordering then serviced a Poll ahead of the
      --  kick it was meant to observe (the "udp closed port"
      --  flake). Stash the one-shot reply cap; the service loop
      --  completes the op when the raw callback clears
      --  Ping_Pending or Ping_Limit expires.
      Ping_Reply_H := Reply_H;
      Reply_H := 0;
   end Handle_Ping;

   ------------------------------------------------------------------
   --  Net: volume (m71c). Root enumerates status / address /
   --  gateway / dns / arp; the three config files are writable
   --  (dotted decimal, offset-0 whole-value writes). ReadDir and
   --  file-op badges: the file server forwards with per-client
   --  pid badges, so nothing here may assume badge 0 — the
   --  socket ops live on disjoint labels (21..25).
   ------------------------------------------------------------------

   type Net_File is (Nf_None, Nf_Root, Nf_Status, Nf_Address,
                     Nf_Gateway, Nf_Dns, Nf_Arp);

   --  Render scratch (library level: content is tiny — the ARP
   --  file is the largest at a handful of ~30-byte lines).
   Render_Buf : String (1 .. 1024);
   Render_Len : Natural := 0;

   procedure Put (S : String) is
   begin
      if Render_Len + S'Length <= Render_Buf'Length then
         Render_Buf (Render_Len + 1 .. Render_Len + S'Length) := S;
         Render_Len := Render_Len + S'Length;
      end if;
   end Put;

   procedure Put_Line (S : String) is
   begin
      Put (S);
      Put ((1 => Character'Val (10)));
   end Put_Line;

   --  Unpack the NUL-terminated path starting at message word
   --  First (8 chars per word, little-endian).
   function Path_Of (First : Natural) return String is
      Name : String (1 .. 32) := (others => Character'Val (0));
      Len  : Natural := 0;
   begin
      for P in 0 .. 31 loop
         declare
            Ch : constant Character :=
              Character'Val (Natural
                (Shr (Syscalls.Message.Words (First + P / 8),
                      (P mod 8) * 8) and 16#FF#));
         begin
            exit when Ch = Character'Val (0);
            Len := Len + 1;
            Name (Len) := Ch;
         end;
      end loop;
      return Name (1 .. Len);
   end Path_Of;

   function Resolve (Path : String) return Net_File is
   begin
      if Path = "" then
         return Nf_Root;
      elsif Path = "status" then
         return Nf_Status;
      elsif Path = "address" then
         return Nf_Address;
      elsif Path = "gateway" then
         return Nf_Gateway;
      elsif Path = "dns" then
         return Nf_Dns;
      elsif Path = "arp" then
         return Nf_Arp;
      end if;
      return Nf_None;
   end Resolve;

   function Live_Socks return U64 is
      N : U64 := 0;
   begin
      for I in 1 .. Max_Socks loop
         if Socks (I).Used then
            N := N + 1;
         end if;
      end loop;
      return N;
   end Live_Socks;

   --  Fill Render_Buf with the file's current content.
   procedure Render (F : Net_File) is
   begin
      Render_Len := 0;
      case F is
         when Nf_Status =>
            Put_Line ("netserv up");
            Put_Line ("ip " & Ip_Image (My_IP));
            Put_Line ("gateway " & Ip_Image (Gateway_IP));
            Put_Line ("dns " & Ip_Image (DNS_IP));
            Put_Line ("mac " & Mac_Image (Our_Mac));
            Put_Line ("mtu " & Dec (U32 (MTU)));
            Put_Line ("rx " & Dec (U32 (Rx_Frames))
                      & " tx " & Dec (U32 (Tx_Frames))
                      & " dropped " & Dec (U32 (Ring_Hdr (2))));
            Put_Line ("sockets " & Dec (U32 (Live_Socks)) & "/8");
         when Nf_Address =>
            Put_Line (Ip_Image (My_IP));
         when Nf_Gateway =>
            Put_Line (Ip_Image (Gateway_IP));
         when Nf_Dns =>
            Put_Line (Ip_Image (DNS_IP));
         when Nf_Arp =>
            --  lwIP's ARP table, stable entries only (the m71c
            --  cache had no pending state to display either).
            for I in U32'(0) .. 15 loop
               if Aknet_Arp_Get
                    (I, Render_Ip'Address, Render_Mac'Address) /= 0
               then
                  Put_Line (Ip_Image (Render_Ip) & " "
                            & Mac_Image (Render_Mac));
               end if;
            end loop;
         when others =>
            null;
      end case;
   end Render;

   --  Stat/Open/ReadDir share the (status, size, is_dir) reply
   --  shape (m64: stat answers directories, is_dir in word 4).
   procedure Reply_Stat (Status, Size : U64; Is_Dir : Boolean) is
   begin
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Words (0) := Status;
      Syscalls.Message.Words (1) := Size;
      Syscalls.Message.Words (4) := (if Is_Dir then 1 else 0);
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
         Console.Put_Line ("netserv reply failed");
      end if;
   end Reply_Stat;

   procedure Handle_Stat_Or_Open is
      F : constant Net_File := Resolve (Path_Of (0));
   begin
      case F is
         when Nf_Root =>
            Reply_Stat (Status_Ok, 0, True);
         when Nf_None =>
            Reply_Stat (Status_Not_Found, 0, False);
         when others =>
            Render (F);
            Reply_Stat (Status_Ok, U64 (Render_Len), False);
      end case;
   end Handle_Stat_Or_Open;

   procedure Handle_Read_Dir is
      Idx : constant U64 := Syscalls.Message.Words (4);
      F   : constant Net_File := Resolve (Path_Of (0));
      Name : String (1 .. 24) := (others => Character'Val (0));
      Name_Len : Natural := 0;
   begin
      if F = Nf_Root then
         case Idx is
            when 0 =>
               Name (1 .. 6) := "status";
               Name_Len := 6;
            when 1 =>
               Name (1 .. 7) := "address";
               Name_Len := 7;
            when 2 =>
               Name (1 .. 7) := "gateway";
               Name_Len := 7;
            when 3 =>
               Name (1 .. 3) := "dns";
               Name_Len := 3;
            when 4 =>
               Name (1 .. 3) := "arp";
               Name_Len := 3;
            when others =>
               null;
         end case;
      end if;
      if Name_Len = 0 then
         Reply (Status_Not_Found, 0);
         return;
      end if;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Words (0) := Status_Ok;
      Syscalls.Message.Words (1) := 0;   --  size: content is live
      Syscalls.Message.Words (2) := 0;   --  not a directory
      for P in 1 .. Name_Len loop
         Syscalls.Message.Words (3 + (P - 1) / 8) :=
           Syscalls.Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Name (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
         Console.Put_Line ("netserv readdir reply failed");
      end if;
   end Handle_Read_Dir;

   --  Map the transferred client buffer, run Body against it,
   --  unmap and delete. Shared by Read and Write.
   procedure Handle_Read is
      Offset : constant U64 := Syscalls.Message.Words (0);
      Length : constant U64 := Syscalls.Message.Words (1);
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      F      : constant Net_File := Resolve (Path_Of (2));
      Count  : U64 := 0;
      Status : U64 := Status_Ok;
   begin
      if Buf = 0 or else Length = 0 then
         Status := Status_Bad_Args;
      elsif F = Nf_None or else F = Nf_Root then
         Status := Status_Not_Found;
      else
         Render (F);
         if Offset >= U64 (Render_Len) then
            Status := Status_Out_Of_Range;
         else
            Count := U64'Min (Length, U64 (Render_Len) - Offset);
            Count := U64'Min (Count, Buf_Bytes);
            if Syscalls.Mem_Map
                 (Syscalls.Address_Space_Cap, Buf, Buf_Win_VA, 0,
                  Buf_Bytes, 3) /= 0
            then
               Status := Status_Not_Found;
               Count := 0;
            else
               declare
                  Dst : Byte_Span (0 .. Count - 1)
                    with Address => To_Addr (Buf_Win_VA);
               begin
                  for I in 0 .. Count - 1 loop
                     Dst (I) := U8 (Character'Pos
                       (Render_Buf (Natural (Offset) + Natural (I)
                                    + 1)));
                  end loop;
               end;
               if Syscalls.Mem_Unmap
                    (Syscalls.Address_Space_Cap, Buf_Win_VA,
                     Buf_Bytes) /= 0
               then
                  Console.Put_Line ("netserv buffer unmap failed");
               end if;
            end if;
         end if;
      end if;
      if Buf /= 0
        and then Syscalls.Cap_Delete (Buf) /= 0
      then
         Console.Put_Line ("netserv buffer cap delete failed");
      end if;
      Reply (Status, Count);
   end Handle_Read;

   --  Writable config: address/gateway/dns accept a dotted-
   --  decimal whole-value write at offset 0. Address and gateway
   --  writes reprogram the netif (m72b).
   procedure Handle_Write is
      Offset : constant U64 := Syscalls.Message.Words (0);
      Length : constant U64 := Syscalls.Message.Words (1);
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      F      : constant Net_File := Resolve (Path_Of (2));
      Status : U64 := Status_Ok;
      Count  : U64 := 0;
   begin
      if Buf = 0 or else Length = 0 or else Length > 32
        or else Offset /= 0
      then
         Status := Status_Bad_Args;
      elsif F /= Nf_Address and then F /= Nf_Gateway
        and then F /= Nf_Dns
      then
         Status := Status_Bad_Args;
      elsif Syscalls.Mem_Map
              (Syscalls.Address_Space_Cap, Buf, Buf_Win_VA, 0,
               Buf_Bytes, 3) /= 0
      then
         Status := Status_Not_Found;
      else
         declare
            Mem : Byte_Span (0 .. Length - 1)
              with Address => To_Addr (Buf_Win_VA);
            Text : String (1 .. Natural (Length));
            V    : U32;
         begin
            for I in 1 .. Natural (Length) loop
               Text (I) := Character'Val (Natural (Mem (U64 (I - 1))));
            end loop;
            if Parse_IP (Text, V) then
               case F is
                  when Nf_Address =>
                     My_IP := V;
                     Aknet_Set_Addr (My_IP, Gateway_IP);
                  when Nf_Gateway =>
                     Gateway_IP := V;
                     Aknet_Set_Addr (My_IP, Gateway_IP);
                  when others =>
                     DNS_IP := V;
               end case;
               Count := Length;
            else
               Status := Status_Bad_Args;
            end if;
         end;
         if Syscalls.Mem_Unmap
              (Syscalls.Address_Space_Cap, Buf_Win_VA,
               Buf_Bytes) /= 0
         then
            Console.Put_Line ("netserv buffer unmap failed");
         end if;
      end if;
      if Buf /= 0
        and then Syscalls.Cap_Delete (Buf) /= 0
      then
         Console.Put_Line ("netserv buffer cap delete failed");
      end if;
      Reply (Status, Count);
   end Handle_Write;

   procedure Handle_File_Op is
      L : constant U64 := Syscalls.Message.Label;
   begin
      if L = Files.Op_Stat or else L = Files.Op_Open then
         Handle_Stat_Or_Open;
      elsif L = Files.Op_Read then
         Handle_Read;
      elsif L = Files.Op_Write then
         Handle_Write;
      elsif L = Files.Op_ReadDir then
         Handle_Read_Dir;
      elsif L = Files.Op_Sync or else L = Files.Op_Close then
         Reply (Status_Ok, 0);
      else
         Reply (Status_Bad_Args, 0);
      end if;
   end Handle_File_Op;

   --  Register the Net: volume with the file server. This MUST be
   --  netserv's own last bring-up step, never init's at spawn: once
   --  the VFS mounts Net:, the fs forwards volume ops synchronously,
   --  and an fs blocked forwarding to a netserv that is itself
   --  blocked on an fs call (the ENV: reads above) is a circular
   --  deadlock (m72a wedge forensics). Self-registering after all
   --  fs-dependent bring-up closes that window for good: while
   --  serving, netserv makes no blocking fs calls at all.
   procedure Register_Net_Volume is
      Dev   : constant String := "Net";
      Lab   : constant String := "Net";
      Chars : constant String := Dev & Lab;
   begin
      Syscalls.Message.Label := Files.Op_Add_FS;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Words (0) := U64 (Dev'Length);
      Syscalls.Message.Words (1) := U64 (Lab'Length);
      Syscalls.Message.Words (2) := 1;  --  case-insensitive
      for P in 1 .. Chars'Length loop
         Syscalls.Message.Words (3 + (P - 1) / 8) :=
           Syscalls.Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Chars (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      --  The transfer copies Reg_Cap; netserv keeps its handle.
      Syscalls.Message.Caps := (0 => Reg_Cap, others => 0);
      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         Fatal ("net volume registration failed");
      end if;
   end Register_Net_Volume;

   ------------------------------------------------------------------
   --  Bring-up
   ------------------------------------------------------------------

   procedure Set_Rx_Online is
      Ring_Mint : U64;
      Ntfn_Mint : U64;
   begin
      Ring_Mint := Syscalls.Cap_Mint
        (Ring_Cap,
         Syscalls.Right_Map + Syscalls.Right_Read
           + Syscalls.Right_Write + Syscalls.Right_Transfer, 0);
      Ntfn_Mint := Syscalls.Cap_Mint
        (Ntfn_Cap, Syscalls.Right_Write + Syscalls.Right_Transfer, 0);
      if Ring_Mint = Syscalls.Syscall_Failed
        or else Ntfn_Mint = Syscalls.Syscall_Failed
      then
         Fatal ("rx cap mint failed");
      end if;

      Syscalls.Message.Label := Drv_Op_Set_Rx;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Words (0) := Ring_Bytes;
      Syscalls.Message.Caps := (0 => Ring_Mint, 1 => Ntfn_Mint,
                                others => 0);
      if Syscalls.IPC_Call (Netdev_EP) /= Syscalls.IPC_Ok
        or else Syscalls.Message.Words (0) /= 0
      then
         Fatal ("set-rx rejected");
      end if;
      Ring_Slots := Syscalls.Message.Words (1);
      if Ring_Slots = 0 then
         Fatal ("set-rx slot count");
      end if;

      --  The driver keeps its transferred copies for its lifetime;
      --  ours are per-call.
      if Syscalls.Cap_Delete (Ring_Mint) /= 0
        or else Syscalls.Cap_Delete (Ntfn_Mint) /= 0
      then
         Console.Put_Line ("netserv rx mint delete failed");
      end if;
   end Set_Rx_Online;

   --  50 ms timer wheel for lwIP (ARP retry/aging now, TCP
   --  timers from m72c): a secondary thread pokes the bound
   --  notification bit 2; the service loop runs
   --  sys_check_timeouts and the pending-ARP tracker on it.
    procedure Ticker_Main is
       Now : U64;
    begin
       loop
          Now := Syscalls.Read_Time;
          if Syscalls.Sleep_Until
               (Now + Tick_Hz / 20) /= 0
            or else Syscalls.Ntfn_Signal (Ntfn_Cap, Signal_Tick) /= 0
          then
             exit;
          end if;
       end loop;
    end Ticker_Main;

   procedure Start_Ticker is
      Stack_Cap : U64;
      IPC_Cap   : U64;
      TLS_Cap   : U64;
      R         : U64;
   begin
      Stack_Cap := Syscalls.Mem_Alloc (1);
      IPC_Cap   := Syscalls.Mem_Alloc (1);
      TLS_Cap   := Syscalls.Mem_Alloc (1);
      if Stack_Cap = Syscalls.Syscall_Failed
        or else IPC_Cap = Syscalls.Syscall_Failed
        or else TLS_Cap = Syscalls.Syscall_Failed
      then
         Fatal ("ticker alloc failed");
      end if;
      --  The kernel maps the stack and IPC buffer from the
      --  Thread_Create caps; the TLS page we map ourselves.
      if Syscalls.Mem_Map
           (Syscalls.Address_Space_Cap, TLS_Cap, Ticker_TLS_VA, 0,
            Syscalls.Page_Size, 3) /= 0
      then
         Fatal ("ticker tls map failed");
      end if;
      Syscalls.Thread_Create_Write_Params
        (Params =>
           (Stack_VA      => Ticker_Stack_Top,
            Stack_Pages   => 1,
            Entry_PC      => Syscalls.Thread_Entry_Point,
            Arg           => To_VA (Ticker_Main'Address),
            TLS_Base      => Ticker_TLS_VA,
            Priority_Bits => 0,
            Stack_Cap     => Stack_Cap,
            IPC_Cap       => IPC_Cap,
            IPC_VA        => Ticker_IPC_VA));
      R := Syscalls.Thread_Create;
      if R = Syscalls.Syscall_Failed then
         Fatal ("ticker create failed");
      end if;
   end Start_Ticker;

   ------------------------------------------------------------------
   --  Main: bring up, then serve.
   ------------------------------------------------------------------

   procedure Run is
   begin
      Console.Set_Endpoint (Console_EP);
      Files.Bind (FS_Cap);

      --  lwIP core init (memp pools, timeout list); the netif
      --  follows once the driver info is in.
      Lwip_Init;
      Console.Put_Line ("netserv lwip 2.2.1 init ok");

      Read_Env_IP ("ENV:Net.Address", My_IP);
      Read_Env_IP ("ENV:Net.Gateway", Gateway_IP);
      Read_Env_IP ("ENV:Net.DNS", DNS_IP);

      --  Register the Net: volume as soon as the fs-dependent
      --  bring-up (the ENV: reads above) is done: later steps talk
      --  only to the driver, and clients opening Net: before the
      --  service loop starts simply rendezvous on the endpoint.
      --  Registering early closes the udp_test address-read race;
      --  registering while the fs could be blocked forwarding to a
      --  netserv that is itself blocked on an fs call would be the
      --  m72a circular deadlock, so this must stay after the last
      --  fs call and before the loop (which makes no blocking fs
      --  calls at all).
      Register_Net_Volume;

      --  Driver info: MAC (words 1/2, byte 0 in the low bits) + MTU.
      Syscalls.Message.Label := Drv_Op_Info;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (Netdev_EP) /= Syscalls.IPC_Ok
        or else Syscalls.Message.Words (0) /= 0
      then
         Fatal ("driver info failed");
      end if;
      for I in 0 .. 3 loop
         Our_Mac (I) := U8 (Shr (Syscalls.Message.Words (1), I * 8)
                            and 16#FF#);
      end loop;
      for I in 4 .. 5 loop
         Our_Mac (I) := U8 (Shr (Syscalls.Message.Words (2), (I - 4) * 8)
                            and 16#FF#);
      end loop;
      MTU := Syscalls.Message.Words (3);

      Ring_Cap := Syscalls.Mem_Alloc (Ring_Pages);
      Tx_Cap := Syscalls.Mem_Alloc (1);
      if Ring_Cap = Syscalls.Syscall_Failed
        or else Tx_Cap = Syscalls.Syscall_Failed
      then
         Fatal ("mem alloc failed");
      end if;
      if Syscalls.Mem_Map
           (Syscalls.Address_Space_Cap, Ring_Cap, Ring_VA, 0,
            Ring_Bytes, 3) /= 0
        or else Syscalls.Mem_Map
           (Syscalls.Address_Space_Cap, Tx_Cap, Tx_VA, 0,
            Syscalls.Page_Size, 3) /= 0
      then
         Fatal ("mem map failed");
      end if;

      --  TX staging mint: the driver needs Manage for
      --  mem_object_pa and Transfer for the per-call transfer;
      --  reused forever.
      Tx_Mint := Syscalls.Cap_Mint
        (Tx_Cap, Syscalls.Right_Read + Syscalls.Right_Manage
           + Syscalls.Right_Transfer, 0);
      if Tx_Mint = Syscalls.Syscall_Failed then
         Fatal ("tx mint failed");
      end if;

      Ntfn_Cap := Syscalls.Ntfn_Create;
      if Ntfn_Cap = Syscalls.Syscall_Failed
        or else Syscalls.Ntfn_Bind_Thread (Ntfn_Cap) /= 0
      then
         Fatal ("ntfn setup failed");
      end if;

      --  The netif before the RX tap goes online: once Set_Rx
      --  lands, frames (and the first ARP for us) can arrive at
      --  any wakeup.
      Aknet_Setup (Our_Mac'Address, My_IP, Gateway_IP, U32 (MTU));
      Raw_Pcb := Aknet_Raw_Icmp_New;
      if Raw_Pcb = System.Null_Address then
         Fatal ("raw pcb failed");
      end if;

      Set_Rx_Online;
      Start_Ticker;

      Console.Put_Line
        ("netserv online ip " & Ip_Image (My_IP)
         & " gw " & Ip_Image (Gateway_IP)
         & " dns " & Ip_Image (DNS_IP)
         & " mac " & Mac_Image (Our_Mac)
         & " mtu " & Dec (U32 (MTU)));

      ---------------------------------------------------------------
      --  Service loop: one IPC_Recv multiplexing client ops, the
      --  Net: file surface, the driver's RX-kick notification
      --  (bit 0) and the 50 ms ticker (bit 2). Dispatch is by
      --  LABEL, not badge: the file server forwards Net: ops with
      --  per-client pid badges (labels 0..18), raw service-cap
      --  calls arrive badge 0 (Op_Socket, Op_Ping), and socket
      --  ops (21..25) arrive on the minted caps with badge =
      --  socket id.
      ---------------------------------------------------------------

      loop
         if Syscalls.IPC_Recv (Svc_EP, Reply_H) /= Syscalls.IPC_Ok
         then
            Console.Put_Line ("netserv recv failed");
            Syscalls.Process_Exit;
         end if;

         declare
            L     : constant U64 := Syscalls.Message.Label;
            Badge : constant U64 := Syscalls.Message.Badge;
            Id    : Natural;
         begin
            if L = Syscalls.Notification_Label then
               declare
                  Bits : constant U64 := Syscalls.Message.Words (0);
               begin
                  if (Bits and Signal_Rx) /= 0 then
                     Drain_Ring;
                  end if;
                  if (Bits and Signal_Tick) /= 0 then
                     Aknet_Check_Timeouts;
                     Check_Pending;
                  end if;
               end;
            elsif L <= 18 then
               Handle_File_Op;
            elsif L = Op_Ping and then Badge = 0 then
               Handle_Ping;
            elsif L = Op_Socket and then Badge = 0 then
               Handle_Sock_Open;
            elsif L >= Op_Bind and then L <= Op_Close
              and then Badge >= 1 and then Badge <= U64 (Max_Socks)
              and then Socks (Natural (Badge)).Used
            then
               Id := Natural (Badge);
               if L = Op_Bind then
                  Handle_Sock_Bind (Id);
               elsif L = Op_Connect then
                  Handle_Sock_Connect (Id);
               elsif L = Op_Kick then
                  Drain_Sock_Tx (Id);    --  call (m72b: was send)
                  if Reply_H /= 0 then
                     Reply (Status_Ok, 0);
                  end if;
               elsif L = Op_Poll then
                  Handle_Sock_Poll (Id);
               else
                  Handle_Sock_Close (Id);
               end if;
            elsif Reply_H /= 0 then
               Reply (Status_Bad_Args, 0);
            end if;
         end;

         --  Complete a deferred Op_Ping: the raw callback cleared
         --  Ping_Pending (success, report the RTT) or the timeout
         --  expired (report no-reply). The 50 ms ticker bounds the
         --  timeout resolution.
         if Ping_Reply_H /= 0 then
            if not Ping_Pending then
               Reply_To (Ping_Reply_H, Status_Ok, Ping_Rtt);
               Ping_Reply_H := 0;
            elsif Syscalls.Read_Time > Ping_Limit then
               Ping_Pending := False;
               Reply_To (Ping_Reply_H, Ping_No_Reply, 0);
               Ping_Reply_H := 0;
            end if;
         end if;
      end loop;
   end Run;

end Netserv_Engine;
