# M80 — grow-on-demand tables (limit-fixes pass)

**Status: planned, not started.** Locked 2026-08-31. Load this file
only when working on M80; RESUME.md carries a one-line pointer.

## The problem

Fixed `Max_*` capacity tables keep failing the same way: silently
full, consumer loses the race. Burns so far: fileserver Max_Files
16 (m34/m37b, silent drop), Max_Process_Slots (m34), Max_Volumes
8→12 (m79b, Net: silently unmounted), notifications 16 (m71b),
netserv socks 8 (m73), bureau windows 4 (m68-ish), bootinfo 1 page
(m38b), boot files 24, devmgr manifest lines 8 (7 used, 9th line
silently dropped). The m34 follow-up rule "VA windows are fixed
literals, never derived from table sizes" already de-risked the
fileserver; this pass deletes the cap class itself.

Direction (user-chosen): **hybrid, growable-first**. Capacity is
policy; the only bound is RAM. seL4's lesson applies: its kernel
does no dynamic allocation — userland retypes untyped memory into
objects, so "table full" is a userland policy decision. We keep
akernel's PMM-backed kernel allocation but steal the principle:
growable slabs at page granularity, exhaustion = plain OOM (already
a hard error everywhere), no magic numbers.

`Max_*` survives only with a written justification in its comment:
wire formats (IPC Max_Words/Caps), hardware rings (virtqueue Num),
geometry (GPU display ceiling), boot-order tables (Max_Reserved,
Max_DMA_Devices), transient staging (deferred stacks).

## Existing kernel template (copy this)

Endpoints (`kernel-ipc.adb:187-258`), devices
(`kernel-devices.adb:34-91`), memory objects (`kernel-memory.adb`)
already do it: `Grow_Pool` allocates one PMM frame, carves
16-byte-rounded slots, pushes each onto an intrusive free list;
frames are never returned (high-water slab); objects are referenced
by raw address from caps with refcount = cap count; all teardown
happens before slot reuse under the BKL. Boot-order confirmed safe:
PMM initializes at akernel.adb:472, first table use is init's first
spawn; the 3 kernel-started processes live outside all tables.

## Hard facts from the census (don't rediscover)

- **pid encoding**: `pid = gen*256 + slot+4` (kernel-processes.adb
  :524-528). Low byte overflows for slots >= 252, so the current
  encoding caps process slots at **252**. Thread ids are a monotonic
  counter from 1024 — thread slots have NO encoding constraint.
- Only userland pid decode: `fuzz.adb:3211`
  (`Pid1 mod 256 = Slot1 + 4`). procfs treats pids opaque.
- Introspection: `Process_Table_Slots=128` is a compile-time mirror
  (akernel_user-syscalls.ads:194); `Slot_Count` returns
  Max_Process_Slots; enumeration probes slots 0..127 and tolerates
  sparseness (`Info_Not_Found` = skip). There is no runtime
  table-size syscall.
- **TCBs/PCBs are referenced by raw address everywhere** (scheduler,
  endpoint queues, reply caps, notification bindings, IRQ waiters).
  Growable tables must never relocate and never return frames.
- Notifications' `Slot_Of` (kernel-notifications.adb:18-36) is the
  only address->index decode in any pool — contiguity arithmetic
  over the static array; multi-frame pools must reimplement it as a
  frame-range walk.
- Scheduler: `Sleep_Index range 0..319` is a hardcoded literal
  (kernel-scheduler.adb:22) decoupled from Max_Tasks=320. Every
  `Wake` result is dropped at 6 call sites (kernel-ipc.adb:124/1090,
  kernel-notifications.adb:99/136/149/162, kernel-interrupts.adb:185,
  kernel-processes.adb:1262); `Sleep_Until` result dropped at
  arch-traps.adb:1174.
- Queued sends (Max 64): pointer-referenced only, full pool already
  falls back to blocking rendezvous — cleanest conversion.
- Occupancy at test boot: processes ~21/128, threads ~35/256,
  notifications ~8 steady / ~18-24 peak of 32 (every netserv client
  socket eats one), fileserver files 94/512, volumes 9-10/12 with
  9p, netserv socks ~6-10/16, bootinfo 96/511, boot files 94/256.
- **s-osinte bug (latent, independent of capacity)**: the
  per-process thread tables hash `kernel_thread_id mod 64`
  (s-osinte.adb: Table_Index). Two threads with congruent kernel
  ids silently clobber each other's ATCB/priority TODAY.
- Userspace has two heaps: GNAT heap at 0x4000_0000 (2 MiB max,
  s-memory.adb) and newlib sbrk at 0x5200_0000 (4 MiB). Shared-RTS
  VA gap 0x4A81_0000..0x5000_0000 is free but small;
  **0x7000_0000..0x7FF0_0000 is free everywhere** per the full VA
  census (bureau ends 0x6B00, thread stacks 0x6F00+, IPC 0x6FFE+);
  M83 moved the user main stack to 0x7FF0_0000..0x8000_0000 (64
  pages), so the M80d helper arena below is **15 MiB**, not 16.
- Crates share `rts/akernel/` as a static library; generics there
  are precedented (Akernel_User.IPC, Virtio.PCI/MMIO). Constraint:
  no library-level elaboration runs in crates — helpers must lazily
  init; s-memory.adb must never `with` the helper (circularity).
- Client socket rings: 1 MiB stride for 2-page rings is pure
  padding; Resolve_VA sits at 0x4A80_0000 right above 8 rings.
- Userspace is NOT told total RAM (bootinfo is caps-only; DTB
  parser ignores /memory) — grow on demand, never RAM-size.

## Slices (each: clean serial build, zero warnings, make test
## SMP4 + SMP1, commit)

### M80a — DEFERRED: process/thread tables growable

Deferred per user decision 2026-08-31. Placeholder instead:
processes stay 128 (6x headroom; encoding ceiling 252 anyway),
threads 256→512 rides along in M80b (one constant + Sleep_Index
derivation), spawn exhaustion gets LOUD (init decodes No_Slot vs
Scheduler_Failed vs Cap_Failed instead of generic "spawn failed"),
fuzz prints process/thread occupancy each run.

Triggers that re-open this slice (cost then ~= cost now; the ABI
surface is frozen and tiny):
- any new userland pid decoding or pid arithmetic;
- any workload approaching ~100 processes;
- any new kernel feature referencing the process/thread tables.

When reopened: chunked record storage (never relocate), encoding
widen to `gen * 2^20 + slot + 4` (update fuzz:3211 —
interface-change exception), generation stamps per-chunk (they live
outside the records because Initialize_* overwrite whole records),
Slot_Count -> high-water + new append-only Sys_Table_Info syscall,
procfs/fuzz enumerate at runtime, Initial_Thread_Slot pinning
dissolves, Max_Queue_Walk=256 (kernel-ipc.adb:370) -> live count.

### M80b — scheduler queues -> intrusive TCB lists

A queue never needs capacity beyond live threads, so linking
through the TCB makes fullness unrepresentable:

- Add `Rdy_Next/Rdy_Prev`, `Slp_Next/Slp_Prev` to the TCB
  (Queue_Next for endpoint queues is the precedent).
- Ready queue: doubly-linked; pop-by-priority stays an O(n) walk
  (today is O(n) shifts — no asymptotic change).
- Sleep queue: sorted linked insert; delete Sleep_Index/Max_Tasks.
- Wake/Sleep_Until/Push can no longer fail -> the six dropped Wake
  results and the dropped Sleep_Until result disappear as a class;
  spawn/thread-create rollback simplifies.
- Threads 256 -> 512 (encoding-free); Max_Queue_Walk derive.
- Deferred stacks stay static per-CPU (transient staging, drained
  every trap entry) but the silent drop at kernel-processes.adb:1441
  gets a debug print + counter — it's a leak indicator.

Risk: touches the scheduler core. Extra boot smoke before the gate.

### M80c — notifications + queued sends -> frame slabs

- Queued sends: endpoint Grow_Pool template verbatim; full-pool
  fallback-to-blocking already exists and stays.
- Notifications (32): frame slab; reimplement Slot_Of as a
  frame-list range+alignment walk. Refcount/bind/cleanup scans are
  already address-based.
- Pressure is real: ~24/32 peak in test boot; every netserv client
  socket + fuzz worker gate takes one.

### M80d — userspace helper + fileserver

- New `userspace/rts/akernel/akernel_user-tables.ads`: generic over
  element type; chunk-append growth over Mem_Alloc (<=64 pages/
  chunk) mapped into a helper arena at **0x7000_0000** (burn-guard
  comment + compile-time window assert per house convention —
  arena ceiling is 0x7FF0_0000, the M83 stack base: 15 MiB =
  **60 chunks of 64 pages**, NOT 64 chunks/16 MiB); lazy
  init; stable indices while entries live (chunk-append, never
  realloc-copy — netserv sock ids, shell job numbers, gloss fds and
  bureau slots are user-visible indices); static 60-entry chunk
  directory (documented sanity bound, e.g. 245K file entries).
- fileserver: File_Table, Volumes, Assigns, Forward_Caps (bounded-
  leak comment retires), Pipes (reclaims 512 KiB BSS), Pendings.
- Fold in: init's Push_* helpers check the reply status WORD (not
  just IPC_Ok) and Debug_Put_Line on failure — kills the silent
  no-mount class for real (the m79 Net: bug).

### M80e — netserv + client sockets RTS + s-osinte

- netserv Socks/Pend/Resolves -> helper. Sock ids are stable chunk
  indices on the wire (badge = id); server Sock_VA window grows
  (stride already 64 KiB). lwIP pools switch to malloc-backed
  (MEMP_MEM_MALLOC) so PCB capacity is RAM (sbrk arena), not
  lwipopts.h constants. Subsumes RESUME open candidate 3
  (AKNET_MAX_SOCKS=8 glue listen table — reconcile while there).
- Akernel_User.Sockets: ring VA stride 1 MiB -> 64 KiB, move
  Resolve_VA; ~128 socks/process in the same 8 MiB; table via
  helper.
- s-osinte: replace the three mod-64 parallel arrays with a
  growable (handle -> ATCB) search table. Fixes the latent
  collision bug.

### M80f — remaining servers

bureau Wins + Z (window ids already decoupled from slots; the
slot->Surf_VA 4 MiB-stride formula needs region planning past ~32
windows — document), devmgr Lines/Input_Svc (+ loud manifest-
overflow print regardless), serial Lines/Sinks, shell Jobs, libman
Entries + client Open_Table, gloss FDs/Dir_Slots, bfs live-query
subscription table (4 slots, m82g — post-census addition; the
overflow resync event stays as the queue-depth backstop).

### M80g — display ceiling 1920x1080

virtio_gpu clamp + attach-backing entry pages (768 -> 2025+
entries, DMA layout adjust), bureau/terminal max-geometry (derived
chunk counts follow), Surf_Max_Objects 8 -> 32. QEMU runtime
opt-in: QEMU_GPU_FLAGS (xres/yres), default stays 1024x768 —
same pattern as QEMU_9P_FLAGS. Smoke: one big-mode boot, bureau's
existing "PASS bureau display info ok" covers the path.

### M80h — policy + docs

- RESUME.md rule rewrite: "capacity tables grow on demand; a static
  Max_* needs a written justification (wire format, hardware ring,
  boot order, transient staging) in its comment."
- Census-comment cleanup on surviving Max_* (wire limits, ring
  sizes, scrollback, text buffers, deferred stacks, boot-time
  Max_Reserved/Max_DMA_Devices).
- fuzz capacity-census group: expected mounts exist (Sys:, Net:,
  Host: when present), occupancy printed via Proc:/Net: each run.

## Explicitly out of scope

- seL4-style untyped retype (architectural redesign; strands
  spawn/grant/bootinfo machinery).
- Cap tables (already paged on demand, RAM-bound).
- Virtqueue Num (hardware), IPC Max_Words/Caps (wire format).
- Bootinfo pages (append-only boot protocol; headroom + loud print
  already).
