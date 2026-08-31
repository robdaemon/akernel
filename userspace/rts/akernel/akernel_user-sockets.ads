with Interfaces;
with System;
with Akernel_User.Syscalls;

--  Socket client (milestone 71c): the userland half of the
--  netserv socket protocol. A socket is a minted cap on the
--  netserv service endpoint (badge = socket id) plus a shared
--  two-page ring-pair memory object and a client notification:
--
--    page 0 = RX ring (server produces, client consumes)
--    page 1 = TX ring (client produces, server consumes)
--
--  Each ring: word0 head (producer), word1 tail (consumer),
--  word2 dropped, word3 reserved; 4 slots of 1008 bytes at
--  offset 64. A slot is len:u16, flags:u16, addr:u32, port:u32,
--  then up to 996 payload bytes. On TX, addr/port are the
--  destination (0 = the Connect default peer); on RX they are
--  the source.
--
--  Ops on the minted socket cap: Op_Bind=21 (word0 = port,
--  0 = ephemeral -> assigned), Op_Connect=22 (word0 = IPv4 BE
--  low 32, word1 = port), Op_Kick=23 (one-way send: TX ring
--  dirty), Op_Poll=24 -> (status, rx level, tx free, error),
--  Op_Close=25, and m72c's Op_Listen=26 (word0 = backlog hint)
--  and Op_Accept=27 (cap0 = a fresh two-page ring pair, cap1 =
--  a client ntfn; reply carries the child socket id, the client
--  mints its badged cap — the Op_Socket pattern). The server
--  signals the client notification with bit 0 = RX readable,
--  bit 1 = error/closed.
--
--  Protocols: IPPROTO_UDP datagrams (hairpin loopback when the
--  destination is our own address; a closed local port sets the
--  sender's error word), IPPROTO_ICMP ping sockets (Linux
--  ping-socket semantics: the client sends an ICMP echo request
--  message, netserv owns the IP header, overwrites the ident
--  with the socket id, recomputes the checksum, and matches
--  echo replies back to the socket) and m72c's IPPROTO_TCP
--  streams (SOCK_STREAM): Connect blocks until the handshake
--  resolves (reply status 0 ok / 4 refused / 5 timeout), Listen
--  marks the socket (Poll's rx level is the parked-accept
--  backlog), Accept claims a pending connection as a fresh
--  handle, and the rings carry a byte stream in the same slots
--  (addr/port unused). Peer close or a reset arrives as a
--  zero-length slot with flags bit 0: Recv_From reports it as
--  Status_Ok with Count = 0 (EOF); Poll's sticky error word
--  distinguishes (0 = orderly, 4/5/6 = refused/timeout/reset).
--
--  Wait strategy: Recv_From/Send_To poll the shared rings in
--  Sleep_Until slices (5 ms) against a Read_Time deadline —
--  callers here are single-channel CLI programs; GUI clients
--  that multiplex several sources bind the notification to
--  their thread and IPC_Recv instead.
--
--  Timeouts are in Read_Time ticks (10 MHz).

package Akernel_User.Sockets is
   use type Syscalls.U64;

   subtype U64 is Syscalls.U64;
   subtype U32 is Interfaces.Unsigned_32;

   AF_INET     : constant U64 := 2;
   SOCK_STREAM : constant U64 := 1;
   SOCK_DGRAM  : constant U64 := 2;

   IPPROTO_ICMP : constant U64 := 1;
   IPPROTO_TCP  : constant U64 := 6;
   IPPROTO_UDP  : constant U64 := 17;

   Status_Ok        : constant U64 := 0;
   Status_Timeout   : constant U64 := 1;
   Status_Not_Ready : constant U64 := 2;
   Status_Bad_Args  : constant U64 := 3;
   Status_Error     : constant U64 := 4;

   Rx_Bit  : constant U64 := 1;
   Err_Bit : constant U64 := 2;

   --  Wire the package to the netserv client endpoint (uniform
   --  command ABI handle 6 for C: programs).
   procedure Attach (Net_Cap : U64);

   --  The attached netserv endpoint (0 = not attached). Mirrors
   --  Files.Endpoint/Console.Endpoint: the GNAT.Sockets bridge
   --  (m73) lazily attaches handle 6 unless a program attached its
   --  own first.
   function Endpoint return U64;

   --  New socket (Proto = IPPROTO_UDP, IPPROTO_ICMP or
   --  IPPROTO_TCP); Handle returns the minted socket cap.
   --  Protocol status.
   function Socket (Proto : U64; Handle : out U64) return U64;

   --  Bind a local port (0 = ephemeral; Assigned returns the
   --  chosen port).
   function Bind (Handle : U64; Port : U64; Assigned : out U64)
                  return U64;

   --  Default peer + RX filter (UDP/ICMP; Port ignored for ICMP).
   --  For TCP this CONNECTS: blocks until the handshake resolves
   --  and returns 0 ok / 4 refused / 5 timeout (a few seconds at
   --  worst — the server bounds the wait).
   function Connect (Handle : U64; IP : U32; Port : U64) return U64;

   --  TCP: mark a bound socket as a listener. Backlog is a hint;
   --  the server parks as many pending connections as it has
   --  socket slots.
   function Listen (Handle : U64; Backlog : U64) return U64;

   --  TCP: claim a pending connection on a listener as a fresh
   --  stream handle. Non-blocking: Status_Not_Ready when the
   --  backlog is empty (Poll's rx level reports it). Peer_*
   --  return the connection's remote address (m73: BSD accept
   --  fills a sockaddr_in from them).
   function Accept_Connection
     (Handle     : U64;
      New_Handle : out U64;
      Peer_IP    : out U32;
      Peer_Port  : out U64) return U64;

   --  Queue a datagram (Len <= 996) and kick the server. IP/Port
   --  select the destination; pass 0/0 for the Connect default.
   function Send_To
     (Handle : U64;
      Data   : System.Address;
      Len    : U64;
      IP     : U32;
      Port   : U64) return U64;

   --  Pop the next datagram (or, for TCP, the next stream bytes
   --  — chunking is arbitrary); waits up to Timeout ticks
   --  (0 = non-blocking). Count returns the payload bytes
   --  (truncated at Max), Src_* the sender (unused for TCP).
   --  Status_Timeout on an empty ring past the deadline. For TCP,
   --  Status_Ok with Count = 0 is EOF: the peer closed (or the
   --  connection reset — Poll's error word says which).
   function Recv_From
     (Handle   : U64;
      Buf      : System.Address;
      Max      : U64;
      Timeout  : U64;
      Src_IP   : out U32;
      Src_Port : out U64;
      Count    : out U64) return U64;

   --  Snapshot: queued RX datagrams (a TCP listener: the parked
   --  accept backlog), free TX slots, sticky error word (nonzero
   --  once a TX failed, e.g. ARP timeout or hairpin to a closed
   --  port; m72c: 4 = connect refused, 5 = connect timeout,
   --  6 = reset).
   function Poll
     (Handle   : U64;
      Rx_Level : out U64;
      Tx_Free  : out U64;
      Error    : out U64) return U64;

   --  Close the socket (server side frees the slot) and release
   --  all local caps.
   function Close (Handle : U64) return U64;

   --  m78a: resolve a hostname to an IPv4 address through the
   --  netserv-resident resolver (lwIP dns.c; queries go to the
   --  Net:dns server and share lwIP's cache). Blocks until the
   --  resolver answers, bounded by lwIP's own DNS retry/timeout
   --  budget (a few seconds at worst). Statuses: Status_Ok with
   --  IP set (packed big-endian, the Ip_Image convention);
   --  Status_Timeout (1) = the lookup failed (NXDOMAIN, no
   --  answer, timeout — the wire does not distinguish);
   --  Status_Not_Ready (2) = the resolver table is full;
   --  Status_Bad_Args (3) = empty or oversize name (> 255);
   --  Status_Error (4) = transport failure.
   function Resolve (Name : String; IP : out U32) return U64;

   --  Dotted-decimal IPv4 ("10.0.2.15", optional trailing
   --  CR/LF); False on any malformation.
   function Parse_IP (Text : String; IP : out U32) return Boolean;

   --  The reverse: "10.0.2.15".
   function Ip_Image (IP : U32) return String;

   --  m73: C-convention exports for gnat_user/akernel_gsocket.c
   --  (GNAT.Sockets' C helper layer).  Scalars and out-parameters
   --  only, so the C ABI matches the Ada profile directly.
private
   pragma Export (C, Attach, "aknet_sock_attach");
   pragma Export (C, Endpoint, "aknet_sock_endpoint");
   pragma Export (C, Socket, "aknet_sock_socket");
   pragma Export (C, Bind, "aknet_sock_bind");
   pragma Export (C, Connect, "aknet_sock_connect");
   pragma Export (C, Listen, "aknet_sock_listen");
   pragma Export (C, Accept_Connection, "aknet_sock_accept");
   pragma Export (C, Send_To, "aknet_sock_sendto");
   pragma Export (C, Recv_From, "aknet_sock_recvfrom");
   pragma Export (C, Poll, "aknet_sock_poll");
   pragma Export (C, Close, "aknet_sock_close");

   --  m78a: C-friendly Resolve (name as address + length) for
   --  akernel_gsocket.c's DNS path.
   function Resolve_C
     (Name : System.Address; Len : U64; IP : out U32) return U64;
   pragma Export (C, Resolve_C, "aknet_sock_resolve");

end Akernel_User.Sockets;
