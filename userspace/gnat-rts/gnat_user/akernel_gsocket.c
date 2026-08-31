/*  Akernel GNAT.Sockets C port layer (milestone 73): the ABI
 *  reference is gcc-15.3.0 gcc/ada/socket.c (the file the M72 plan
 *  called "gsocket.c") plus the imports of g-socthi/g-sothco.  All
 *  socket operations ride Akernel_User.Sockets (the aknet_sock_*
 *  exports of userspace/rts/akernel/akernel_user-sockets.adb), which
 *  implements the netserv endpoint protocol (UDP/ICMP/TCP over the
 *  vendored lwIP stack).  No host headers: the structs below ARE the
 *  akernel socket ABI, sized by gnat_user/s-oscons.ads.
 *
 *  fd space: 0..2 stay newlib's (console), 3..255 are this table
 *  (FD_SETSIZE 256, fd_set = 32-byte bit array).  Signalling fds for
 *  GNAT.Sockets selectors are in-process flag pairs living in the
 *  same table — selector abortion is always same-process, so no
 *  kernel object is needed.
 *
 *  Blocking ops poll the shared rings in 5 ms Sleep_Until slices,
 *  the RTS wait strategy.  IPs are host-order packed u32
 *  (a<<24|b<<16|c<<8|d) at the bridge; sockaddr_in carries network
 *  order bytes, matching GNAT.Sockets.Thin_Common's marshaling. */

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ------------------------------------------------------------------ */
/*  Akernel bridge (Akernel_User.Sockets C exports)                    */
/* ------------------------------------------------------------------ */

typedef unsigned long long ak_u64;
typedef unsigned int       ak_u32;

extern void    aknet_sock_attach (ak_u64 cap);
extern ak_u64  aknet_sock_endpoint (void);
extern ak_u64  aknet_sock_socket (ak_u64 proto, ak_u64 *handle);
extern ak_u64  aknet_sock_bind (ak_u64 handle, ak_u64 port,
                                ak_u64 *assigned);
extern ak_u64  aknet_sock_connect (ak_u64 handle, ak_u32 ip,
                                   ak_u64 port);
extern ak_u64  aknet_sock_listen (ak_u64 handle, ak_u64 backlog);
extern ak_u64  aknet_sock_accept (ak_u64 handle, ak_u64 *new_handle,
                                  ak_u32 *peer_ip, ak_u64 *peer_port);
extern ak_u64  aknet_sock_sendto (ak_u64 handle, const void *data,
                                  ak_u64 len, ak_u32 ip, ak_u64 port);
extern ak_u64  aknet_sock_recvfrom (ak_u64 handle, void *buf,
                                    ak_u64 max, ak_u64 timeout,
                                    ak_u32 *src_ip, ak_u64 *src_port,
                                    ak_u64 *count);
extern ak_u64  aknet_sock_poll (ak_u64 handle, ak_u64 *rx_level,
                                ak_u64 *tx_free, ak_u64 *error);
extern ak_u64  aknet_sock_close (ak_u64 handle);
extern ak_u64  aknet_sock_resolve (const void *name, ak_u64 len,
                                   ak_u32 *ip);

/*  Raw syscall stub (userspace/rts/akernel/syscalls-riscv64.s) */
extern ak_u64 akernel_sys_sleep_until (ak_u64 deadline);

/*  Tick clock: the riscv `time` CSR at 10 MHz, read from U-mode
 *  (akernel_rtclock.c) — the domain Sleep_Until deadlines live in.
 *  NOTE: syscall 34 (read_clock) is the WALL clock (seconds/ns
 *  from the RTC), a different domain — do not use it here. */
extern ak_u64 akernel_rdtime (void);

static ak_u64
ak_now (void)
{
   return akernel_rdtime ();
}

/* ------------------------------------------------------------------ */
/*  Constants (mirror gnat_user/s-oscons.ads; errno from newlib)       */
/* ------------------------------------------------------------------ */

#define AK_AF_INET   2

#define AK_SOCK_STREAM 1
#define AK_SOCK_DGRAM  2

#define AK_IPPROTO_ICMP 1
#define AK_IPPROTO_TCP  6
#define AK_IPPROTO_UDP  17

#define AK_SOL_SOCKET 1
#define AK_SO_ERROR     4

#define AK_MSG_PEEK 2

#define AK_FIONBIO  0x5421
#define AK_FIONREAD 0x541B

#define AK_POLLIN   1
#define AK_POLLOUT  4
#define AK_POLLERR  8
#define AK_POLLHUP  16
#define AK_POLLNVAL 32

/*  Bridge protocol statuses (akernel_user-sockets.ads) */
#define AK_ST_OK        0
#define AK_ST_TIMEOUT   1
#define AK_ST_NOT_READY 2
#define AK_ST_BAD_ARGS  3

/*  Bridge sticky error words (Op_Poll) */
#define AK_ERR_HAIRPIN  1   /*  hairpin to a closed local port */
#define AK_ERR_ARP      2   /*  ARP resolution failed */
#define AK_ERR_USAGE    3
#define AK_ERR_REFUSED  4   /*  TCP connect refused */
#define AK_ERR_CXTIME   5   /*  TCP connect timeout */
#define AK_ERR_RESET    6   /*  TCP reset */

/*  Time: Read_Time runs at 10 MHz */
#define AK_TICK_HZ   10000000ULL
#define AK_SLICE     50000ULL            /*  5 ms */

#define AK_FD_FIRST  3
#define AK_FD_MAX    256                 /*  == FD_SETSIZE */
#define AK_FDSET_BYTES 32                /*  256 bits */

#define AK_MAX_PAYLOAD 996               /*  ring slot payload */

/*  netdb codes */
#define AK_HOST_NOT_FOUND 1
#define AK_TRY_AGAIN      2
#define AK_NO_RECOVERY    3
#define AK_NO_DATA        4

/*  getaddrinfo codes (glibc values) */
#define AK_EAI_NONAME   (-2)
#define AK_EAI_AGAIN    (-3)
#define AK_EAI_FAIL     (-4)
#define AK_EAI_FAMILY   (-6)
#define AK_EAI_SOCKTYPE (-7)
#define AK_EAI_SERVICE  (-8)
#define AK_EAI_MEMORY   (-10)
#define AK_EAI_SYSTEM   (-11)

/* ------------------------------------------------------------------ */
/*  sockaddr layout (Have_Sockaddr_Len = False: plain u16 family)      */
/* ------------------------------------------------------------------ */

struct ak_sockaddr_in
{
   unsigned short sin_family;   /*  host order (AF_INET) */
   unsigned short sin_port;     /*  NETWORK order */
   unsigned char  sin_addr[4];  /*  network order bytes */
   char           sin_zero[8];
};

struct ak_pollfd
{
   int   fd;
   short events;
   short revents;
};

/*  struct hostent/servent layouts (SIZEOF_struct_hostent = 32) */
struct ak_hostent
{
   char  *h_name;
   char **h_aliases;
   int    h_addrtype;
   int    h_length;
   char **h_addr_list;
};

struct ak_servent
{
   char  *s_name;
   char **s_aliases;
   int    s_port;      /*  network order in the low 16 bits */
   char  *s_proto;
};

/*  struct addrinfo, offsets pinned by s-oscons AI_*_OFFSET */
struct ak_addrinfo
{
   int                  ai_flags;
   int                  ai_family;
   int                  ai_socktype;
   int                  ai_protocol;
   unsigned int         ai_addrlen;
   void                *ai_addr;
   char                *ai_canonname;
   struct ak_addrinfo  *ai_next;
};

/* ------------------------------------------------------------------ */
/*  fd table                                                           */
/* ------------------------------------------------------------------ */

#define AK_KIND_SOCK 1
#define AK_KIND_SIGR 2   /*  signalling pair, read end */
#define AK_KIND_SIGW 3   /*  signalling pair, write end */

#define AK_NOPT 8

struct ak_sock
{
   unsigned char  used;
   unsigned char  kind;
   unsigned char  proto;        /*  AK_IPPROTO_* */
   unsigned char  nonblock;
   unsigned char  listening;
   unsigned char  connected;    /*  peer known (connect/accept) */
   ak_u64         handle;       /*  akernel socket cap */
   ak_u32         local_ip;     /*  host-order packed */
   unsigned short local_port;   /*  host order */
   ak_u32         peer_ip;
   unsigned short peer_port;
   ak_u64         last_so_err;  /*  sticky error already reported */
   int            partner;      /*  signalling pair other end */
   unsigned int   sig_count;    /*  unread signalling bytes */
   struct { int level, name, val; } opts[AK_NOPT];
   int            nopts;
};

static struct ak_sock ak_fds[AK_FD_MAX];
static int            ak_h_errno;

static unsigned short
ak_sw16 (unsigned short v)
{
   return (unsigned short) ((v >> 8) | (v << 8));
}

static ak_u32
ak_addr_to_u32 (const unsigned char *b)
{
   return ((ak_u32) b[0] << 24) | ((ak_u32) b[1] << 16)
          | ((ak_u32) b[2] << 8) | (ak_u32) b[3];
}

static void
ak_u32_to_addr (ak_u32 ip, unsigned char *b)
{
   b[0] = (unsigned char) (ip >> 24);
   b[1] = (unsigned char) (ip >> 16);
   b[2] = (unsigned char) (ip >> 8);
   b[3] = (unsigned char) ip;
}

static void
ak_sleep_slice (void)
{
   (void) akernel_sys_sleep_until (ak_now () + AK_SLICE);
}

/*  Lazy binding to the netserv client endpoint: handle 6 of the
 *  uniform command ABI.  A program that attached its own handle
 *  (Akernel_User.Sockets.Attach) is left alone. */
static int
ak_ensure_net (void)
{
   if (aknet_sock_endpoint () == 0)
      aknet_sock_attach (6);
   return (aknet_sock_endpoint () != 0) ? 0 : -1;
}

static struct ak_sock *
ak_get (int fd)
{
   if (fd < AK_FD_FIRST || fd >= AK_FD_MAX || !ak_fds[fd].used)
      return NULL;
   return &ak_fds[fd];
}

static int
ak_alloc (void)
{
   int fd;

   for (fd = AK_FD_FIRST; fd < AK_FD_MAX; fd++)
      if (!ak_fds[fd].used)
         {
            memset (&ak_fds[fd], 0, sizeof ak_fds[fd]);
            ak_fds[fd].used = 1;
            ak_fds[fd].partner = -1;
            return fd;
         }
   errno = EMFILE;
   return -1;
}

/*  Map a bridge sticky error word to (newlib) errno. */
static int
ak_sticky_errno (ak_u64 err)
{
   switch (err)
     {
      case 0:               return 0;
      case AK_ERR_HAIRPIN:  return ECONNREFUSED;
      case AK_ERR_ARP:      return EHOSTUNREACH;
      case AK_ERR_REFUSED:  return ECONNREFUSED;
      case AK_ERR_CXTIME:   return ETIMEDOUT;
      case AK_ERR_RESET:    return ECONNRESET;
      default:              return EIO;
     }
}

/* ------------------------------------------------------------------ */
/*  BSD calls (imported by GNAT.Sockets.Thin)                          */
/* ------------------------------------------------------------------ */

int
socket (int domain, int type, int protocol)
{
   ak_u64 proto, handle;
   int    fd;

   if (ak_ensure_net () != 0)
      {
         errno = ENETDOWN;
         return -1;
      }
   if (domain != AK_AF_INET)
      {
         errno = EAFNOSUPPORT;
         return -1;
      }

   if (type == AK_SOCK_STREAM)
      proto = AK_IPPROTO_TCP;
   else if (type == AK_SOCK_DGRAM)
      proto = (protocol == AK_IPPROTO_ICMP) ? AK_IPPROTO_ICMP
                                            : AK_IPPROTO_UDP;
   else
      {
         errno = EOPNOTSUPP;
         return -1;
      }

   if (aknet_sock_socket (proto, &handle) != AK_ST_OK)
      {
         errno = ENOBUFS;
         return -1;
      }

   fd = ak_alloc ();
   if (fd < 0)
      {
         (void) aknet_sock_close (handle);
         return -1;
      }
   ak_fds[fd].kind   = AK_KIND_SOCK;
   ak_fds[fd].proto  = (unsigned char) proto;
   ak_fds[fd].handle = handle;
   return fd;
}

/*  Renamed from close (m73): newlib's close() owns file fds. */
int
__gnat_socket_close (int fd)
{
   struct ak_sock *s = ak_get (fd);

   if (s == NULL || s->kind != AK_KIND_SOCK)
      {
         errno = EBADF;
         return -1;
      }
   (void) aknet_sock_close (s->handle);
   s->used = 0;
   return 0;
}

int
bind (int fd, const void *name, int namelen)
{
   const struct ak_sockaddr_in *sin = name;
   struct ak_sock *s = ak_get (fd);
   ak_u64 assigned = 0;
   ak_u64 st;

   (void) namelen;
   if (s == NULL || s->kind != AK_KIND_SOCK)
      {
         errno = EBADF;
         return -1;
      }
   if (sin->sin_family != AK_AF_INET)
      {
         errno = EAFNOSUPPORT;
         return -1;
      }
   st = aknet_sock_bind (s->handle, ak_sw16 (sin->sin_port),
                         &assigned);
   if (st != AK_ST_OK)
      {
         errno = (st == AK_ST_BAD_ARGS) ? EINVAL : EADDRINUSE;
         return -1;
      }
   s->local_port = (unsigned short) assigned;
   s->local_ip   = ak_addr_to_u32 (sin->sin_addr);
   return 0;
}

/*  BSD auto-binds an unbound socket on first connect/send; mirror
 *  that so callers need not bind an ephemeral port by hand.  Only
 *  valid before connect: an accepted or connected socket is already
 *  bound on the netserv side. */
static int
ak_auto_bind (struct ak_sock *s)
{
   ak_u64 assigned = 0;

   if (s->local_port != 0)
      return 0;
   if (aknet_sock_bind (s->handle, 0, &assigned) != AK_ST_OK)
      {
         errno = EADDRNOTAVAIL;
         return -1;
      }
   s->local_port = (unsigned short) assigned;
   return 0;
}

int
connect (int fd, const void *name, int namelen)
{
   const struct ak_sockaddr_in *sin = name;
   struct ak_sock *s = ak_get (fd);
   ak_u64 st;

   (void) namelen;
   if (s == NULL || s->kind != AK_KIND_SOCK)
      {
         errno = EBADF;
         return -1;
      }
   if (sin->sin_family != AK_AF_INET)
      {
         errno = EAFNOSUPPORT;
         return -1;
      }
   if (ak_auto_bind (s) != 0)
      return -1;

   st = aknet_sock_connect (s->handle, ak_addr_to_u32 (sin->sin_addr),
                            ak_sw16 (sin->sin_port));
   if (st != AK_ST_OK)
      {
         /*  4 = refused, 5 = timeout at the protocol level */
         errno = (st == 4) ? ECONNREFUSED
               : (st == 5) ? ETIMEDOUT
               : EIO;
         return -1;
      }
   s->peer_ip   = ak_addr_to_u32 (sin->sin_addr);
   s->peer_port = ak_sw16 (sin->sin_port);
   s->connected = 1;
   return 0;
}

int
listen (int fd, int backlog)
{
   struct ak_sock *s = ak_get (fd);

   if (s == NULL || s->kind != AK_KIND_SOCK
       || s->proto != AK_IPPROTO_TCP)
      {
         errno = EOPNOTSUPP;
         return -1;
      }
   if (aknet_sock_listen (s->handle, (ak_u64) backlog) != AK_ST_OK)
      {
         errno = EIO;
         return -1;
      }
   s->listening = 1;
   return 0;
}

int
accept (int fd, void *addr, unsigned *addrlen)
{
   struct ak_sock *s = ak_get (fd);
   ak_u64 nh, peer_port = 0;
   ak_u32 peer_ip = 0;
   int    nfd;

   if (s == NULL || s->kind != AK_KIND_SOCK || !s->listening)
      {
         errno = EINVAL;
         return -1;
      }
   for (;;)
      {
         ak_u64 st = aknet_sock_accept (s->handle, &nh, &peer_ip,
                                        &peer_port);
         if (st == AK_ST_OK)
            break;
         if (st != AK_ST_NOT_READY)
            {
               errno = EIO;
               return -1;
            }
         if (s->nonblock)
            {
               errno = EWOULDBLOCK;
               return -1;
            }
         ak_sleep_slice ();
      }

   nfd = ak_alloc ();
   if (nfd < 0)
      {
         (void) aknet_sock_close (nh);
         return -1;
      }
   ak_fds[nfd].kind      = AK_KIND_SOCK;
   ak_fds[nfd].proto     = AK_IPPROTO_TCP;
   ak_fds[nfd].handle    = nh;
    ak_fds[nfd].connected = 1;
    ak_fds[nfd].peer_ip   = peer_ip;
    ak_fds[nfd].peer_port = (unsigned short) peer_port;
    ak_fds[nfd].local_ip   = s->local_ip;
    ak_fds[nfd].local_port = s->local_port;

   if (addr != NULL && addrlen != NULL)
      {
         struct ak_sockaddr_in *sin = addr;

         memset (sin, 0, sizeof *sin);
         sin->sin_family = AK_AF_INET;
         sin->sin_port   = ak_sw16 ((unsigned short) peer_port);
         ak_u32_to_addr (peer_ip, sin->sin_addr);
         *addrlen = sizeof *sin;
      }
   return nfd;
}

/*  Shared receive worker.  Returns the byte count, 0 on orderly TCP
 *  EOF, or -1 with errno set. */
static int
ak_recv (struct ak_sock *s, void *buf, int len, int flags,
         ak_u32 *src_ip, ak_u64 *src_port)
{
   if (flags & AK_MSG_PEEK)
      {
         errno = EOPNOTSUPP;
         return -1;
      }

   for (;;)
      {
         ak_u64 count = 0;
         ak_u64 st = aknet_sock_recvfrom (s->handle, buf, (ak_u64) len,
                                          0, src_ip, src_port, &count);
         if (st == AK_ST_OK)
            {
                if (count > 0)
                   return (int) count;

               /*  TCP EOF marker: orderly close or reset. */
               if (s->proto == AK_IPPROTO_TCP)
                  {
                     ak_u64 rx, tx, err;

                     if (aknet_sock_poll (s->handle, &rx, &tx, &err)
                           == AK_ST_OK && err != 0)
                        {
                           errno = ak_sticky_errno (err);
                           return -1;
                        }
                     return 0;
                  }
               /*  UDP never returns a zero datagram from us. */
               continue;
            }
          if (st == AK_ST_TIMEOUT || st == AK_ST_NOT_READY)
             {
                if (s->nonblock)
                   {
                      errno = EWOULDBLOCK;
                      return -1;
                   }
                ak_sleep_slice ();
                continue;
             }
          errno = (st == AK_ST_BAD_ARGS) ? EBADF : EIO;
          return -1;
       }
}

int
recv (int fd, void *msg, int len, int flags)
{
   struct ak_sock *s = ak_get (fd);
   ak_u32 sip;
   ak_u64 sport;

   if (s == NULL || s->kind != AK_KIND_SOCK)
      {
         errno = EBADF;
         return -1;
      }
   /*  The bridge export stores through all its out-pointers. */
   return ak_recv (s, msg, len, flags, &sip, &sport);
}

int
recvfrom (int fd, void *msg, int len, int flags, void *from,
          unsigned *fromlen)
{
   struct ak_sock *s = ak_get (fd);
   ak_u32 sip = 0;
   ak_u64 sport = 0;
   int    n;

   if (s == NULL || s->kind != AK_KIND_SOCK)
      {
         errno = EBADF;
         return -1;
      }
   n = ak_recv (s, msg, len, flags, &sip, &sport);
   if (n > 0 && from != NULL && fromlen != NULL)
      {
         struct ak_sockaddr_in *sin = from;

         memset (sin, 0, sizeof *sin);
         sin->sin_family = AK_AF_INET;
         sin->sin_port   = ak_sw16 ((unsigned short) sport);
         ak_u32_to_addr (sip, sin->sin_addr);
         *fromlen = sizeof *sin;
      }
   return n;
}

/*  Shared send worker: one datagram (UDP) or a chunked stream (TCP).
 *  Returns the byte count or -1. */
static int
ak_send (struct ak_sock *s, const void *buf, int len, ak_u32 dst_ip,
         ak_u64 dst_port)
{
   int sent = 0;

   if (s->proto != AK_IPPROTO_TCP)
      {
         /*  One datagram per ring slot; no IP fragmentation. */
         if (len > AK_MAX_PAYLOAD)
            {
               errno = EMSGSIZE;
               return -1;
            }
         for (;;)
            {
               ak_u64 st = aknet_sock_sendto (s->handle, buf,
                                              (ak_u64) len, dst_ip,
                                              dst_port);
               if (st == AK_ST_OK)
                  return len;
               if (st == AK_ST_NOT_READY || st == AK_ST_TIMEOUT)
                  {
                     if (s->nonblock)
                        {
                           errno = EWOULDBLOCK;
                           return -1;
                        }
                     ak_sleep_slice ();
                     continue;
                  }
               errno = (len == 0 || st == AK_ST_BAD_ARGS) ? EINVAL : EIO;
               return -1;
            }
      }

   while (sent < len)
      {
         int chunk = len - sent;

         if (chunk > AK_MAX_PAYLOAD)
            chunk = AK_MAX_PAYLOAD;

         /*  A dead connection surfaces via the sticky error. */
           {
              ak_u64 rx, tx, err;

              if (aknet_sock_poll (s->handle, &rx, &tx, &err) == AK_ST_OK
                  && err != 0)
                 {
                    errno = ak_sticky_errno (err);
                    return -1;
                 }
           }

           {
              ak_u64 st = aknet_sock_sendto (s->handle,
                                             (const char *) buf + sent,
                                             (ak_u64) chunk, 0, 0);
              if (st == AK_ST_OK)
                 {
                    sent += chunk;
                    continue;
                 }
              if (st == AK_ST_NOT_READY || st == AK_ST_TIMEOUT)
                 {
                    if (s->nonblock)
                       {
                          errno = EWOULDBLOCK;
                          return sent > 0 ? sent : -1;
                       }
                    ak_sleep_slice ();
                    continue;
                 }
              errno = EIO;
              return -1;
           }
      }
   return sent;
}

int
sendto (int fd, const void *msg, int len, int flags, const void *to,
        int tolen)
{
   struct ak_sock *s = ak_get (fd);
   ak_u32 dst_ip = 0;
   ak_u64 dst_port = 0;

   (void) flags;   /*  MSG_Forced_Flags is 0; nothing else supported */
   if (s == NULL || s->kind != AK_KIND_SOCK)
      {
         errno = EBADF;
         return -1;
      }
   if (to != NULL && tolen > 0)
      {
         const struct ak_sockaddr_in *sin = to;

         if (sin->sin_family != AK_AF_INET)
            {
               errno = EAFNOSUPPORT;
               return -1;
            }
         dst_ip   = ak_addr_to_u32 (sin->sin_addr);
         dst_port = ak_sw16 (sin->sin_port);
      }
    else if (!s->connected)
       {
          errno = EDESTADDRREQ;
          return -1;
       }
    if (!s->connected && ak_auto_bind (s) != 0)
       return -1;
    return ak_send (s, msg, len, dst_ip, dst_port);
}

int
getsockname (int fd, void *name, unsigned *namelen)
{
   struct ak_sock *s = ak_get (fd);
   struct ak_sockaddr_in *sin = name;

   if (s == NULL || s->kind != AK_KIND_SOCK)
      {
         errno = EBADF;
         return -1;
      }
   memset (sin, 0, sizeof *sin);
   sin->sin_family = AK_AF_INET;
   sin->sin_port   = ak_sw16 (s->local_port);
   ak_u32_to_addr (s->local_ip, sin->sin_addr);
   *namelen = sizeof *sin;
   return 0;
}

int
getpeername (int fd, void *name, unsigned *namelen)
{
   struct ak_sock *s = ak_get (fd);
   struct ak_sockaddr_in *sin = name;

   if (s == NULL || s->kind != AK_KIND_SOCK)
      {
         errno = EBADF;
         return -1;
      }
   if (!s->connected)
      {
         errno = ENOTCONN;
         return -1;
      }
   memset (sin, 0, sizeof *sin);
   sin->sin_family = AK_AF_INET;
   sin->sin_port   = ak_sw16 (s->peer_port);
   ak_u32_to_addr (s->peer_ip, sin->sin_addr);
   *namelen = sizeof *sin;
   return 0;
}

int
getsockopt (int fd, int level, int optname, void *optval,
            unsigned *optlen)
{
   struct ak_sock *s = ak_get (fd);
   int i;

   if (s == NULL || s->kind != AK_KIND_SOCK)
      {
         errno = EBADF;
         return -1;
      }

   if (level == AK_SOL_SOCKET && optname == AK_SO_ERROR)
      {
         /*  The bridge keeps the error sticky; BSD clears SO_ERROR
          *  once read, so report each value once. */
         ak_u64 rx, tx, err = 0;
         int    val = 0;

         if (aknet_sock_poll (s->handle, &rx, &tx, &err) == AK_ST_OK
             && err != 0 && err != s->last_so_err)
            val = ak_sticky_errno (err);
         s->last_so_err = err;
         *(int *) optval = val;
         *optlen = sizeof (int);
         return 0;
      }

   for (i = 0; i < s->nopts; i++)
      if (s->opts[i].level == level && s->opts[i].name == optname)
         {
            *(int *) optval = s->opts[i].val;
            *optlen = sizeof (int);
            return 0;
         }
   *(int *) optval = 0;
   *optlen = sizeof (int);
   return 0;
}

int
setsockopt (int fd, int level, int optname, const void *optval,
            unsigned optlen)
{
   struct ak_sock *s = ak_get (fd);
   int i;

   (void) optlen;
   if (s == NULL || s->kind != AK_KIND_SOCK)
      {
         errno = EBADF;
         return -1;
      }
   if (level == AK_SOL_SOCKET && optname == AK_SO_ERROR)
      {
         errno = EINVAL;
         return -1;
      }
   /*  Stored only: buffer sizes are fixed by the ring geometry,
    *  keepalive/nodelay have no knobs in the stack. */
   for (i = 0; i < s->nopts; i++)
      if (s->opts[i].level == level && s->opts[i].name == optname)
         {
            s->opts[i].val = *(const int *) optval;
            return 0;
         }
   if (s->nopts == AK_NOPT)
      {
         errno = ENOBUFS;
         return -1;
      }
   s->opts[s->nopts].level = level;
   s->opts[s->nopts].name  = optname;
   s->opts[s->nopts].val   = *(const int *) optval;
   s->nopts++;
   return 0;
}

int
shutdown (int fd, int how)
{
   /*  No half-close in the protocol; GNAT.Sockets.Shutdown_Socket
    *  is a deliberate user call, not on any implicit path. */
   (void) how;
   return (ak_get (fd) != NULL) ? 0 : -1;
}

int
socketpair (int domain, int type, int protocol, int *fds)
{
   (void) domain; (void) type; (void) protocol; (void) fds;
   errno = EOPNOTSUPP;   /*  no AF_UNIX */
   return -1;
}

int
gethostname (char *name, size_t namelen)
{
   static const char me[] = "akernel";

   if (namelen < sizeof me)
      {
         errno = EINVAL;
         return -1;
      }
   memcpy (name, me, sizeof me);
   return 0;
}

long
recvmsg (int fd, void *msg, int flags)
{
   (void) fd; (void) msg; (void) flags;
   errno = ENOSYS;   /*  no scatter/gather in the ring ABI */
   return -1;
}

long
sendmsg (int fd, void *msg, int flags)
{
   (void) fd; (void) msg; (void) flags;
   errno = ENOSYS;
   return -1;
}

/* ------------------------------------------------------------------ */
/*  fd_set helpers (bit array over fds 0..255)                         */
/* ------------------------------------------------------------------ */

static int
ak_isset (const unsigned char *set, int fd)
{
   return (set[fd >> 3] >> (fd & 7)) & 1;
}

static void
ak_setbit (unsigned char *set, int fd)
{
   set[fd >> 3] |= (unsigned char) (1 << (fd & 7));
}

static void
ak_clrbit (unsigned char *set, int fd)
{
   set[fd >> 3] &= (unsigned char) ~(1 << (fd & 7));
}

void
__gnat_last_socket_in_set (unsigned char *set, int *last)
{
   int l = -1;
   int s;

   for (s = *last; s >= 0; s--)
      if (ak_isset (set, s))
         {
            l = s;
            break;
         }
   *last = l;
}

void
__gnat_get_socket_from_set (unsigned char *set, int *last, int *sk)
{
   *sk = *last;
   ak_clrbit (set, *sk);
   __gnat_last_socket_in_set (set, last);
}

void
__gnat_insert_socket_in_set (unsigned char *set, int sk)
{
   ak_setbit (set, sk);
}

int
__gnat_is_socket_in_set (unsigned char *set, int sk)
{
   return ak_isset (set, sk);
}

void
__gnat_remove_socket_from_set (unsigned char *set, int sk)
{
   ak_clrbit (set, sk);
}

void
__gnat_reset_socket_set (unsigned char *set)
{
   memset (set, 0, AK_FDSET_BYTES);
}

/* ------------------------------------------------------------------ */
/*  select/poll readiness                                              */
/* ------------------------------------------------------------------ */

/*  1 readable, 2 writable, 4 except — bit mask of current state. */
static int
ak_ready (int fd)
{
   struct ak_sock *s = ak_get (fd);
   ak_u64 rx = 0, tx = 0, err = 0;
   int    m = 0;

   if (s == NULL)
      return 0;
   if (s->kind == AK_KIND_SIGR)
      return (s->sig_count > 0) ? 1 : 0;
   if (s->kind == AK_KIND_SIGW)
      return 2;   /*  in-memory pair: always writable */
   if (s->kind != AK_KIND_SOCK)
      return 0;

   if (aknet_sock_poll (s->handle, &rx, &tx, &err) != AK_ST_OK)
      return 4;
   if (err != 0)
      return 1 | 2 | 4;
   if (rx > 0)
      m |= 1;          /*  data, EOF marker, or accept backlog */
   if (tx > 0 && !s->listening)
      m |= 2;
   return m;
}

struct ak_timeval
{
   long long tv_sec;
   long long tv_usec;
};

int
select (int nfds, unsigned char *readfds, unsigned char *writefds,
        unsigned char *exceptfds, struct ak_timeval *timeout)
{
   ak_u64 deadline = 0;
   int    infinite = (timeout == NULL);

   if (!infinite)
      deadline = ak_now ()
                 + (ak_u64) timeout->tv_sec * AK_TICK_HZ
                 + (ak_u64) timeout->tv_usec * (AK_TICK_HZ / 1000000ULL);
   if (nfds > AK_FD_MAX)
      nfds = AK_FD_MAX;

   for (;;)
      {
         int nready = 0;
         int fd;

         for (fd = 0; fd < nfds; fd++)
            {
               int m = 0;

               if ((readfds && ak_isset (readfds, fd))
                   || (writefds && ak_isset (writefds, fd))
                   || (exceptfds && ak_isset (exceptfds, fd)))
                  m = ak_ready (fd);
               if (readfds && ak_isset (readfds, fd))
                  {
                     if (m & 1)
                        nready++;
                     else
                        ak_clrbit (readfds, fd);
                  }
               if (writefds && ak_isset (writefds, fd))
                  {
                     if (m & 2)
                        nready++;
                     else
                        ak_clrbit (writefds, fd);
                  }
               if (exceptfds && ak_isset (exceptfds, fd))
                  {
                     if (m & 4)
                        nready++;
                     else
                        ak_clrbit (exceptfds, fd);
                  }
            }

         if (nready > 0)
            return nready;
         if (!infinite && ak_now () >= deadline)
            return 0;
         ak_sleep_slice ();
      }
}

int
poll (struct ak_pollfd *fds, unsigned long nfds, int timeout_ms)
{
   ak_u64 deadline = ak_now ()
                     + (ak_u64) timeout_ms * (AK_TICK_HZ / 1000ULL);
   int    infinite = (timeout_ms < 0);

   for (;;)
      {
         int nready = 0;
         unsigned long i;

         for (i = 0; i < nfds; i++)
            {
               struct ak_pollfd *p = &fds[i];
               int m = ak_ready (p->fd);

               p->revents = 0;
               if (ak_get (p->fd) == NULL)
                  {
                     p->revents = AK_POLLNVAL;
                     nready++;
                     continue;
                  }
               if ((p->events & AK_POLLIN) && (m & 1))
                  p->revents |= AK_POLLIN;
               if ((p->events & AK_POLLOUT) && (m & 2))
                  p->revents |= AK_POLLOUT;
               if (m & 4)
                  p->revents |= AK_POLLERR;
               if (p->revents != 0)
                  nready++;
            }

         if (nready > 0)
            return nready;
         if (!infinite && ak_now () >= deadline)
            return 0;
         ak_sleep_slice ();
      }
}

int
__gnat_socket_ioctl (int fd, int req, int *arg)
{
   struct ak_sock *s = ak_get (fd);

   if (s == NULL || s->kind != AK_KIND_SOCK)
      {
         errno = EBADF;
         return -1;
      }
   if (req == AK_FIONBIO)
      {
         s->nonblock = (*arg != 0);
         return 0;
      }
   if (req == AK_FIONREAD)
      {
         /*  The ring knows slots, not bytes: report an upper bound
          *  (only used for N_Bytes_To_Read control queries). */
         ak_u64 rx = 0, tx = 0, err = 0;

         if (aknet_sock_poll (s->handle, &rx, &tx, &err) != AK_ST_OK)
            {
               errno = EIO;
               return -1;
            }
         *arg = (int) (rx * AK_MAX_PAYLOAD);
         return 0;
      }
   errno = EINVAL;
   return -1;
}

/* ------------------------------------------------------------------ */
/*  Signalling fds (in-process selector abort pairs)                   */
/* ------------------------------------------------------------------ */

int
__gnat_create_signalling_fds (int *fds)
{
   int r = ak_alloc ();
   int w;

   if (r < 0)
      return -1;
   w = ak_alloc ();
   if (w < 0)
      {
         ak_fds[r].used = 0;
         return -1;
      }
   ak_fds[r].kind = AK_KIND_SIGR;
   ak_fds[w].kind = AK_KIND_SIGW;
   ak_fds[r].partner = w;
   ak_fds[w].partner = r;
   fds[0] = r;
   fds[1] = w;
   return 0;
}

int
__gnat_read_signalling_fd (int rsig)
{
   struct ak_sock *s = ak_get (rsig);

   if (s == NULL || s->kind != AK_KIND_SIGR)
      {
         errno = EBADF;
         return -1;
      }
   if (s->sig_count == 0)
      {
         errno = EWOULDBLOCK;
         return -1;
      }
   s->sig_count--;
   return 1;
}

int
__gnat_write_signalling_fd (int wsig)
{
   struct ak_sock *s = ak_get (wsig);

   if (s == NULL || s->kind != AK_KIND_SIGW)
      {
         errno = EBADF;
         return -1;
      }
   {
      struct ak_sock *r = ak_get (s->partner);

      if (r == NULL)
         {
            errno = EPIPE;
            return -1;
         }
      r->sig_count++;
   }
   return 1;
}

void
__gnat_close_signalling_fd (int sig)
{
   struct ak_sock *s = ak_get (sig);

   if (s != NULL)
      s->used = 0;
}

void
__gnat_disable_sigpipe (int fd)
{
   (void) fd;   /*  no SIGPIPE exists here */
}

void
__gnat_disable_all_sigpipes (void)
{
}

/* ------------------------------------------------------------------ */
/*  errno/h_errno                                                      */
/* ------------------------------------------------------------------ */

int
aknet_get_errno (void)
{
   return errno;
}

int
__gnat_get_h_errno (void)
{
   return ak_h_errno;
}

/* ------------------------------------------------------------------ */
/*  inet_pton / inet_ntop                                              */
/* ------------------------------------------------------------------ */

/*  Parse dotted decimal into 4 network-order bytes.  Returns 1 ok,
 *  0 malformed. */
static int
ak_parse_dotted (const char *src, unsigned char *dst)
{
   int part = 0, val = 0, digits = 0;

   for (;; src++)
      {
         char c = *src;

         if (c >= '0' && c <= '9')
            {
               val = val * 10 + (c - '0');
               if (val > 255)
                  return 0;
               digits++;
               continue;
            }
         if ((c == '.' || c == '\0' || c == ' ' || c == '\n'
              || c == '\r' || c == '\t') && digits > 0)
            {
               dst[part++] = (unsigned char) val;
               val = 0;
               digits = 0;
               if (c != '.')   /*  NUL/space/newline: done */
                  break;
               if (part == 4)
                  return 0;   /*  too many parts */
               continue;
            }
         return 0;
      }
   return (part == 4) ? 1 : 0;
}

int
__gnat_inet_pton (int af, const char *src, void *dst)
{
   if (af != AK_AF_INET)
      {
         errno = EAFNOSUPPORT;
         return -1;
      }
   return ak_parse_dotted (src, dst);
}

const char *
__gnat_inet_ntop (int af, const void *src, char *dst, unsigned size)
{
   const unsigned char *b = src;

   if (af != AK_AF_INET)
      {
         errno = EAFNOSUPPORT;
         return NULL;
      }
   if (snprintf (dst, size, "%u.%u.%u.%u", b[0], b[1], b[2], b[3])
         >= (int) size)
      {
         errno = ENOSPC;
         return NULL;
      }
   return dst;
}

/* ------------------------------------------------------------------ */
/*  netdb: host/service lookups                                        */
/* ------------------------------------------------------------------ */

static char               ak_he_name[256];
static char              *ak_he_aliases[1] = { NULL };
static unsigned char      ak_he_addr[4];
static char              *ak_he_addr_list[2];
static struct ak_hostent  ak_he;

static char              *ak_se_aliases[1] = { NULL };
static struct ak_servent  ak_se;

struct ak_svent { const char *name; unsigned short port; };
static const struct ak_svent ak_services[] = {
   { "echo", 7 }, { "discard", 9 }, { "daytime", 13 },
   { "ftp", 21 }, { "ssh", 22 }, { "telnet", 23 },
   { "domain", 53 }, { "http", 80 }, { "ntp", 123 },
};

static void
ak_fill_hostent (const char *name, const unsigned char *ip)
{
   size_t n = strlen (name);

   if (n >= sizeof ak_he_name)
      n = sizeof ak_he_name - 1;
   memcpy (ak_he_name, name, n);
   ak_he_name[n] = '\0';
   memcpy (ak_he_addr, ip, 4);
   ak_he_addr_list[0] = (char *) ak_he_addr;
   ak_he_addr_list[1] = NULL;
   ak_he.h_name      = ak_he_name;
   ak_he.h_aliases   = ak_he_aliases;
   ak_he.h_addrtype  = AK_AF_INET;
   ak_he.h_length    = 4;
   ak_he.h_addr_list = ak_he_addr_list;
}

/*  DNS via the netserv-resident resolver (m78a): Op_Resolve on
 *  the netserv endpoint (lwIP dns.c inside netserv, queries go
 *  to the Net:dns server).  Returns 1 with *ip filled, 0 on
 *  failure. */
static int
ak_dns_query (const char *name, unsigned char *ip);

static void
ak_fill_servent (const char *name, unsigned short port,
                 const char *proto)
{
   ak_se.s_name    = (char *) name;
   ak_se.s_aliases = ak_se_aliases;
   ak_se.s_port    = ak_sw16 (port);
   ak_se.s_proto   = (char *) proto;
}

int
__gnat_gethostbyname (const char *name, struct ak_hostent *ret,
                      char *buf, size_t buflen, int *h_errnop)
{
   unsigned char ip[4];

   (void) buf; (void) buflen;   /*  caller serializes via Task_Lock */

   if (ak_parse_dotted (name, ip))
      {
         ak_fill_hostent (name, ip);
         *ret = ak_he;
         *h_errnop = 0;
         return 0;
      }

   if (ak_dns_query (name, ip))
      {
         ak_fill_hostent (name, ip);
         *ret = ak_he;
         *h_errnop = 0;
         return 0;
      }

   *h_errnop = ak_h_errno ? ak_h_errno : AK_HOST_NOT_FOUND;
   return -1;
}

int
__gnat_gethostbyaddr (const char *addr, int len, int type,
                      struct ak_hostent *ret, char *buf, size_t buflen,
                      int *h_errnop)
{
   char dotted[16];

   (void) len; (void) buf; (void) buflen;
   if (type != AK_AF_INET)
      {
         *h_errnop = AK_NO_DATA;
         return -1;
      }
   /*  No reverse DNS here: resolve numerically (dotted name), so
    *  Get_Host_By_Name on a dotted string works as GNAT.Sockets
    *  documents it. */
   (void) __gnat_inet_ntop (AK_AF_INET, addr, dotted,
                            sizeof dotted);
   ak_fill_hostent (dotted, (const unsigned char *) addr);
   *ret = ak_he;
   *h_errnop = 0;
   return 0;
}

/*  Plain non-reentrant reverse lookup, imported directly by
 *  g-socthi.adb's Nonreentrant_Gethostbyaddr (POSIX signature,
 *  NULL on failure).  Not provided by newlib, so no collision. */
void *
gethostbyaddr (const void *addr, int len, int type)
{
   char dotted[16];

   (void) len;
   if (type != AK_AF_INET)
      {
         ak_h_errno = AK_NO_DATA;
         return NULL;
      }
   (void) __gnat_inet_ntop (AK_AF_INET, addr, dotted,
                            sizeof dotted);
   ak_fill_hostent (dotted, (const unsigned char *) addr);
   return &ak_he;
}

int
__gnat_getservbyname (const char *name, const char *proto,
                      struct ak_servent *ret, char *buf, size_t buflen)
{
   unsigned i;

   (void) buf; (void) buflen;
   for (i = 0; i < sizeof ak_services / sizeof ak_services[0]; i++)
      if (strcmp (name, ak_services[i].name) == 0)
         {
            ak_fill_servent (ak_services[i].name, ak_services[i].port,
                             proto);
            *ret = ak_se;
            return 0;
         }
   return -1;
}

int
__gnat_getservbyport (int port, const char *proto,
                      struct ak_servent *ret, char *buf, size_t buflen)
{
   unsigned i;

   (void) buf; (void) buflen;
   for (i = 0; i < sizeof ak_services / sizeof ak_services[0]; i++)
      if ((int) ak_services[i].port == (int) ak_sw16 ((unsigned short)
                                                      port)
          || (int) ak_services[i].port == port)
         {
            ak_fill_servent (ak_services[i].name, ak_services[i].port,
                             proto);
            *ret = ak_se;
            return 0;
         }
   return -1;
}

char *
__gnat_hostent_h_name (struct ak_hostent *h)
{
   return h->h_name;
}

char *
__gnat_hostent_h_alias (struct ak_hostent *h, int index)
{
   return h->h_aliases[index];
}

int
__gnat_hostent_h_addrtype (struct ak_hostent *h)
{
   return h->h_addrtype;
}

int
__gnat_hostent_h_length (struct ak_hostent *h)
{
   return h->h_length;
}

char *
__gnat_hostent_h_addr (struct ak_hostent *h, int index)
{
   return h->h_addr_list[index];
}

char *
__gnat_servent_s_name (struct ak_servent *s)
{
   return s->s_name;
}

char *
__gnat_servent_s_alias (struct ak_servent *s, int index)
{
   return s->s_aliases[index];
}

unsigned short
__gnat_servent_s_port (struct ak_servent *s)
{
   return (unsigned short) s->s_port;
}

char *
__gnat_servent_s_proto (struct ak_servent *s)
{
   return s->s_proto;
}

/* ------------------------------------------------------------------ */
/*  DNS (m78a): netserv-resident resolver                              */
/* ------------------------------------------------------------------ */

/*  A-record lookup through netserv's Op_Resolve (lwIP dns.c owns
 *  the wire protocol, the cache and the retry/timeout budget; the
 *  server is netserv's DNS_IP — the writable Net:dns file).  The
 *  m73 hand-rolled query (one ephemeral UDP socket per lookup,
 *  fixed txid, client-side answer parsing) is gone.  Returns 1
 *  with *ip filled (network order bytes), 0 on failure with
 *  ak_h_errno set: the wire no longer distinguishes NXDOMAIN from
 *  a silent timeout (lwIP's found callback reports NULL for
 *  both), so a failed lookup maps to HOST_NOT_FOUND and a
 *  resolver-table-full rejection to TRY_AGAIN. */
static int
ak_dns_query (const char *name, unsigned char *ip)
{
   ak_u32 out_ip = 0;
   ak_u64 st;

   if (ak_ensure_net () != 0)
      return 0;
   st = aknet_sock_resolve (name, (ak_u64) strlen (name), &out_ip);
   if (st == AK_ST_OK)
      {
         ak_u32_to_addr (out_ip, ip);
         return 1;
      }
   ak_h_errno = (st == AK_ST_NOT_READY) ? AK_TRY_AGAIN
                                        : AK_HOST_NOT_FOUND;
   return 0;
}

/* ------------------------------------------------------------------ */
/*  getaddrinfo family                                                 */
/* ------------------------------------------------------------------ */

/*  Own IPv4 address from Net:address (fallback 10.0.2.15). */
static ak_u32
ak_own_address (void)
{
   unsigned char b[4];
   char          buf[64];
   FILE         *f = fopen ("Net:address", "r");

   if (f != NULL)
      {
         size_t n = fread (buf, 1, sizeof buf - 1, f);

         fclose (f);
         buf[n] = '\0';
         if (ak_parse_dotted (buf, b))
            return ak_addr_to_u32 (b);
      }
   return 0x0A00020FU;   /*  10.0.2.15 */
}

static struct ak_addrinfo *
ak_mk_addrinfo (ak_u32 ip_host, unsigned short port, int socktype,
                int protocol, int flags)
{
   struct ak_addrinfo     *ai = malloc (sizeof *ai);
   struct ak_sockaddr_in  *sa = malloc (sizeof *sa);

   if (ai == NULL || sa == NULL)
      {
         free (ai);
         free (sa);
         return NULL;
      }
   memset (sa, 0, sizeof *sa);
   sa->sin_family = AK_AF_INET;
   sa->sin_port   = ak_sw16 (port);
   ak_u32_to_addr (ip_host, sa->sin_addr);

   ai->ai_flags     = flags;
   ai->ai_family    = AK_AF_INET;
   ai->ai_socktype  = socktype;
   ai->ai_protocol  = protocol;
   ai->ai_addrlen   = sizeof *sa;
   ai->ai_addr      = sa;
   ai->ai_canonname = NULL;
   ai->ai_next      = NULL;
   return ai;
}

int
__gnat_getaddrinfo (const char *node, const char *service,
                    const struct ak_addrinfo *hints,
                    struct ak_addrinfo **res)
{
   int            family   = hints ? hints->ai_family : 0;
   int            socktype = hints ? hints->ai_socktype : 0;
   int            flags    = hints ? hints->ai_flags : 0;
   ak_u32         ip = 0;
   unsigned short port = 0;
   unsigned char  b[4];
   struct ak_addrinfo *head = NULL, **tail = &head;

   if (family != 0 && family != AK_AF_INET)
      return AK_EAI_FAMILY;
   if (socktype != 0 && socktype != AK_SOCK_STREAM
       && socktype != AK_SOCK_DGRAM)
      return AK_EAI_SOCKTYPE;

   if (node == NULL || node[0] == '\0')
      /*  No loopback interface: the hairpin is our own address. */
      ip = (flags & 1) ? 0 : ak_own_address ();   /*  AI_PASSIVE=1 */
   else if (ak_parse_dotted (node, b))
      ip = ak_addr_to_u32 (b);
   else if (flags & 4)                 /*  AI_NUMERICHOST */
      return AK_EAI_NONAME;
   else if (ak_dns_query (node, b))
      ip = ak_addr_to_u32 (b);
   else
      return AK_EAI_NONAME;

   if (service != NULL && service[0] != '\0')
      {
         char *end = NULL;
         long  v = strtol (service, &end, 10);

         if (end != NULL && *end == '\0' && v >= 0 && v <= 65535)
            port = (unsigned short) v;
         else
            {
               unsigned i;

               for (i = 0;
                    i < sizeof ak_services / sizeof ak_services[0];
                    i++)
                  if (strcmp (service, ak_services[i].name) == 0)
                     {
                        port = ak_services[i].port;
                        break;
                     }
               if (port == 0)
                  return AK_EAI_SERVICE;
            }
      }

   if (socktype == 0 || socktype == AK_SOCK_STREAM)
      {
         struct ak_addrinfo *ai = ak_mk_addrinfo (ip, port,
                                                  AK_SOCK_STREAM,
                                                  AK_IPPROTO_TCP,
                                                  flags);
         if (ai == NULL)
            goto enomem;
         *tail = ai;
         tail = &ai->ai_next;
      }
   if (socktype == 0 || socktype == AK_SOCK_DGRAM)
      {
         struct ak_addrinfo *ai = ak_mk_addrinfo (ip, port,
                                                  AK_SOCK_DGRAM,
                                                  AK_IPPROTO_UDP,
                                                  flags);
         if (ai == NULL)
            goto enomem;
         *tail = ai;
         tail = &ai->ai_next;
      }

   *res = head;
   return 0;

enomem:
   while (head != NULL)
      {
         struct ak_addrinfo *next = head->ai_next;

         free (head->ai_addr);
         free (head);
         head = next;
      }
   return AK_EAI_MEMORY;
}

int
__gnat_getnameinfo (const void *sa, unsigned salen, char *host,
                    size_t hostlen, char *serv, size_t servlen,
                    int flags)
{
   const struct ak_sockaddr_in *sin = sa;

   (void) salen; (void) flags;
   if (sin->sin_family != AK_AF_INET)
      return AK_EAI_FAMILY;
   if (host != NULL)
      {
         if (__gnat_inet_ntop (AK_AF_INET, sin->sin_addr, host,
                               (unsigned) hostlen) == NULL)
            return AK_EAI_SYSTEM;
      }
   if (serv != NULL)
      {
         if (snprintf (serv, servlen, "%u",
                       (unsigned) ak_sw16 (sin->sin_port))
               >= (int) servlen)
            return AK_EAI_SYSTEM;
      }
   return 0;
}

void
__gnat_freeaddrinfo (struct ak_addrinfo *res)
{
   while (res != NULL)
      {
         struct ak_addrinfo *next = res->ai_next;

         free (res->ai_addr);
         free (res->ai_canonname);
         free (res);
         res = next;
      }
}

const char *
__gnat_gai_strerror (int errcode)
{
   switch (errcode)
     {
      case AK_EAI_AGAIN:
         return "Temporary failure in name resolution.";
      case AK_EAI_FAIL:
         return "Nonrecoverable failure in name resolution.";
      case AK_EAI_FAMILY:
         return "The ai_family member is not supported.";
      case AK_EAI_MEMORY:
         return "Memory allocation failure.";
      case AK_EAI_NONAME:
         return "Neither nodename nor servname provided, or not known.";
      case AK_EAI_SERVICE:
         return "The servname parameter is not supported.";
      case AK_EAI_SOCKTYPE:
         return "The ai_socktype member is not supported.";
      case AK_EAI_SYSTEM:
         return "System error returned in errno.";
      default:
         return "Unknown error.";
     }
}

int
__gnat_minus_500ms (void)
{
   return 0;   /*  not Windows */
}
