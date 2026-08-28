/*  Milestone 72b: lwIP <-> netserv glue.
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
 *  intercepts own-address packets at the IP layer and feeds them
 *  straight back into ip4_input — the wire never sees them.
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
         /*  Hairpin: ip4_input consumes its pbuf, but a netif
          *  output function must not consume the caller's pbuf
          *  (aknet_raw_send/aknet_udp_send free it after sendto).
          *  Keep the caller's reference alive across the hairpin
          *  or the send path double-frees and corrupts the pool. */
         pbuf_ref (p);
         return ip4_input (p, netif);
      }
   return etharp_output (netif, p, ipaddr);
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
