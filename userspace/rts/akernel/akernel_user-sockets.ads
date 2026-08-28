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
--  Op_Close=25. The server signals the client notification with
--  bit 0 = RX readable, bit 1 = error/closed.
--
--  Protocols: IPPROTO_UDP datagrams (hairpin loopback when the
--  destination is our own address; a closed local port sets the
--  sender's error word) and IPPROTO_ICMP ping sockets (Linux
--  ping-socket semantics: the client sends an ICMP echo request
--  message, netserv owns the IP header, overwrites the ident
--  with the socket id, recomputes the checksum, and matches
--  echo replies back to the socket).
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

   AF_INET    : constant U64 := 2;
   SOCK_DGRAM : constant U64 := 2;

   IPPROTO_ICMP : constant U64 := 1;
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

   --  New datagram socket (Proto = IPPROTO_UDP or IPPROTO_ICMP);
   --  Handle returns the minted socket cap. Protocol status.
   function Socket (Proto : U64; Handle : out U64) return U64;

   --  Bind a local port (0 = ephemeral; Assigned returns the
   --  chosen port).
   function Bind (Handle : U64; Port : U64; Assigned : out U64)
                  return U64;

   --  Default peer + RX filter. Port is ignored for ICMP.
   function Connect (Handle : U64; IP : U32; Port : U64) return U64;

   --  Queue a datagram (Len <= 996) and kick the server. IP/Port
   --  select the destination; pass 0/0 for the Connect default.
   function Send_To
     (Handle : U64;
      Data   : System.Address;
      Len    : U64;
      IP     : U32;
      Port   : U64) return U64;

   --  Pop the next datagram; waits up to Timeout ticks
   --  (0 = non-blocking). Count returns the payload bytes
   --  (truncated at Max), Src_* the sender. Status_Timeout on
   --  an empty ring past the deadline.
   function Recv_From
     (Handle   : U64;
      Buf      : System.Address;
      Max      : U64;
      Timeout  : U64;
      Src_IP   : out U32;
      Src_Port : out U64;
      Count    : out U64) return U64;

   --  Snapshot: queued RX datagrams, free TX slots, sticky
   --  error word (nonzero once a TX failed, e.g. ARP timeout
   --  or hairpin to a closed port).
   function Poll
     (Handle   : U64;
      Rx_Level : out U64;
      Tx_Free  : out U64;
      Error    : out U64) return U64;

   --  Close the socket (server side frees the slot) and release
   --  all local caps.
   function Close (Handle : U64) return U64;

   --  Dotted-decimal IPv4 ("10.0.2.15", optional trailing
   --  CR/LF); False on any malformation.
   function Parse_IP (Text : String; IP : out U32) return Boolean;

   --  The reverse: "10.0.2.15".
   function Ip_Image (IP : U32) return String;

end Akernel_User.Sockets;
