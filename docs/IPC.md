# IPC design

Status: core implemented (ep_create, call/recv/reply, cap transfer,
reply cap, endpoint slab, FIFO caller queue, grant-list spawn with
rights-subset enforcement + badges, Boot_File_Object image caps,
bootinfo page, Akernel_User.IPC typed wrappers, init namespace
composition via bootinfo-name grant tokens, Akernel_User.Streams
endpoint streams + console output path via the console server in
Drivers/Serial). Deferred items at bottom.

## Principles

- Synchronous rendezvous in the kernel (seL4-style). No kernel buffering,
  no in-kernel message queues. Async semantics (Amiga-style message ports)
  are built in userspace: server thread + shared memory.
- Kernel mechanism only; protocol lives in userspace. Kernel never parses
  names, paths, or protocol payloads.
- Plan 9 model: a file is a channel to a server. VFS is userspace; the
  kernel gains no file concepts beyond boot-file image caps.
- Authority is capability possession. Rights are monotonically decreasing:
  no operation may amplify rights (`Duplicate` must enforce
  `Has_Rights (Old, New)`).

## Message format

Fixed size, 96 bytes, always copied in full. No count fields.

```text
offset  0: label   u64        protocol-defined; not interpreted by kernel
offset  8: words   u64 [6]    payload
offset 56: caps    u64 [4]    cap handles (sender's table on call,
                              receiver's table on recv), Invalid_Handle = none
offset 88: badge   u64        recv only: badge of the endpoint cap the
                              sender called through (server-chosen cookie)
```

## IPC buffer

Each thread owns one IPC buffer page, created and mapped at thread spawn
at a fixed user VA:

```text
IPC_Buffer_VA = 0x6FFF0000   (just below user stack top 0x70000000)
```

The frame is kernel-allocated, zeroed at spawn, mapped `User_RW`, and
freed by user-address-space teardown. Its physical address is recorded
in the thread's TCB; the kernel accesses the buffer via
`Phys_To_Virt (TCB.IPC_Buffer_PA)` — no page-table walk at syscall
time (the page is kernel-created and never unmapped). Always mapped:
no fault handling needed. Rendezvous transfer is one copy: sender
buffer -> receiver buffer.

Constraint: the VA is fixed per address space, so there is one IPC
buffer per process while processes have a single thread. When
multi-thread processes arrive, per-thread buffer VAs must be
allocated instead.

Rationale: full message is 96 bytes; syscall registers (a0..a5) cannot
carry it on send or return it on recv. Buffer is the canonical ABI.

## Rendezvous and blocking

Callers block in a per-endpoint FIFO queue (TCB-linked; blocked callers
are not in the ready queue, so there is no membership conflict). A
receiver takes the head caller's message; the caller stays blocked
until the receiver replies (or the reply fails). One waiting receiver
per endpoint (single-receiver discipline, same as IRQ lines). Endpoint
finalization fails every queued caller and the waiting receiver with
`endpoint gone` (3).

Wake-with-status: the waker writes the result code into the blocked
thread's saved trap-frame a0 in its TCB context
(`Kernel.Tasks.Set_Saved_Result`) before `Scheduler.Wake`.

Userspace result codes (a0): 0 ok, 1 invalid, 2 transfer failed,
3 endpoint gone, 4 reply gone.

## Syscalls

```text
11 ep_create()        -> a0 handle, U64'Last on failure
12 call(a0 = ep_cap)  -> a0 status; blocks until reply
13 recv(a0 = ep_cap)  -> a0 status; blocks until a caller arrives
14 reply(a0 = 254)    -> a0 status; one-shot reply to current caller
```

Rights checked: `call` requires `Send` on the endpoint cap;
`recv` requires `Receive`.

### call

Blocks the caller until: a server receives the message AND replies.
On entry kernel reads message from caller's IPC buffer. On wakeup the
reply (label + 6 words) is in the caller's buffer; a0 = status.

### recv

Blocks until a caller performs rendezvous. Kernel writes the full
96-byte message into the receiver's buffer: label/words from the caller,
badge from the endpoint cap the caller used, cap slots = handles of
newly installed transferred caps in the receiver's table. Mints reply
cap at handle 254 (see below).

### Cap transfer in messages

- Sender marks up to 4 cap handles in its buffer cap slots.
- Each transferred cap must have `Transfer` right.
- Kernel duplicates each into the receiver's table (full rights copy;
  sender may pre-reduce with `Duplicate` before sending).
- Receiver's buffer cap slots are rewritten to the new handles.
- If any transfer fails (receiver table full), the call fails before
  rendezvous completes; no partial delivery.

## Reply cap

Reserved handle 254 (alongside self address-space cap at 255). Userspace
cannot install anything at 254.

Implementation: no allocation. `recv` mints a cap entry at 254 with
a new `Reply_Object` kind whose object pointer is the caller TCB.
Caller thread is flagged waiting-for-reply.

| Event | Result |
|---|---|
| `reply(254)` | Reply words copied to caller buffer; caller wakes with 0; cap consumed. Second `reply` -> invalid (1). |
| Server exits/is reaped with pending reply cap | Cleanup hook wakes caller with `reply gone` (4). |
| Caller exits while blocked in `call` | Unlinked from endpoint queue; server's later `reply` -> invalid. |
| Server `recv`s again without replying | Cap at 254 overwritten; previous caller wakes with `reply gone` (4). Servers must reply before re-receiving (one outstanding reply per server thread). |
| Endpoint destroyed with queued callers | Each queued caller wakes with `endpoint gone` (3); waiting receiver likewise. |

Properties: server can reply once, to the actual caller only; cannot
stockpile a channel back to the client; no per-client reply endpoints;
no leaks on any death path.

Plain `send` (block-until-received, no reply expected) is deferred;
`call`/`recv`/`reply` covers the RPC pattern.

Deadlock note: A calling B while B calls A blocks forever, undetected
(kernel does no deadlock detection, same as seL4). Protocol rule:
servers must never `call` their clients; the only channel back to a
client is the one-shot reply cap.

## Objects and refcounting

Dynamically-owned shared objects now exist (endpoints, later memory
objects), so refcounting enters the object model:

- Dynamic objects carry `Refcount`. Insert/duplicate/transfer increments;
  cap close decrements; zero destroys via kind-specific finalizer.
- Finalizers: Endpoint — fail/wake any blocked caller and waiting
  receiver; Memory — return frames to PMM.
- Existing static objects (boot MMIO region, IRQ lines) are *pinned*:
  refcount sentinel value, never destroyed. Static allocation stays.
- `Kernel.Objects.Cleanup_Thread_Cap_Object` becomes the
  decrement-and-maybe-destroy dispatcher; endpoint/IRQ waiter cleanup
  stays as part of endpoint/IRQ finalization.

## Memory objects (bulk/DMA)

Raw user pointers never cross IPC. Bulk data (block device DMA, file
reads, shared buffers) moves through `Memory_Object` caps:

- Object owns a set of physical frames; rights Map/Read/Write.
- Client allocates (future syscall), maps locally, sends a derived cap
  plus offset/length in message words.
- Server maps the same frames, performs I/O (driver programs DMA into
  them), replies.
- Refcounted: frames return to PMM when last cap closes.
- No IOMMU yet: DMA drivers are trusted privileged processes.

### Boot files as memory objects

`mem_map` also accepts `Boot_File_Object` caps (Read right; flags
must be read-only): the initrd image frames are mapped borrowed and
read-only (pinned statics, never freed). File data need not start on
a page boundary, so the syscall returns the lead-in byte offset in
a1 (userspace stub `akernel_sys_mem_map_file` / wrapper
`Mem_Map_File`; the asm stub injects flags=read-only). The mappable
extent is the file's true page span, ceil((lead-in + length) / 4096)
pages. Servers holding boot-file caps map files directly instead of
byte-at-a-time `boot_read_byte`.

## File protocol (9P-ish)

Userspace protocol (kernel never parses it) between
System/Fileserver (holds every boot-file cap via the `boot_files`
manifest token) and clients (hold only the `fs` endpoint Send cap):

```text
Op_Set_Name = 0  init -> server: (handle, length, name[32]), one per
                 granted boot file, pushed right after spawn, then a
                 zero-handle terminator
Op_Stat     = 1  words = name[48] -> (status, size)
Op_Open     = 2  words = name[48] -> (status, size); client then
                 allocates/maps its read buffer (memory object)
Op_Read     = 3  (offset, length, name[32]) + buffer memory cap in
                 cap slot 0 -> (status, count); bytes land at offset
                 0 of the client's buffer
Op_Mount    = 4  init -> server: (devlen, labellen, ci-flag,
                 device ++ label chars[24]) from the manifest's
                 volume directive; binds device name + volume label
                 + case-sensitivity to the boot-file set
Op_Add_Block = 5 Op_Mount words + block-driver service endpoint
                 cap; mounts a raw block-backed volume ("disk")
Op_Add_FS   = 6  Op_Mount words + fs-driver service endpoint cap;
                 mounts a VFS-forwarded volume (e.g. System/Fat32)
Op_Write    = 7  (offset, length, name[32]) + buffer memory cap ->
                 (status, count); server consumes the buffer.
                 Boot-file volumes read-only; raw "disk" and
                 fs-driver volumes writable (create in an existing
                 directory; sparse writes rejected)
Op_Delete   = 8  words = name[48] -> (status, 0); deletes a file
Op_Truncate = 9  words = name[48] -> (status, 0); truncates to 0
Op_Mkdir    = 10 words = name[48] -> (status, 0)
Op_Rmdir    = 11 words = name[48] -> (status, 0); empty dirs only
Op_Sync     = 12 no words -> (status, 0); server fans out to every
                 fs-driver volume. Write-through everywhere today,
                 so a verified no-op passthrough; becomes a real
                 flush with write-back caches / device flush.
statuses: 0 ok, 1 not found, 2 not ready, 3 bad args, 4 out of range
```

Block layer (virtio-blk driver and System/Partmgr speak the same
protocol on their service endpoints; partmgr adds op 3):

```text
Blk_Info  = 0  -> (status, capacity in sectors)
Blk_Read  = 1  (sector, count) + buffer cap -> (status, 0);
               count <= 8 (one page)
Blk_Write = 2  (sector, count) + buffer cap -> (status, 0)
part_query = 3 (slot) -> (status, first LBA, size in sectors,
               populated slot count); partmgr only. Clients select
               the partition by cap badge 16#1000#+N (manifest
               partN tokens, or cap_mint'd caps)
```

The FAT32 driver keeps an 8-slot write-through metadata sector
cache (FAT/directory/FSInfo) refreshed from the bounce on every
write; file data bypasses it. Coherence caveat: a raw PDn write
to a mounted partition bypasses the fs driver's cache — do not
raw-write a mounted partition (same rule as host OSes).

Volumes are Amiga-style: a device name (`RD0`) and a volume label
(`Initrd`) both resolve to the mounted file set. Wire names are
qualified (`RD0:System/Init` or `Initrd:System/Init`); volume
prefixes always compare case-insensitively, path comparison follows
the volume's case flag (the initrd mounts `ci`). Unqualified names
are a client-side concern: Akernel_User.Files prepends a default
volume (`RD0`, settable) — the seed of a PATH resolver. Other
devices get their label from the mounted filesystem itself; the
manifest directive is the initrd's boot-time equivalent.

Stateless reads (no fids, no close). The read buffer is client-owned
(replies cannot transfer caps — the reply path zeroes cap slots);
the transferred cap pins the frames while the server holds it. The
server maps boot files via the mem_map boot-file branch (borrowed
RO pages + lead-in offset) and copies into the client buffer mapped
in its own AS. Manifest tokens: `fs_server` (Receive side),
`fs` (Send side), `boot_files` (all boot-file caps in bootinfo
order).

## Namespaces and spawn v2

Namespace = per-process set of caps, Plan 9 style. Kernel moves caps;
names are userspace metadata, never parsed by the kernel.

### Spawn ABI (v2 implemented)

```text
spawn(a0 = image_cap, a1 = grant_count)
  image_cap: Boot_File_Object cap with Read + Execute rights, or a
  Memory_Object cap with Read (ELF staged by a file server: read via
  the file protocol into an object, spawn from the object cap — no
  boot-file cap involved), held by
  the spawner (kernel never sees a path). Grant entries in the
  spawner's IPC buffer at offset 128, max 32, each 24 bytes:
    u64 parent_handle
    u64 rights_mask      (bit 0 Read .. bit 9 Manage, Rights record order)
    u64 badge
```

Kernel mints each entry into the child cap table at sequential handles
1..N. Validation: handle open in parent, not a reply cap, mask within
the valid 10 bits, requested rights a subset of the parent entry's
(monotonically decreasing). Child's namespace is exactly what the
parent grants. Reserved handles 254 (reply) and 255 (self AS) are
kernel-managed.

Uniform spawn regardless of backend: a `Boot_File_Object` (initrd)
or a `Memory_Object` (ELF staged by a file server, implemented:
`Kernel.ELF.Source` abstracts byte reads over a physmap range or the
object's scattered frames, so the loader never needs contiguity) — a
file server hands the spawner a memory cap containing the ELF, killing
the "VFS path for spawn" item.

### Boot file caps

Kernel hands init one `Boot_File_Object` cap per initrd file at boot
(handles 3..N, Read + Execute + Transfer). `Boot_File_Object` =
physmap base + length into the initrd image, refcount-pinned statics
enumerated at boot (`Kernel.Boot_Files.Enumerate`). The boot byte
API (`boot_file_size`/`boot_read_byte`) is cap-based: a0 = boot file
cap with the Read right; it exists only so init can parse the
manifest and is retired once memory-object mapping lets init map
files directly.

### Names as data

- Child discovers names by convention: handle order = grant list order;
  parent may send a `(handle -> name)` table as first message on a
  well-known endpoint cap placed at handle 1 by convention.
- Init gets its bootstrap table from the kernel-provided read-only
  bootinfo page at `0x6FFE0000` (implemented): magic + count header,
  then 64-byte (handle, kind, rights mask, name) entries covering
  every boot file cap and the device_resource authority cap,
  so init hardcodes no handle numbers.

### Manifest stays boot-launch only

Manifest remains init's boot-time program/grant list for initrd
contents (Amiga-ish startup-sequence role). It is not a general
namespace mechanism.

## Users, sessions, permissions

- Init launches a session manager / getty analog. Login spawns a user
  shell with a composed namespace *subset*: e.g. no raw UART MMIO cap,
  only a console channel cap to the console server.
- Permissions = capability possession. Any process holding an image cap
  and resource caps may spawn; it can only grant what it holds, with
  rights no greater than its own. No UID checks in the kernel.
- User identity where needed = a badge on a session endpoint cap,
  minted by the session manager. Servers trust badges only from
  endpoints they minted (same rule as client multiplexing).

## Init state and crash recovery

- Authority lives in kernel cap tables; init's name table is
  reconstructible convention (deterministic handle order + manifest).
- Init is a fatal-fault domain for now (halt/reboot on init death): its
  boot-time caps are kernel-granted and cannot be reacquired.
- Mitigation: keep init tiny; policy lives in spawned servers that hold
  their own caps. Init retains parent caps and can restart/re-grant a
  dead policy server without serialization.
- Future: kernel introspection syscalls for init to query/reconstruct
  state (process list, child cap tables) gated on `Manage` right of the
  process cap. Designed for, not yet scheduled.

## RTS implications

- `Akernel_User.IPC` (implemented): typed wrappers over
  call/recv/reply, generic over request/response payload records
  marshalled into the 6-word area (larger payloads via memory caps).
- `Akernel_User.Streams` (implemented): `Endpoint_Stream`, an
  Ada.Streams `Root_Stream_Type` over endpoint caps, is the
  fundamental I/O substrate (40-byte chunks, Op_Write/Op_Read
  labels, (Count, Data) records); `Akernel_User.Console` binds it to
  the init-minted console endpoint (`console` manifest token /
  devmgr class-0 grant) with Drivers/Serial as the console server.
  Console writes are line-atomic on both paths: the server buffers
  per client (keyed by the console cap badge, which init sets to the
  manifest program id) and flushes to the UART only on newline or a
  full 160-byte buffer; the kernel debug_putchar syscall buffers per
  thread (128 bytes in the TCB) with the same flush rule, plus a
  flush on exit. Concurrent writers never interleave within a line.
  Ada.Streams itself is vendored into the RTS (light runtime lacks
  it) until the real custom RTS lands. File protocol (9P-ish,
  simplified) layers on top later.
- Future tasking runtime: Ada rendezvous maps onto call/recv/reply
  (entry call = call, accept = recv + reply). Non-tasking core first.

## Notification objects (implemented)

seL4-style: a capability-ownable word of pending signal bits
(`Notification_Object`, static slab of 16). Signaling ORs bits in;
waiting consumes them. Rights: Wait = ntfn_wait, Write =
ntfn_signal, Manage = ntfn_bind_thread; creation also carries
Transfer so a signaler mint can cross a message (window protocol
v3: the consumer pushes a Write+Transfer mint to the producer).
The thread binding is thread<->object, not cap<->object: closing
one cap to the object on a live thread never unbinds; the unbind
hook fires only at thread teardown (`Thread_Dying` on
Close_Cap/Cleanup_Thread_Cap_Object, set only by Discard_Slot).
Endpoint/IRQ-line cap-close hooks still clear waiters on any cap
close — safe only because no code deletes a cap while blocked on
the object.

```text
ntfn_create() -> cap handle or fail          (syscall 18)
ntfn_wait(cap) -> bits (blocks until /= 0)   (syscall 19)
ntfn_signal(cap, bits) -> 0/1                (syscall 20)
ntfn_bind_thread(cap) -> 0/1                 (syscall 21)
irq_bind_ntfn(irq_cap, ntfn_cap, badge)      (syscall 22)
  -> 0/1; IRQ cap needs Ack, ntfn needs Write
cpu_count() -> online harts                  (syscall 27)
  -> 1..64; first introspection syscall, lets programs adapt to
  UP vs SMP (Tests/Spin skips itself on UP)
cap_mint(cap, rights_mask, badge) -> cap     (syscall 28)
  derives an attenuated (rights subset) + badged cap in the
  caller's own table; same validation as spawn grant lists.
  Session-manager pattern: badging caps after spawn (init mints
  partN-badged partition-service caps). Note a cap transferred
  in a message must carry the Transfer right.
```

A thread binds at most one notification to itself. IPC_Recv checks
the bound notification before blocking: pending bits are delivered
as a synthetic message (Label = U64'Last, kernel-reserved; word 0 =
bits; no caps, no reply cap). A signal arriving while the bound
thread is blocked in Receive cancels the endpoint wait and delivers
the same synthetic message, so a server multiplexes endpoint
traffic and IRQ notifications on one recv (Drivers/Serial: UART RX
is IRQ-driven this way — the UART IRQ line signals the bound
notification with badge 1, the server drains RBR and acks).

IRQ lines are SHAREABLE (milestone 27): PCI INTx is swizzled onto
four PLIC sources ((dev + pin - 1) mod 4), so the fifth device
onward always shares. Interrupts.Register chains duplicate-source
line objects (registration of the SAME line object still fails
Already_Registered); Deliver walks the chain and pokes every line
— each driver reads its own device ISR to claim the event, level
triggering re-delivers while any partner keeps the line asserted.
Invariant burned: EVERY thread holding an IRQ cap must eventually
irq_ack after being poked — an unacked line holds the PLIC claim
open and silences the source for all partners (the rng driver's
poll-only design silently owned source 35 until the GPU landed on
it; rng now drains + acks like every other driver).

## Deferred

- Plain `send` (notify-style, no reply). Bureau->client input
  delivery dodged the need via shared-memory queues +
  notifications (window protocol v3); revisit if another
  producer->consumer channel needs it.
- Register fast path: `call_small`/`send_small` variants carrying
  label + 4 words + no caps in registers. Pure optimization, no
  protocol change; only if profiling justifies.
- Kernel introspection syscalls for init state reconstruction.
- IOMMU/DMA isolation.
- Cap transfer beyond 4 per message.
