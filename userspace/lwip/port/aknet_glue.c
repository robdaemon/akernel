/*  Milestone 72b/72c: lwIP <-> netserv glue.
 *
 *  netserv.adb keeps the whole client-facing surface (ring pairs,
 *  badges, ops, Net: volume); this file is the thin adapter between
 *  it and the lwIP raw API. Everything runs on netserv's single
 *  service thread (frame drain, bounded poll-drain or a 50 ms
 *  ticker notification), so NO_SYS needs no locking here.
 *
 *  IP addresses cross the boundary as host-order u32 (the akernel
 *  convention: 10.0.2.15 = 0x0A00020F); the glue converts.
 *
 *  Hairpin: m71c looped "dst == our own address" traffic back
 *  locally. lwIP has no ARP entry for ourselves, so aknet_output
 *  intercepts own-address packets at the IP layer. They are NOT
 *  fed synchronously into ip4_input (m72c): tcp_in.c keeps parse
 *  state in file-static variables (inseg/recv_flags/recv_data), so
 *  a reentrant tcp_input — SYN hairpinned from inside tcp_connect,
 *  its SYN-ACK from inside the SYN's tcp_input — corrupts the
 *  in-flight handshake (the m72c hairpin-connect wedge), the same
 *  reason lwIP's own loopif queues loopback packets. And the queue
 *  holds COPIES, not pbuf refs: lwIP's input path mutates the pbuf
 *  it is handed (pbuf_remove_header), which corrupts a TCP segment
 *  still parked in the sender's unacked queue. Hairpinned copies
 *  sit on a FIFO drained by aknet_hairpin_drain, called only from
 *  netserv's top-level contexts, never from a callback.
 *
 *  The netmask is 0.0.0.0 on purpose: the m71c stack had no
 *  routing and ARPed every destination directly (slirp's network
 *  is flat), and ip4_route with a /0 mask reproduces exactly that
 *  (every destination is "on-link"). */

#include "lwip/opt.h"
#include "lwip/def.h"
#include "lwip/pbuf.h"
#include "lwip/netif.h"
#include "lwip/ip4.h"
#include "lwip/ip4_addr.h"
#include "lwip/ip_addr.h"
#include "lwip/etharp.h"
#include "lwip/udp.h"
#include "lwip/raw.h"
#include "lwip/timeouts.h"
#include "lwip/prot/iana.h"
#include "lwip/prot/ip4.h"
#include "netif/ethernet.h"

#include <string.h>

/*  Exported by netserv.adb (Convention C). */
extern int  aknet_frame_tx (const u8_t *frame, u32_t len);
extern void aknet_on_udp_rx (u32_t id, u32_t src_ip, u32_t src_port,
                             const u8_t *data, u32_t len);
extern int  aknet_on_icmp_rx (u32_t src_ip, const u8_t *data,
                              u32_t len);

static struct netif aknet_netif;

/*  Single-threaded scratch (2 KiB covers any slot-sized frame). */
static u8_t aknet_txbuf[2048];
static u8_t aknet_rxbuf[2048];

/*  Hairpin queue (see the file header): own-address pbufs held
 *  for later, non-reentrant delivery. 16 entries is far beyond
 *  anything a drain round can accumulate. */
#define AKNET_HQ_SIZE 16
static struct pbuf *aknet_hq[AKNET_HQ_SIZE];
static u32_t aknet_hq_head;
static u32_t aknet_hq_tail;
static u8_t  aknet_hq_draining;

/*------------------------------------------------------------------*/
/*  netif driver                                                    */
/*------------------------------------------------------------------*/

static err_t
aknet_linkoutput (struct netif *netif, struct pbuf *p)
{
   (void) netif;
   if (p->tot_len > sizeof (aknet_txbuf))
      return ERR_MEM;
   pbuf_copy_partial (p, aknet_txbuf, p->tot_len, 0);
   if (aknet_frame_tx (aknet_txbuf, (u32_t) p->tot_len) != 0)
      return ERR_IF;
   return ERR_OK;
}

static err_t
aknet_output (struct netif *netif, struct pbuf *p,
              const ip4_addr_t *ipaddr)
{
   if (ip4_addr_cmp (ipaddr, netif_ip4_addr (netif)))
      {
         struct pbuf *q;

         /*  Hairpin: queue a COPY for aknet_hairpin_drain (the
          *  queue avoids reentrant tcp_input — tcp_in.c keeps
          *  parse state in file-static variables). A copy, never
          *  a pbuf_ref of the caller's pbuf: lwIP's input path
          *  mutates what it is handed (pbuf_remove_header in
          *  tcp_input), and the caller can keep that pbuf — a
          *  TCP segment lives in the unacked queue for the whole
          *  RTT; mutating it corrupts the segment's bookkeeping
          *  (the m72c unpurgeable-SYN-ACK nagle deadlock). UDP/
          *  ICMP freed theirs immediately, which is why m72b's
          *  ref-based hairpin looked fine. */
         if (aknet_hq_tail - aknet_hq_head >= AKNET_HQ_SIZE)
            return ERR_MEM;
         q = pbuf_alloc (PBUF_RAW, p->tot_len, PBUF_RAM);
         if (q == NULL)
            return ERR_MEM;
         pbuf_copy (q, p);
         aknet_hq[aknet_hq_tail % AKNET_HQ_SIZE] = q;
         aknet_hq_tail++;
         return ERR_OK;
      }
   return etharp_output (netif, p, ipaddr);
}

/*  Deliver every queued hairpin packet, FIFO. Draining can
 *  enqueue more (the SYN-ACK's delivery produces the ACK), so
 *  loop until empty. Called only from netserv's top-level
 *  contexts — the drain guard makes a stray nested call (none
 *  exist today) a harmless no-op, not corruption. */
void
aknet_hairpin_drain (void)
{
   if (aknet_hq_draining)
      return;
   aknet_hq_draining = 1;
   while (aknet_hq_head != aknet_hq_tail)
      {
         struct pbuf *p = aknet_hq[aknet_hq_head % AKNET_HQ_SIZE];

         aknet_hq_head++;
         if (ip4_input (p, &aknet_netif) != ERR_OK)
            pbuf_free (p);
      }
   aknet_hq_draining = 0;
}

static err_t
aknet_netif_init (struct netif *netif)
{
   netif->name[0] = 'a';
   netif->name[1] = 'k';
   netif->output = aknet_output;
   netif->linkoutput = aknet_linkoutput;
   netif->mtu = 1500;
   netif->hwaddr_len = 6;
   netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP
      | NETIF_FLAG_ETHERNET | NETIF_FLAG_LINK_UP;
   return ERR_OK;
}

/*  Bring the interface up. ip/gw are host order; the mask is /0
 *  (see the file header). */
void
aknet_setup (const u8_t *mac, u32_t ip, u32_t gw, u32_t mtu)
{
   ip4_addr_t a;
   ip4_addr_t g;
   ip4_addr_t m;

   ip4_addr_set_u32 (&a, PP_HTONL (ip));
   ip4_addr_set_u32 (&g, PP_HTONL (gw));
   ip4_addr_set_u32 (&m, 0);
   netif_add (&aknet_netif, &a, &m, &g, NULL, aknet_netif_init,
              ethernet_input);
   memcpy (aknet_netif.hwaddr, mac, 6);
   if (mtu != 0)
      aknet_netif.mtu = (u16_t) mtu;
   netif_set_default (&aknet_netif);
   netif_set_up (&aknet_netif);
   netif_set_link_up (&aknet_netif);
}

/*  Writable Net: files: re-program address/gateway (mask kept). */
void
aknet_set_addr (u32_t ip, u32_t gw)
{
   ip4_addr_t a;
   ip4_addr_t g;

   ip4_addr_set_u32 (&a, PP_HTONL (ip));
   ip4_addr_set_u32 (&g, PP_HTONL (gw));
   netif_set_addr (&aknet_netif, &a, NULL, &g);
}

/*  Feed one received frame into the stack (frame drain on the
 *  service thread). */
int
aknet_rx (const u8_t *frame, u32_t len)
{
   struct pbuf *p;

   p = pbuf_alloc (PBUF_RAW, (u16_t) len, PBUF_POOL);
   if (p == NULL)
      return ERR_MEM;
   pbuf_take (p, frame, (u16_t) len);
   if (aknet_netif.input (p, &aknet_netif) != ERR_OK)
      {
         pbuf_free (p);
         return ERR_IF;
      }
   return ERR_OK;
}

/*------------------------------------------------------------------*/
/*  UDP sockets (one pcb per m71c socket; recv arg = socket id)     */
/*------------------------------------------------------------------*/

static void
aknet_udp_rx_cb (void *arg, struct udp_pcb *pcb, struct pbuf *p,
                 const ip_addr_t *addr, u16_t port)
{
   u32_t n;

   (void) pcb;
   if (p == NULL)
      return;
   n = p->tot_len < sizeof (aknet_rxbuf) ? p->tot_len
      : sizeof (aknet_rxbuf);
   pbuf_copy_partial (p, aknet_rxbuf, n, 0);
   aknet_on_udp_rx ((u32_t) (uintptr_t) arg,
                    PP_NTOHL (ip4_addr_get_u32 (ip_2_ip4 (addr))),
                    (u32_t) port, aknet_rxbuf, n);
   pbuf_free (p);
}

struct udp_pcb *
aknet_udp_new (u32_t id)
{
   struct udp_pcb *pcb = udp_new ();

   if (pcb != NULL)
      udp_recv (pcb, aknet_udp_rx_cb, (void *) (uintptr_t) id);
   return pcb;
}

int
aknet_udp_bind (struct udp_pcb *pcb, u32_t port)
{
   return (int) udp_bind (pcb, IP_ADDR_ANY, (u16_t) port);
}

int
aknet_udp_connect (struct udp_pcb *pcb, u32_t ip, u32_t port)
{
   ip4_addr_t dst;

   ip4_addr_set_u32 (&dst, PP_HTONL (ip));
   return (int) udp_connect (pcb, &dst, (u16_t) port);
}

int
aknet_udp_send (struct udp_pcb *pcb, u32_t ip, u32_t port,
                const u8_t *data, u32_t len)
{
   struct pbuf *p;
   ip4_addr_t dst;
   err_t e;

   p = pbuf_alloc (PBUF_TRANSPORT, (u16_t) len, PBUF_RAM);
   if (p == NULL)
      return ERR_MEM;
   pbuf_take (p, data, (u16_t) len);
   ip4_addr_set_u32 (&dst, PP_HTONL (ip));
   e = udp_sendto (pcb, p, &dst, (u16_t) port);
   pbuf_free (p);
   return (int) e;
}

void
aknet_udp_del (struct udp_pcb *pcb)
{
   udp_remove (pcb);
}

/*------------------------------------------------------------------*/
/*  Raw ICMP: one shared pcb for Op_Ping and the ping sockets       */
/*------------------------------------------------------------------*/

static u8_t
aknet_raw_rx_cb (void *arg, struct raw_pcb *pcb, struct pbuf *p,
                 const ip_addr_t *addr)
{
   /* lwIP hands raw pcbs the packet with the IP header still
    * attached; the Ada side wants the ICMP message only. */
   const struct ip_hdr *iph = (const struct ip_hdr *) p->payload;
   u16_t hlen;
   u32_t plen;
   u32_t n;

   (void) arg;
   (void) pcb;
   if (p->tot_len < sizeof (struct ip_hdr))
      return 0;
   hlen = IPH_HL_BYTES (iph);
   if (p->tot_len < hlen)
      return 0;
   plen = p->tot_len - hlen;
   n = plen < sizeof (aknet_rxbuf) ? plen : sizeof (aknet_rxbuf);
   pbuf_copy_partial (p, aknet_rxbuf, (u16_t) n, hlen);
   if (aknet_on_icmp_rx
       (PP_NTOHL (ip4_addr_get_u32 (ip_2_ip4 (addr))), aknet_rxbuf,
        n) != 0)
      {
         /*  Reporting the packet eaten means this callback owns it:
          *  the Ada side only copied the bytes out, so free here. */
         pbuf_free (p);
         return 1;
      }
   return 0;
}

struct raw_pcb *
aknet_raw_icmp_new (void)
{
   struct raw_pcb *pcb = raw_new (IP_PROTO_ICMP);

   if (pcb != NULL)
      raw_recv (pcb, aknet_raw_rx_cb, NULL);
   return pcb;
}

int
aknet_raw_send (struct raw_pcb *pcb, u32_t ip, const u8_t *data,
                u32_t len)
{
   struct pbuf *p;
   ip4_addr_t dst;
   err_t e;

   p = pbuf_alloc (PBUF_IP, (u16_t) len, PBUF_RAM);
   if (p == NULL)
      return ERR_MEM;
   pbuf_take (p, data, (u16_t) len);
   ip4_addr_set_u32 (&dst, PP_HTONL (ip));
   e = raw_sendto (pcb, p, &dst);
   pbuf_free (p);
   return (int) e;
}

/*------------------------------------------------------------------*/
/*  ARP table queries (the pending-resolve tracker and Net:arp)     */
/*------------------------------------------------------------------*/

int
aknet_arp_resolved (u32_t ip)
{
   size_t i;

   for (i = 0; i < ARP_TABLE_SIZE; i++)
      {
         ip4_addr_t *eip;
         struct netif *eni;
         struct eth_addr *emac;

         if (etharp_get_entry (i, &eip, &eni, &emac)
             && PP_NTOHL (ip4_addr_get_u32 (eip)) == ip)
            return 1;
      }
   return 0;
}

int
aknet_arp_get (u32_t i, u32_t *ip, u8_t *mac)
{
   ip4_addr_t *eip;
   struct netif *eni;
   struct eth_addr *emac;

   if (!etharp_get_entry ((size_t) i, &eip, &eni, &emac))
      return 0;
   *ip = PP_NTOHL (ip4_addr_get_u32 (eip));
   memcpy (mac, emac->addr, 6);
   return 1;
}

/*------------------------------------------------------------------*/
/*  Timer wheel (driven by the 50 ms ticker notification)           */
/*------------------------------------------------------------------*/

void
aknet_timeouts (void)
{
   sys_check_timeouts ();
}

/*------------------------------------------------------------------*/
/*  TCP sockets (m72c): one tcp_pcb per stream socket, listen pcbs  */
/*  for Op_Listen. Callback arg = socket id everywhere.             */
/*                                                                  */
/*  RX backpressure rides lwIP's refused-data mechanism (verified   */
/*  in tcp_in.c/tcp.c): the recv callback accepts a chain only      */
/*  when aknet_on_tcp_rx reports it stored WHOLE in the socket's    */
/*  RX ring; otherwise it returns ERR_MEM and lwIP keeps the chain  */
/*  in pcb->refused_data (we must not free it), re-delivering on    */
/*  the fast timer or on aknet_tcp_kick. The CLOSED event (recv     */
/*  callback with p == NULL) is delivered only after refused data,  */
/*  so the Ada-side EOF marker stays in stream order. TCP_WND ==    */
/*  the ring capacity (4 x 996) makes any in-window chain fit an    */
/*  empty ring, so a whole-chain accept is always possible once     */
/*  the client drains.                                              */
/*                                                                  */
/*  Accept parking: the accept callback asks the Ada side for a     */
/*  child socket slot; on success the child pcb is parked (client   */
/*  claims it with Op_Accept), on overflow ERR_ABRT makes lwIP      */
/*  abort the embryonic connection. tcp_accepted needs the LISTEN   */
/*  pcb, which the callback does not receive — hence the per-id     */
/*  listen table below.                                             */
/*------------------------------------------------------------------*/

#include "lwip/tcp.h"
#include "lwip/priv/tcp_priv.h"   /*  tcp_process_refused_data */

extern int   aknet_on_tcp_accept (u32_t id, struct tcp_pcb *newpcb);
extern void  aknet_on_tcp_connected (u32_t id, int err);
extern int   aknet_on_tcp_rx (u32_t id, struct pbuf *p);
extern void  aknet_on_tcp_eof (u32_t id);
extern void  aknet_on_tcp_sent (u32_t id, u32_t len);
extern void  aknet_on_tcp_err (u32_t id, int err);

#define AKNET_MAX_SOCKS 8

static struct tcp_pcb *aknet_listen_pcbs[AKNET_MAX_SOCKS + 1];

static err_t aknet_tcp_rx_cb (void *arg, struct tcp_pcb *tpcb,
                              struct pbuf *p, err_t err);
static err_t aknet_tcp_sent_cb (void *arg, struct tcp_pcb *tpcb,
                                u16_t len);
static void  aknet_tcp_err_cb (void *arg, err_t err);

static void
aknet_tcp_set_cbs (struct tcp_pcb *pcb)
{
   tcp_recv (pcb, aknet_tcp_rx_cb);
   tcp_sent (pcb, aknet_tcp_sent_cb);
   tcp_err (pcb, aknet_tcp_err_cb);
}

static err_t
aknet_tcp_accept_cb (void *arg, struct tcp_pcb *newpcb, err_t err)
{
   u32_t id = (u32_t) (uintptr_t) arg;

   (void) err;
   if (aknet_on_tcp_accept (id, newpcb) != 0)
      return ERR_ABRT;
   /*  The Ada side parked the pcb; free a lwIP backlog slot. */
   if (id >= 1 && id <= AKNET_MAX_SOCKS
       && aknet_listen_pcbs[id] != NULL)
      tcp_accepted (aknet_listen_pcbs[id]);
   return ERR_OK;
}

static err_t
aknet_tcp_connected_cb (void *arg, struct tcp_pcb *tpcb, err_t err)
{
   (void) tpcb;
   aknet_on_tcp_connected ((u32_t) (uintptr_t) arg, (int) err);
   return ERR_OK;
}

static err_t
aknet_tcp_rx_cb (void *arg, struct tcp_pcb *tpcb, struct pbuf *p,
                 err_t err)
{
   (void) err;
   if (p == NULL)
      {
         aknet_on_tcp_eof ((u32_t) (uintptr_t) arg);
         return ERR_OK;
      }
   if (aknet_on_tcp_rx ((u32_t) (uintptr_t) arg, p) == 0)
      return ERR_MEM;   /*  refused: lwIP keeps + retries (see above) */
   tcp_recved (tpcb, p->tot_len);
   pbuf_free (p);
   return ERR_OK;
}

static err_t
aknet_tcp_sent_cb (void *arg, struct tcp_pcb *tpcb, u16_t len)
{
   (void) tpcb;
   aknet_on_tcp_sent ((u32_t) (uintptr_t) arg, (u32_t) len);
   return ERR_OK;
}

static void
aknet_tcp_err_cb (void *arg, err_t err)
{
   aknet_on_tcp_err ((u32_t) (uintptr_t) arg, (int) err);
}

struct tcp_pcb *
aknet_tcp_new (u32_t id)
{
   struct tcp_pcb *pcb = tcp_new ();

   if (pcb != NULL)
      tcp_arg (pcb, (void *) (uintptr_t) id);
   return pcb;
}

int
aknet_tcp_bind (struct tcp_pcb *pcb, u32_t port)
{
   return (int) tcp_bind (pcb, IP_ADDR_ANY, (u16_t) port);
}

/*  tcp_listen CONSUMES *ppcb and returns the listen pcb; the Ada
 *  side keeps its table entry pointing at the result. */
int
aknet_tcp_listen (struct tcp_pcb **ppcb, u32_t id)
{
   struct tcp_pcb *l;

   tcp_arg (*ppcb, (void *) (uintptr_t) id);
   l = tcp_listen (*ppcb);
   if (l == NULL)
      return ERR_MEM;
   *ppcb = l;
   if (id >= 1 && id <= AKNET_MAX_SOCKS)
      aknet_listen_pcbs[id] = l;
   tcp_accept (l, aknet_tcp_accept_cb);
   return 0;
}

/*  Accepted child: full callback set under its own socket id. */
void
aknet_tcp_attach (struct tcp_pcb *pcb, u32_t id)
{
   tcp_arg (pcb, (void *) (uintptr_t) id);
   aknet_tcp_set_cbs (pcb);
}

int
aknet_tcp_connect (struct tcp_pcb *pcb, u32_t ip, u32_t port)
{
   ip4_addr_t dst;

   ip4_addr_set_u32 (&dst, PP_HTONL (ip));
   aknet_tcp_set_cbs (pcb);
   return (int) tcp_connect (pcb, &dst, (u16_t) port,
                             aknet_tcp_connected_cb);
}

int
aknet_tcp_write (struct tcp_pcb *pcb, const u8_t *data, u32_t len)
{
   return (int) tcp_write (pcb, data, (u16_t) len,
                           TCP_WRITE_FLAG_COPY);
}

int
aknet_tcp_output (struct tcp_pcb *pcb)
{
   return (int) tcp_output (pcb);
}

/*  Retry a parked (refused) RX chain now instead of waiting for
 *  the fast timer — called after Accept maps the ring, on the
 *  tick and on client ops. The NULL check is ours: lwIP only
 *  guards refused_data under LWIP_WND_SCALE, and
 *  tcp_process_refused_data on an empty pcb dereferences NULL
 *  (the m72c stval=0x15 fault). */
int
aknet_tcp_kick (struct tcp_pcb *pcb)
{
   if (pcb->refused_data == NULL)
      return 0;
   return (int) tcp_process_refused_data (pcb);
}

/*  Close from any state. Callbacks are cleared first so no late
 *  event (CLOSEPEND retry, RST in flight) can touch a socket slot
 *  the Ada side is about to free; a pcb that cannot FIN now is
 *  aborted instead. */
int
aknet_tcp_close (struct tcp_pcb *pcb, u32_t id)
{
   err_t e;

   if (id >= 1 && id <= AKNET_MAX_SOCKS)
      aknet_listen_pcbs[id] = NULL;   /*  harmless for non-listeners */
   tcp_arg (pcb, NULL);
   /*  tcp_recv/sent/err assert on LISTEN pcbs (and the default
       LWIP_PLATFORM_ASSERT aborts): a listener only ever got
       tcp_accept, so there is nothing to clear. */
   if (pcb->state != LISTEN)
   {
      tcp_recv (pcb, NULL);
      tcp_sent (pcb, NULL);
      tcp_err (pcb, NULL);
   }
   e = tcp_close (pcb);
   if (e != ERR_OK)
      tcp_abort (pcb);
   return 0;
}

/*  Introspection for the Net:tcp listing. */
int
aknet_tcp_state (struct tcp_pcb *pcb)
{
   return (int) pcb->state;
}

u32_t
aknet_tcp_local_port (struct tcp_pcb *pcb)
{
   return (u32_t) pcb->local_port;
}

u32_t
aknet_tcp_remote_port (struct tcp_pcb *pcb)
{
   return (u32_t) pcb->remote_port;
}

u32_t
aknet_tcp_remote_ip (struct tcp_pcb *pcb)
{
   return PP_NTOHL (ip4_addr_get_u32 (ip_2_ip4 (&pcb->remote_ip)));
}

/*  pbuf accessors for the Ada-side ring chunker (the recv callback
 *  hands the chain over; Ada copies slot-sized pieces straight out
 *  of it). */
u32_t
aknet_pbuf_totlen (struct pbuf *p)
{
   return (u32_t) p->tot_len;
}

void
aknet_pbuf_copy (struct pbuf *p, u32_t off, u8_t *dst, u32_t len)
{
   pbuf_copy_partial (p, dst, (u16_t) len, (u16_t) off);
}