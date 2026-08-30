------------------------------------------------------------------------------
--                                                                          --
--                       A K E R N E L   (Milestone 53c)                    --
--                                                                          --
--                     System.OS_Constants (akernel)                        --
--                                                                          --
-- Hand-written replacement for the generated s-oscons.ads. The embedded  --
-- pool ships no OS_Constants (it is produced by s-oscons-tmplt.c against  --
-- target headers); the 53c-vendored Ada.Directories chain needs only the --
-- handful of constants below. Values are AKERNEL facts (gloss dirent     --
-- buffer, adaint struct file_attributes layout), not host measurements.  --
--                                                                        --
-- m73 extends the set for the vendored GNAT.Sockets stack: the values    --
-- below are the AKERNEL socket ABI, implemented by                        --
-- gnat_user/akernel_gsocket.c (fd_set bit layout, struct sizes, option   --
-- codes). Errno numbers are newlib's (sys/errno.h) — the C layer sets   --
-- them and System.CRTL's strerror reports them. Option codes follow     --
-- Linux where the choice is free.                                        --
--                                                                        --
------------------------------------------------------------------------------

with Interfaces.C;

package System.OS_Constants is
   pragma Pure;

   ----------------
   -- Errno bits --
   ----------------

   ENOENT : constant := 2;   --  no such file or directory (gloss)

   ----------------------
   -- C struct buffers --
   ----------------------

   --  Buffer sizes for opaque C structs that GNAT passes to adaint by
   --  pointer. Only need to be >= the real C struct; adaint writes at
   --  most its own layout.

   --  struct file_attributes (adaint.h): int + 7 x uchar + pad +
   --  OS_Time (long long) + __int64 file_length = 32 bytes; 64 with
   --  headroom.
   SIZEOF_struct_file_attributes : constant := 64;

   --  struct dirent allocation for __gnat_readdir's caller buffer:
   --  our akernel_readdir copies a plain NUL-terminated name
   --  (FAT LFN up to 255) into it.
   SIZEOF_struct_dirent_alloc : constant := 280;

   --------------------------
   -- Sockets (m73)        --
   --------------------------

   --  Target feature flags read by the vendored GNAT.Sockets units.

   type OS_Type is (Windows, Other_OS);
   Target_OS : constant OS_Type := Other_OS;
   pragma Warnings (Off, Target_OS);
   --  Suppress warnings on Target_OS since it is in general tested for
   --  equality with Windows.

   Thread_Blocking_IO : constant Boolean := True;
   --  Our socket ops block in the calling thread (IPC + ring waits),
   --  so the thin layer never flips sockets non-blocking behind the
   --  user's back.

   Need_Netdb_Buffer : constant := 0;  --  getXXXbyYYY buffer in KB
   Need_Netdb_Lock   : constant := 1;  --  netdb calls under Task_Lock

   Has_Sockaddr_Len : constant := 0;
   --  struct sockaddr has no leading length byte (Linux layout).

   --  Address families / socket types / wire protocols.  Only AF_INET
   --  exists in the stack; AF_INET6 is declared so the vendored units
   --  compile, and akernel_gsocket.c answers EAFNOSUPPORT.

   AF_UNSPEC : constant := 0;
   AF_UNIX   : constant := 1;
   AF_INET   : constant := 2;
   AF_INET6  : constant := 10;

   SOCK_STREAM : constant := 1;
   SOCK_DGRAM  : constant := 2;
   SOCK_RAW    : constant := 3;

   IPPROTO_IP   : constant := 0;
   IPPROTO_ICMP : constant := 1;
   IPPROTO_IGMP : constant := 2;
   IPPROTO_TCP  : constant := 6;
   IPPROTO_UDP  : constant := 17;
   IPPROTO_IPV6 : constant := 41;
   IPPROTO_RAW  : constant := 255;

   --  Option levels and names (Linux values; the C layer stores or
   --  reports them, only SO_ERROR has live semantics — it reads the
   --  socket's sticky error).

   SOL_SOCKET : constant := 1;

   SO_REUSEADDR     : constant := 2;
   SO_ERROR         : constant := 4;
   SO_BROADCAST     : constant := 6;
   SO_SNDBUF        : constant := 7;
   SO_RCVBUF        : constant := 8;
   SO_KEEPALIVE     : constant := 9;
   SO_LINGER        : constant := 13;
   SO_RCVTIMEO      : constant := 20;
   SO_SNDTIMEO      : constant := 21;
   SO_BINDTODEVICE  : constant := 25;
   SO_BUSY_POLL     : constant := 46;

   TCP_NODELAY      : constant := 1;
   TCP_KEEPIDLE     : constant := 4;
   TCP_KEEPINTVL    : constant := 5;
   TCP_KEEPCNT      : constant := 6;

   IP_PKTINFO         : constant := 8;
   IP_MULTICAST_IF    : constant := 32;
   IP_MULTICAST_LOOP  : constant := 33;
   IP_MULTICAST_TTL   : constant := 34;
   IP_ADD_MEMBERSHIP  : constant := 35;
   IP_DROP_MEMBERSHIP : constant := 36;

   IPV6_MULTICAST_IF    : constant := 17;
   IPV6_MULTICAST_HOPS  : constant := 18;
   IPV6_MULTICAST_LOOP  : constant := 19;
   IPV6_ADD_MEMBERSHIP  : constant := 20;
   IPV6_DROP_MEMBERSHIP : constant := 21;
   IPV6_V6ONLY          : constant := 26;

   --  send/recv flags; MSG_Forced_Flags are OR-ed into every call by
   --  the thin layer (nothing forced here: no SIGPIPE exists).

   MSG_OOB          : constant := 1;
   MSG_PEEK         : constant := 2;
   MSG_EOR          : constant := 16#80#;
   MSG_WAITALL      : constant := 16#100#;
   MSG_Forced_Flags : constant := 0;

   SHUT_RD   : constant := 0;
   SHUT_WR   : constant := 1;
   SHUT_RDWR : constant := 2;

   --  ioctl requests (Linux encoding).  FIONBIO flips the fd-table
   --  nonblocking flag; FIONREAD reports queued RX bytes (slot count
   --  times the slot capacity — an upper bound).

   FIONBIO  : constant := 16#5421#;
   FIONREAD : constant := 16#541B#;

   subtype IOCTL_Req_T is Interfaces.C.int;

   --  poll/select.  fd_set is a plain bit array over fds
   --  0 .. FD_SETSIZE - 1 (256 bits = 32 bytes).

   POLLIN   : constant := 1;
   POLLPRI  : constant := 2;
   POLLOUT  : constant := 4;
   POLLERR  : constant := 8;
   POLLHUP  : constant := 16;
   POLLNVAL : constant := 32;

   FD_SETSIZE         : constant := 256;
   SIZEOF_fd_set      : constant := 32;
   SIZEOF_fd_type     : constant := 32;  --  bits in an fd (C int)
   SIZEOF_nfds_t      : constant := 64;  --  bits in nfds_t
   SIZEOF_pollfd_events : constant := 16;  --  bits in pollfd.events

   --  C struct sizes (akernel_gsocket.c layouts; the Ada side treats
   --  hostent/servent as opaque buffers of exactly this size).

   SIZEOF_sockaddr_in  : constant := 16;
   SIZEOF_sockaddr_in6 : constant := 28;
   SIZEOF_sockaddr_un  : constant := 110;
   SIZEOF_socklen_t    : constant := 4;

   SIZEOF_tv_sec  : constant := 8;
   SIZEOF_tv_usec : constant := 8;
   MAX_tv_sec     : constant := 2 ** (SIZEOF_tv_sec * 8 - 1) - 1;

   SIZEOF_struct_hostent : constant := 32;
   SIZEOF_struct_servent : constant := 32;

   IOV_MAX    : constant := 1024;
   IF_NAMESIZE : constant := 16;

   --  struct addrinfo field offsets (akernel_gsocket.c layout:
   --  4 x int, socklen_t, 3 x pointer on a 64-bit target).

   AI_FLAGS_OFFSET     : constant := 0;
   AI_FAMILY_OFFSET    : constant := 4;
   AI_SOCKTYPE_OFFSET  : constant := 8;
   AI_PROTOCOL_OFFSET  : constant := 12;
   AI_ADDRLEN_OFFSET   : constant := 16;
   AI_ADDR_OFFSET      : constant := 24;
   AI_CANONNAME_OFFSET : constant := 32;
   AI_NEXT_OFFSET      : constant := 40;

   AI_PASSIVE     : constant := 1;
   AI_NUMERICHOST : constant := 4;

   NI_MAXHOST     : constant := 1025;
   NI_MAXSERV     : constant := 32;
   NI_NUMERICHOST : constant := 1;
   NI_NUMERICSERV : constant := 2;

   EAI_SYSTEM     : constant := -11;  --  check errno for details

   --  h_errno codes (HOST_NOT_FOUND etc.) live in their own space.

   HOST_NOT_FOUND : constant := 1;
   TRY_AGAIN      : constant := 2;
   NO_RECOVERY    : constant := 3;
   NO_DATA        : constant := 4;

   --  Errno values compared by the vendored Ada code — newlib's
   --  (sys/errno.h), the same space akernel_gsocket.c sets.
   --  ENOERROR is GNAT's own "no error" marker.

   ENOERROR       : constant := 0;
   EINTR          : constant := 4;
   EIO            : constant := 5;
   EBADF          : constant := 9;
   EAGAIN         : constant := 11;
   EWOULDBLOCK    : constant := 11;   --  = EAGAIN in newlib
   EACCES         : constant := 13;
   EFAULT         : constant := 14;
   EINVAL         : constant := 22;
   EMFILE         : constant := 24;
   EPIPE          : constant := 32;
   EOPNOTSUPP     : constant := 95;
   EPFNOSUPPORT   : constant := 96;
   ECONNRESET     : constant := 104;
   ENOBUFS        : constant := 105;
   EAFNOSUPPORT   : constant := 106;
   EPROTOTYPE     : constant := 107;
   ENOTSOCK       : constant := 108;
   ENOPROTOOPT    : constant := 109;
   ESHUTDOWN      : constant := 110;
   ECONNREFUSED   : constant := 111;
   EADDRINUSE     : constant := 112;
   ECONNABORTED   : constant := 113;
   ENETUNREACH    : constant := 114;
   ENETDOWN       : constant := 115;
   ETIMEDOUT      : constant := 116;
   EHOSTDOWN      : constant := 117;
   EHOSTUNREACH   : constant := 118;
   EINPROGRESS    : constant := 119;
   EALREADY       : constant := 120;
   EDESTADDRREQ   : constant := 121;
   EMSGSIZE       : constant := 122;
   EPROTONOSUPPORT : constant := 123;
   ESOCKTNOSUPPORT : constant := 124;
   EADDRNOTAVAIL  : constant := 125;
   ENETRESET      : constant := 126;
   EISCONN        : constant := 127;
   ENOTCONN       : constant := 128;
   ETOOMANYREFS   : constant := 129;
   ELOOP          : constant := 92;
   ENAMETOOLONG   : constant := 91;

   --  inet_pton/inet_ntop come from akernel_gsocket.c, not libc.

   Inet_Pton_Linkname : constant String := "__gnat_inet_pton";
   Inet_Ntop_Linkname : constant String := "__gnat_inet_ntop";

   subtype Msg_Iovlen_T is Interfaces.C.size_t;

end System.OS_Constants;
