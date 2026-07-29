# IPC design

Status: core implemented (ep_create, call/recv/reply, cap transfer,
reply cap, endpoint slab, FIFO caller queue, grant-list spawn with
rights-subset enforcement + badges). Remaining designed-but-unbuilt:
image caps + bootinfo page for spawn, RTS wrappers, init namespace
composition. Deferred items at bottom.

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

## Namespaces and spawn v2

Namespace = per-process set of caps, Plan 9 style. Kernel moves caps;
names are userspace metadata, never parsed by the kernel.

### Spawn ABI (grant lists implemented; image caps pending)

```text
spawn_boot_path(a0 = path_off, a1 = path_len, a2 = grant_count)
  grant entries in spawner's IPC buffer at offset 128, max 32,
  each 24 bytes:
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

Still pending from the v2 design: image cap in place of the manifest
path slice — `Boot_File_Object` (initrd) or `Memory_Object` (ELF
staged by a file server) — and the bootinfo page. Uniform spawn
regardless of backend; kills the "VFS path for spawn" item — a file
server hands the spawner a memory cap containing the ELF.

### Boot file caps

Kernel hands init one `Boot_File_Object` cap per initrd file at boot
(replaces `boot_file_size`/`boot_read_byte` once spawn consumes them;
byte API retired when init no longer needs it). `Boot_File_Object` =
offset/length into initrd image, refcount-pinned statics.

### Names as data

- Child discovers names by convention: handle order = grant list order;
  parent may send a `(handle -> name)` table as first message on a
  well-known endpoint cap placed at handle 1 by convention.
- Init gets its bootstrap table from a kernel-provided read-only
  bootinfo page: (handle, kind, name) entries, so init stops hardcoding
  handle numbers.

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

- `Akernel.IPC`: typed wrappers over call/recv/reply, generic over
  payload records marshalled into the 6-word area (larger payloads via
  memory caps).
- `Akernel.Streams`: `Root_Stream_Type` over endpoint caps becomes the
  fundamental I/O substrate; file protocol (9P-ish, simplified) layers
  on top.
- Future tasking runtime: Ada rendezvous maps onto call/recv/reply
  (entry call = call, accept = recv + reply). Non-tasking core first.

## Deferred

- Plain `send` (notify-style, no reply).
- Register fast path: `call_small`/`send_small` variants carrying
  label + 4 words + no caps in registers. Pure optimization, no
  protocol change; only if profiling justifies.
- Notification/signal objects (Amiga signals analog); IRQ wait is the
  current proto-notification.
- Kernel introspection syscalls for init state reconstruction.
- IOMMU/DMA isolation.
- Cap transfer beyond 4 per message.
