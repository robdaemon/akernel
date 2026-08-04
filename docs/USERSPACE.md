# Userspace

## Syscall ABI

`a7` = number, `a0..a4` args, `a0` (+`a1` for spawn) return.

```text
0  yield
1  debug_putchar(a0 = char)
2  map_mmio(a0 = as_cap, a1 = mmio_cap, a2 = va, a3 = offset, a4 = len, a5 = flags)
3  irq_wait(a0 = irq_cap)
4  irq_ack(a0 = irq_cap)
6  boot_file_size(a0 = boot_file_cap) -> len, U64'Last fail
7  boot_read_byte(a0 = boot_file_cap, a1 = offset) -> 0..255, 256 EOF, U64'Last fail
   (cap must be a Boot_File_Object with the Read right)
8  spawn(a0 = image_cap, a1 = grant_count)
   -> a0 status (0 ok, 1 invalid, 2 no slot, 3 load fail, 4 cap fail,
      5 sched fail, 6 invalid parent), a1 = process cap on ok
   image_cap: Boot_File_Object cap with Read + Execute rights.
   grant list: up to 32 entries of 24 bytes (source handle u64,
   rights mask u64, badge u64) in the spawner's IPC buffer page at
   offset 128; child receives caps at handles 1..N in list order.
   Rights mask bits: 0 Read, 1 Write, 2 Execute, 3 Map, 4 Send,
   5 Receive, 6 Wait, 7 Ack, 8 Transfer, 9 Manage; must be a subset
   of the source cap's rights.
9  exit() -> does not return
10 reap_process(a0 = process_cap) -> 0 ok, 1 invalid, 2 not exited
11 ep_create() -> endpoint cap handle, U64'Last fail
12 ipc_call(a0 = ep_cap) -> IPC result code; blocks until reply
13 ipc_recv(a0 = ep_cap) -> IPC result code; blocks until caller arrives
14 ipc_reply(a0 = 254) -> IPC result code; one-shot reply
15 mem_alloc(a0 = pages) -> memory-object cap handle, U64'Last fail
   (1..64 pages, zeroed PMM frames, rights Map+Read+Write+Transfer+Manage)
16 mem_map(a0 = as_cap, a1 = mem_cap, a2 = VA, a3 = offset,
   a4 = length, a5 = flags bit0 R/bit1 W) -> 0 ok, 1 fail; maps the
   object's frames as borrowed user pages (frame stays object-owned,
   AS teardown/unmap never frees it); write requires read
17 mem_unmap(a0 = as_cap, a1 = VA, a2 = length) -> 0 ok, 1 fail;
   only borrowed (memory-object) pages unmap, AS-owned pages refuse
18 ntfn_create() -> notification cap handle (Wait+Write+Manage),
   U64'Last fail
19 ntfn_wait(a0 = ntfn_cap) -> pending bits (consumed); blocks
20 ntfn_signal(a0 = ntfn_cap, a1 = bits) -> 0 ok, U64'Last fail
21 ntfn_bind_thread(a0 = ntfn_cap) -> 0 ok, 1 fail (Manage right;
   one bound notification per thread; IPC_Recv delivers signals as
   a synthetic message, label = U64'Last, word 0 = bits)
22 irq_bind_ntfn(a0 = irq_cap, a1 = ntfn_cap, a2 = badge) -> 0 ok,
   1 fail
23 io_map(a0 = resource_cap, a1 = base, a2 = length) -> MMIO cap
   handle, U64'Last fail (device_resource authority; page-aligned,
   <= 64 pages)
24 irq_create(a0 = resource_cap, a1 = source) -> IRQ cap handle
   (Wait+Ack+Transfer+Manage), U64'Last fail (device_resource
   authority; registers + PLIC-enables the source)
25 mem_object_pa(a0 = mem_cap, a1 = index) -> frame PA (Manage
   right), 0 fail
26 cap_delete(a0 = cap) -> 0 ok, U64'Last fail; closes one of the
   caller's own cap-table slots with the exit path's per-kind
   cleanup (object release, endpoint/IRQ/notification hooks)
```

IPC result codes: 0 ok, 1 invalid, 2 transfer failed, 3 endpoint gone,
4 reply gone. Messages are 96 bytes in the thread's IPC buffer page at
VA `0x6FFF0000`: label@0, 6 words@8, 4 cap handles@56 (0 = none),
badge@88 (recv only).

Init also gets a read-only bootinfo page at VA `0x6FFE0000`: magic
`AKINFO01`@0, entry count@8, then 64-byte entries (handle@0, kind@8,
rights mask@16, name length@24, name bytes@32, max 32 chars) listing
every kernel-granted cap by name (one Boot_File_Object per initrd
file, plus device_resource).

Return convention: 0 ok, 1 invalid/denied, 2 would-block (older
nonblocking paths only).

`map_mmio` checks: caller AS cap kind/rights/matches current root; MMIO
cap valid + Map right; R/W flags within cap rights; offset/len in object;
page alignment; VA in `0x40000000..0x80000000`; maps as `User_RW`.

Memory objects (`Kernel.Memory`, refcounted slab + PMM frames) follow
the endpoint lifecycle: one reference per cap, finalizer returns
frames to the PMM when the last cap closes (exit/reap). Borrowed
mappings are marked with PTE RSW bit 0.

Stream protocol (Akernel_User.Streams over endpoints, implemented):
label = op (1 write, 2 read), request/reply records (Count +
40-byte Data) in the 6-word area; console server is the first
consumer.

## RTS scaffold

`userspace/rts/akernel/` — not a full custom GNAT RTS yet; uses
`light-rv64imafdc` plus syscall wrappers/stubs:

```text
akernel_user-syscalls.*   raw syscall wrappers, IPC buffer/message
                          overlays, spawn grant lists, bootinfo page
                          overlay + Boot_Cap/Boot_Cap_Rights lookup
akernel_user-ipc.*        typed RPC wrappers (generic over request/
                          response payload records marshalled into
                          the message's 6-word area, 48-byte limit)
akernel_user-streams.*    Ada.Streams Root_Stream_Type over endpoint
                          caps (Endpoint_Stream): Read/Write RPC per
                          40-byte chunk, wire protocol Op_Write=1 /
                          Op_Read=2 with (Count, Data) records both
                          directions; Device_Error on failed calls
akernel_user-console.*    console output for normal programs: Put /
                          Put_Line over an Endpoint_Stream bound to
                          the init-minted console endpoint; falls back
                          to debug_putchar when no console cap granted
a-stream.*, a-ioexce.ads  vendored GNAT runtime units (light runtime
                          lacks Ada.Streams): compiled per program
                          with -gnatg via each .gpr's Compiler package
s-memory.adb              custom System.Memory body (overrides the
                          light runtime's bump allocator): free-list
                          heap at VA 0x4000_0000 (below text at
                          0x4600_0000), 16-byte blocks with 8-byte
                          size/flag headers, first-fit + splitting +
                          both-sides coalescing, grown on demand by
                          mem_alloc(64)/mem_map page-by-page, max
                          8 chunks (2 MiB); Storage_Error past that.
                          Pulled into every program's closure via a
                          private with on the Akernel_User root spec.
akernel_user-files.*      9P-ish file protocol constants + client:
                          Bind/Stat/Open/Read over the fs endpoint;
                          client-owned 32 KiB read-buffer memory
                          object mapped at 0x4400_0000, transferred
                          per Read call
akernel_user-mmio.*       MMIO helpers
syscalls-riscv64.s        ecall stubs (incl. generic stub for fuzzer)
start-riscv64.s           entry
runtime_stubs-riscv64.s   runtime stubs
linker-riscv64.ld         link script
```

Plan: real non-tasking runtime core first (exceptions, secondary stack,
heap, streams over endpoints); tasking runtime later (Ada rendezvous
maps onto call/recv/reply). See docs/IPC.md.

## Programs

Standalone Alire projects building to `bin/userspace/*.elf`:

- `userspace/init/` — verifies manifest readable (fatal yield loop if
  not; not kernel panic). Runs its device manager first (DTB walk
  against the System/Drivers database, spawning Drivers/Serial as
  the console server and any virtio drivers), then parses the
  manifest and builds a grant list per `program` line (bootinfo
  names / ipc_test / console tokens), spawns, yields, resumes.
  Mints the badged ipc_test endpoint and the console endpoint
  (session-manager badge pattern). Driver handle ABIs:
  platform-node drivers get 1 console (Receive for class 0, Send
  badged with the driver id otherwise), 2 MMIO, 3 IRQ, 4
  per-instance service endpoint (Receive). PCI drivers
  (System/Drivers lines `driver pci,<vid4> <path> pci <virtio-id>`;
  the devmgr scans bus 0 via per-function 4 KiB io_map probe
  windows, assigns BARs into the host's MMIO32/MMIO64 windows —
  no firmware PCI init on riscv virt — and discovers the virtio
  common/notify/ISR/device-cfg regions from the vendor capability
  list; transitional and modern PCI device ids are normalized to
  the virtio id) get a fixed 7-handle ABI: 1 console, 2
  common-cfg, 3 notify, 4 ISR, 5 device-cfg, 6 IRQ (INTx: PLIC
  source 32 + (dev + pin - 1) mod 4), 7 service endpoint. The
  devmgr's first service-endpoint message is a driver config
  (notify_off_multiplier, IRQ source, PCI device id) answered
  with a status-0 reply.
- `userspace/virtio/` — lib crate: MMIO and PCI (Virtio.PCI,
  generic over width-exact register access) transports plus
  split-ring virtqueues; pinned by the driver projects.
- `userspace/virtio_rng/` / `userspace/virtio_blk/` — PCI virtio
  drivers (devmgr pci lines, class 4 / class 2). Both run a boot
  self-test over a private DMA memory object (virtqueue rings +
  payload); blk then serves the block protocol on its service
  endpoint (IRQ-driven completions via a thread-bound
  notification; the ISR register read clears the INTx cause),
  rng stays resident as the future entropy server.
- `userspace/serial/` — console server, an ordinary devmgr-spawned
  driver (`driver ns16550a Drivers/Serial none 0`; class 0 grants
  it the console endpoint Receive side at handle 1, UART MMIO at 2,
  UART IRQ at 3). Serves stream protocol writes to the UART (read
  ops get EOF). Writes are line-atomic: per-client buffers keyed by
  the console cap badge (init/devmgr badge each grant with the
  program/driver id) flush on newline or a full 160-byte buffer;
  the kernel debug_putchar path buffers per thread
  (newline/full/exit flush). UART RX is IRQ-driven through a
  thread-bound notification (IRQ cap at handle 3, irq_bind_ntfn):
  the line signals the notification, IPC_Recv wakes with a
  synthetic Notification_Label message, the server drains RBR and
  acks.
- `userspace/fuzz/` — syscall fuzzer (`Tests/Fuzz`, granted ipc_test
  endpoint at cap 1, console Send cap at 2, Tests/Echo image cap at
  3): directed edge cases + console stream RPC checks + end-to-end
  IPC (spawns echo with granted endpoint + console cap, three
  ping-pong rounds: badge stamping, label/word round-trip, one-shot
  reply cap, cap transfer + handle rewrite, then reap) + grant-list
  validation cases + 4096 deterministic pseudo-random syscalls.
  Test output goes through the console stream; the random phase
  still fuzzes raw debug_putchar (printable garbage in the log is
  that, by design). Found the `irq_wait` missing-`Advance_SEPC`
  livelock. 89/89 directed PASS (incl. memory-object alloc/map/
  touch/unmap, RTS heap new/free/churn/growth, file-protocol
  stat/open/read/volume cases, spawn-from-memory-object with
  reap, and notification wait/signal/bind/recv-delivery cases).
- `userspace/fileserver/` — VFS layer (`System/Fileserver`,
  granted fs endpoint Receive at cap 1, console Send at 2, every
  boot-file cap from 3 via the `boot_files` token): serves the
  9P-ish file protocol (docs/IPC.md) — Stat/Open by name, stateless
  Read/Write into/out of the client-owned buffer memory object
  whose cap rides cap slot 0 (deleted after each op; a per-op
  transferred cap must not linger). Three volume kinds: boot-file
  set (Op_Mount, files mapped as borrowed read-only pages,
  writes rejected), raw block passthrough (Op_Add_Block, the
  single file "disk" via sector RPCs through a bounce page,
  read-modify-write for partial sectors), and fs-driver volumes
  (Op_Add_FS: ops forwarded verbatim — path repacked into words,
  buffer cap transferred onward — to an independent filesystem
  process).
- `userspace/partmgr/` — GPT partition layer (`System/Partmgr`):
  sits between the virtio-blk driver and filesystem drivers.
  Manifest `console blk part_server` grants console at 1, the
  blk service endpoint (Send) at 2 and the partition service
  endpoint (Receive) at 3. Probes LBA 1 for "EFI PART" (entry
  array walk, first 8 non-empty entries become slots in order;
  no header -> slot 0 maps the whole device), then serves the
  same block protocol (info/read/write) with the partition
  selected by the caller's cap badge (partN tokens), sector
  offset translation and bounds checks; request buffer caps are
  forwarded zero-copy to blk and the local copy is cap_delete'd
  after each op.
- `userspace/fat32/` — FAT32 filesystem driver (`System/Fat32`):
  an independent fs process behind the VFS. Manifest
  `console part0 fat32_server` grants console at 1, the
  partition-1 block service (badged Send on partmgr) at 2 and
  its own service endpoint
  (Receive) at 3; init pushes the Send side to the VFS as
  Op_Add_FS (device HD0, label AKDISK). Probes sector 0 for a
  FAT32 BPB (0x55AA, 512-byte sectors, "FAT32   " type string,
  cluster size <= 8 sectors), then serves the same client file
  protocol: subdirectory traversal ('/'-separated components),
  LFN matching (UCS-2 assembly, case-insensitive, short 8.3
  fallback), FAT chain walks through the bounce page, reads
  streaming cluster-by-cluster into the mapped client buffer,
  and Op_Write: file create (8.3 component names only, free-slot
  scan + directory chain extension), sector read-modify-write,
  cluster chain extension (free-entry scan from the FSInfo hint,
  both FAT mirrors + FSInfo updated), dirent cluster/size
  writeback. No sparse writes (offset > size rejected); no
  delete/mkdir/LFN-create yet.
- `userspace/echo/` — IPC echo server (`Tests/Echo`), spawned by the
  fuzzer with an endpoint cap at handle 1 and console Send cap at 2:
  recv/reply rounds reporting badge, words, double-reply failure,
  transferred cap handle; exits after three rounds. Prints through
  the console stream.
- `userspace/spin/` — preemption canary (`Tests/Spin`, console Send
  cap at 1): prints `spin online` via the console stream then
  busy-loops forever; boot continuing afterwards proves timer
  preemption.

## Manifest

`System/Manifest` line format:

```text
volume <device> <label> [ci|cs]
program <id> <path> [grants...]
```

The volume directive mounts the initrd file set Amiga-style: device
name `RD0`, volume label `Initrd`, case-insensitive paths (`ci`).
The file server accepts `RD0:...` and `Initrd:...` qualified names;
unqualified names get the client-side default volume prepended.

Current: a `volume RD0 Initrd ci` directive, fileserver with
`fs_server console boot_files`, fuzzer with
`ipc_test console Tests/Echo fs System/Manifest`, spin with
`console`, FAT32 driver with `console blk fat32_server`, plus a
`# file Tests/Echo` comment line (skipped by init; keeps the path
resolvable for the fuzzer's spawn). Boot-launch mechanism for
initrd contents only (Amiga-ish startup-sequence role); not a
general namespace mechanism — see docs/IPC.md for namespace/session
design.

Grant tokens map to grant-list entries: a bootinfo entry name
grants that cap with the kernel-assigned rights; `ipc_test` grants
init's badged test endpoint (full rights, badge 0xEC40); `console`
grants Send on the console endpoint (badged with the program id);
`fs` grants Send on the
file-server endpoint, `fs_server` grants Receive on it
(System/Fileserver only); `boot_files` grants every boot-file cap
in bootinfo order (System/Fileserver only — init pushes the
matching name table over the fs endpoint after spawn); `blk`
grants Send on the virtio-blk service endpoint kept by the device
manager (System/Partmgr only); `part_server` grants Receive on
the init-minted partition service endpoint (System/Partmgr
only); `partN` (N = 0..7) grants Send on it badged 16#1000#+N —
the badge selects the GPT slot inside partmgr;
`fat32_server` grants Receive on the init-minted FAT32
endpoint (System/Fat32 only — init pushes the Send side to the VFS
as Op_Add_FS after spawn).
