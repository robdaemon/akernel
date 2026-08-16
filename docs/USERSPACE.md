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
23 io_map(a0 = resource_cap, a1 = base, a2 = length, a3 = device_id)
   -> MMIO cap handle, U64'Last fail (device_resource authority;
   page-aligned, <= 64 pages; a3 = U64'Last for unattributed
   platform MMIO, otherwise a PCI requester id the region belongs
   to — used by the IOMMU authorization hook)
24 irq_create(a0 = resource_cap, a1 = source) -> IRQ cap handle
   (Wait+Ack+Transfer+Manage), U64'Last fail (device_resource
   authority; registers + PLIC-enables the source)
25 mem_object_pa(a0 = mem_cap, a1 = index) -> frame PA (Manage
   right), 0 fail. IOMMU authorization point: with the IOMMU
   online the frame is IOVA=PA mapped for every PCI device the
   caller holds an attributed MMIO cap for; the memory object's
   finalizer tears the mappings down.
26 cap_delete(a0 = cap) -> 0 ok, U64'Last fail; closes one of the
   caller's own cap-table slots with the exit path's per-kind
   cleanup (object release, endpoint/IRQ/notification hooks)
   (27-33: reply-cap duplication, process/thread introspection,
   system_reset — see docs/IPC.md and arch-traps.adb)
34 read_clock() -> a0 = seconds since the Unix epoch, a1 =
   nanoseconds within the second (board RTC; goldfish on qemu
   virt); both 0 when no RTC ticks. Ungated, read-only.
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
                          Op_Read=2 / Op_Input=3 (device -> server
                          input injection: source drivers push input
                          bytes into the server's input FIFO; client
                          Op_Read drains it) with (Count, Data)
                          records both directions; Device_Error on
                          failed calls
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
  UART IRQ at 3). Serves stream protocol writes to the UART. Writes
  are line-atomic: per-client buffers keyed by the console cap
  badge (init/devmgr badge each grant with the program/driver id)
  flush on newline or a full 160-byte buffer — newline-flush slots
  are RELEASED immediately (a badge needs a slot only while a
  partial line pends; pinning them overflowed the 8-slot table
  once 10+ console clients existed, pushing steady-state writers
  onto the table-full bypass where lines interleave); the kernel
  debug_putchar path buffers per thread (newline/full/exit flush).
  Input: a bounded FIFO (128 bytes, drop-new) fed by UART RX and
  by Op_Input pushes from source drivers (virtio-input keyboard);
  client Op_Read drains it (Count = 0 when empty). Sinks:
  Op_Attach_Sink (init/devmgr badge 0 only; cap slot 0 carries an
  endpoint Send cap) registers output mirrors — the virtio-gpu
  text console — that every flushed line is stream-written to;
  a sink whose write fails is dropped and its cap deleted, so a
  dead display server can never wedge the console. Serial output
  always continues as the debug/logging copy. UART RX is
  IRQ-driven through a thread-bound notification (IRQ cap at
  handle 3, irq_bind_ntfn): the line signals the notification,
  IPC_Recv wakes with a synthetic Notification_Label message, the
  server drains RBR (into the FIFO, echoed) and acks.
- `userspace/virtio_gpu/` — virtio-gpu driver (virtio-gpu-pci
  addr 0x7, class 16). Controlq 2D only (no feature bits):
  GET_DISPLAY_INFO -> CREATE_2D (B8G8R8A8) -> ATTACH_BACKING
  (per-page entries; the framebuffer is a list of 64-page memory
  objects — the kernel object page cap) -> SET_SCANOUT, then
  TRANSFER_TO_HOST_2D + RESOURCE_FLUSH per dirty pixel-row band.
  Text console: font8x8 (public domain) stretched 2x vertically
  = 8x16 cells (128x48 at 1024x768), scroll/CR/LF/TAB/BS. Serves
  the stream protocol on handle 7 as a console SINK (Op_Write
  renders); the console server mirrors its line-atomic lines to
  it after devmgr attaches the endpoint via Op_Attach_Sink. All
  driver logging is Debug_Put_Line — a console print during init
  would deadlock against the server blocked in the sink RPC.
  The same endpoint ALSO serves the display-service protocol
  (`akernel_user-display.ads`, labels 10+ — stream labels own
  1..4) for the Bureau compositor (milestone 28, slice 1):
  caps move caller -> callee only (replies are words-only), so
  the compositor ALLOCATES the compositing buffer (Mem_Alloc
  64-page chunks, contiguous VA) and pushes chunk caps with
  Op_Set_Buffer (base index in w0, up to 4 caps per call, caps
  must carry Manage — the driver runs Mem_Object_PA on them;
  the driver KEEPS them for the session, deliberate exception
  to the per-op cap_delete rule so the frames outlive the
  compositor). Op_Commit_Buffer DETACHes the boot framebuffer
  backing and ATTACHes the compositor's chunks (one full-screen
  TRANSFER + FLUSH); Op_Present(x,y,w,h) pushes a pixel band
  straight from the compositor's buffer (zero extra copy).
  Op_Get_Info returns width/height/stride/total-pages. The text
  console keeps rendering into the driver's own framebuffer
  until a compositor commits; its writes are invisible after
  (Bureau's terminal client takes the sink over in slice 3).
  Op_Set_Cursor/Op_Move_Cursor reserved for the hw cursor
  (cursorq UPDATE_CURSOR 0x300 / MOVE_CURSOR 0x301, slice 4).
- `userspace/bureau/` — Bureau, the compositor / window server
  (milestone 28, slice 2). Spawned by devmgr right after the
  GPU driver (image System/Bureau; handles: 1 = console Send
  badged, 2 = display-EP Send). Allocates the compositing
  buffer (64-page chunks at 0x60000000), pushes chunk caps
  (Op_Set_Buffer, minted Map+Read+Write+Manage+Transfer, its
  minted copies deleted per call), commits, renders the
  Workbench-3.x-style desktop: gray palette, "Bureau" screen
  bar with a right-side gadget placeholder, one matted window
  (dark frame + gadtools bevel + blue ACTIVE title bar with
  close/depth placeholders + white pane), presents the frame,
  then blocks (clients arrive in slice 3). Burned (then un-burned): pixels are
  B8G8R8A8 = LE u32 AARRGGBB (low byte = BLUE); a screendump
  decoder with an R/B swap "proved" otherwise, the palette
  "fix" produced a real salmon title (user caught it), and
  the buggy decoder re-confirmed. Decode PPM bytes straight
  (R,G,B); trust the user's eyes over the script.
  font8x8 lives in rts/akernel now (shared client rendering;
  bit 0 = leftmost pixel). Client display helpers:
  akernel_user-display.adb (raw IPC_Call). Slice 3 added the
  window-service loop on handle 3 (window protocol v1,
  akernel_user-window.ads, labels 20-24): ONE surface slot
  bound to the startup window; the client pushes surface
  chunk caps, Bureau maps them read-only and copies
  Op_Surface_Update bands into the compositing buffer at the
  pane origin, then Presents (wl_shm model).
- `userspace/terminal/` — Bureau's first client (image
  System/Terminal, devmgr-spawned after Bureau; handles:
  1 = console Send, 2 = Bureau window service Send, 3 = sink
  EP Receive). Allocates its surface, pushes chunks, renders
  the console mirror text grid into it (font8x8 8x16 cells,
  dark on white; scroll = surface memmove + one
  Op_Surface_Update band). devmgr attaches ITS sink EP via
  Op_Attach_Sink (the GPU driver EP is no longer a sink).
  Burned: the WHOLE display stack (GPU driver, Bureau,
  terminal) logs via Debug_Put_Line only — any console print
  deadlocks against the console server's mirror into the
  terminal sink (Bureau <-> terminal cycle proven live).
  Input arrives via the Bureau seat (slice 4): Bureau forwards
  focused keys as stream Op_Input bytes, the terminal injects
  them into the console input FIFO (shell reads Op_Read in
  milestone 31).
- Seat (slice 4, akernel_user-window.ads labels 26/30/31):
  devmgr records class-18 service EPs at spawn, then after
  Bureau + terminal are up pushes the terminal's stream EP to
  Bureau (Op_Set_Focus, cap slot 0) and Bureau's EP to both
  virtio-input instances (Seat_Config_Label = U64'Last-2 —
  the input functions scan before the GPU, so this arrives as
  a SECOND message post-bring-up; the virtio-input event loop
  is now the rng-style IPC_Recv multiplex, IRQ notifications
  arrive as synthetic Notification_Label messages). Keyboard
  chars (driver keymap) -> Op_Key -> Bureau -> stream Op_Input
  -> terminal -> console input FIFO. Tablet ABS_X/Y batched on
  EV_SYN + BTN_LEFT/RIGHT bits -> Op_Pointer (raw 0..32767,
  Bureau scales) -> Bureau's SOFTWARE cursor sprite (chosen
  over the virtio hw cursor: arch-independent, works on any
  dumb display driver; Bureau re-saves/redraws the sprite when
  an update band clobbers it). Burned: HMP mouse_move produces
  no absolute events for the virtio tablet — absolute pointer
  injection needs QMP input-send-event (run target exposes
  -qmp unix:/tmp/qqmp.sock alongside the HMP socket).
- `userspace/virtio_input/` — virtio-input driver (one image for
  every function: virtio-keyboard-pci addr 0x5, virtio-tablet-pci
  addr 0x6; class 18 spawns one instance each, role from the
  ID_NAME config string). Same 7-handle PCI driver ABI. Eventq
  only: 8 posted 8-byte event buffers, descriptor id == slot id,
  IRQ-driven over INTx, decode + repost on completion. Device
  config is the QEMU/Linux virtio_input.h layout (selected-blob
  region: select/subsel/size at 0x00..0x02, payload at 0x08;
  EV_BITS=0x11, ABS_INFO=0x12, per-type bitmaps only). Keyboard:
  US keymap with shift/capslock, printable chars (+ enter/tab/
  backspace/escape) delivered as Op_Input to the console server.
  Tablet/mouse: absolute/relative motion and buttons are
  serial-logged for now — a structured pointer channel lands with
  the GPU console.
- `userspace/virtio_rng/` — virtio-rng entropy driver (class 4).
  Polls its one entropy completion, then lives in a Recv loop
  that drains + acks stray shared-INTx notifications — EVERY IRQ
  cap holder must ack after being poked: an unacked line holds
  the PLIC claim open and silences the shared source for all
  partners (burned when the GPU landed on source 35).
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
  Op_Add_FS (device BD0, label Sys — milestone 29; the raw
  whole-device volume moved to WD0). Probes sector 0 for a
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
  writeback; Op_Rename/Op_Volume_Info (41a); dirent create/
  write/access stamps from the board RTC (Sys_Read_Clock, 59 —
  Op_Stat reply words 2/3 carry the FAT write date/time).
  No sparse writes (offset > size rejected).
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
