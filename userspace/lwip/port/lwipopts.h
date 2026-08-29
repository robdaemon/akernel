/*  Milestone 72a: lwIP build options for akernel's netserv.
 *
 *  NO_SYS raw-API single-threaded configuration: every lwIP entry
 *  point runs on netserv's main loop (frame drain, timer tick or
 *  bounded poll-drain), so no locking and no OS layer.
 *
 *  Memory comes from newlib malloc, which the m53b gloss layer backs
 *  with the _sbrk VA arena — lwIP gets no private allocator and no
 *  static pool tuning beyond the pbuf pool below.
 *
 *  TCP is tuned to the m71c socket ring geometry: 4 slots x 996
 *  payload bytes per direction, so MSS 996 and a 4-slot window.
 *  That equality is load-bearing (m72c): the recv callback accepts
 *  a pbuf chain only when it fits the ring WHOLE (otherwise it
 *  returns ERR_MEM and lwIP parks the chain in pcb->refused_data,
 *  retrying on the fast timer), and TCP_WND == ring capacity
 *  guarantees any in-window chain fits an empty ring. */

#ifndef AKERNEL_LWIPOPTS_H
#define AKERNEL_LWIPOPTS_H

#define NO_SYS                          1
#define SYS_LIGHTWEIGHT_PROT            0

/*  NO_SYS does not auto-disable the sequential APIs (their opt.h
 *  defaults are 1); without these, memp.c tries to declare the
 *  netconn pools and init.h rejects the configuration. */
#define LWIP_NETCONN                    0
#define LWIP_SOCKET                     0

/*  Memory: libc malloc/free via Akernel_User.Gloss's _sbrk arena. */
#define MEM_LIBC_MALLOC                 1
#define MEMP_MEM_MALLOC                 1
#define MEM_ALIGNMENT                   8

/*  Protocols: IPv4 + ARP + ICMP + UDP + TCP + raw pcbs. */
#define LWIP_IPV4                       1
#define LWIP_IPV6                       0
#define LWIP_ARP                        1
#define LWIP_ICMP                       1
#define LWIP_RAW                        1
#define LWIP_UDP                        1
#define LWIP_TCP                        1
#define LWIP_DNS                        0
#define LWIP_DHCP                       0
#define LWIP_AUTOIP                     0
#define LWIP_IGMP                       0
#define LWIP_ACD                        0

/*  TCP sized to the socket ring pair (4 x 996-byte payload slots). */
#define TCP_MSS                         996
#define TCP_WND                         3984
#define TCP_SND_BUF                     3984
#define TCP_SND_QUEUELEN                8
#define TCP_OVERSIZE                    0

/*  PCB pools: 8 client UDP sockets + spares; one shared raw ICMP
 *  pcb (Op_Ping + ping sockets) + spares. TCP (m72c): the 8-socket
 *  table plus TIME_WAIT stragglers — 5 (the opt.h default) was
 *  already tight for the tcp_test listener/child/refused churn. */
#define MEMP_NUM_UDP_PCB                10
#define MEMP_NUM_RAW_PCB                4
#define MEMP_NUM_TCP_PCB                10
#define MEMP_NUM_TCP_PCB_LISTEN         8

/*  RX frames land in pbuf pool entries; 1514-byte frames + headers
 *  must fit one pbuf so the netif shim stays trivial. */
#define PBUF_POOL_SIZE                  16
#define PBUF_POOL_BUFSIZE               1600

/*  Stats feed Net:status; nothing prints them from inside lwIP. */
#define LWIP_STATS                      1
#define LWIP_STATS_DISPLAY              0

#endif /* AKERNEL_LWIPOPTS_H */
