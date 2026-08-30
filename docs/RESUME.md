# Akernel resume

Live state and open work. Earlier milestones live in `git log`.
The previous full resume is archived at `docs/HISTORY.md`.

## Recently shipped

- **Milestone 65** — Tier-1 shared library manager (`System/Libman`).
  Version/revision enforcement, reference counting, per-client caps,
  private-spawn fallback when no manager is bound.
- **Docs** — Trinket widget/window/rendering docs under
  `docs/trinket/`; Ravenscar tasking runtime design under
  `docs/runtime/tasking.md`.

## Active

**Milestone 66 — kernel thread primitives** (see
`docs/runtime/tasking.md`).

- [x] Add `Thread_Create`, `Thread_Exit`, `Thread_Self` syscalls.
- [x] `Sleep_Until` syscall + kernel sleep queue + timer programming.
- [x] Move to per-thread IPC buffers (initial thread keeps the legacy
  `0x6FFF_0000` VA; secondary threads supply a memory cap + VA).
- [x] Set `tp` from a syscall argument so each task can have TLS.
- [x] Add a minimal userspace thread test before touching Ada tasking.
- [x] Stabilise the test suite under SMP4 (the console-endpoint race
  that broke the shell is fixed; `make test` now passes).
- [x] Add `Tests/Thread_Test` to the auto-spawn manifest and make the
  full suite pass with it present.

### M66c/WIP state (thread test)

Done this session:

- Added `.tdata`/`.tbss`/`.tls_copy` sections to
  `userspace/rts/akernel/linker-riscv64.ld`.
- `start-riscv64.s` now copies the TLS template and zeros `.tbss`;
  secondary threads arrive with `tp` already set by the kernel.
- Added `userspace/thread_test/` crate and wired it into
  `INITRD_CRATES`/test manifest.
- Added `akernel_thread_entry` runtime trampoline so secondary
  threads get `gp` before calling the Ada worker.
- Fixed `Thread_Create` to map the new thread's kernel stack into the
  process address space (missing mapping was causing a kernel page
  fault on first trap).
- Fixed `Thread_Exit` not to deallocate the currently-running kernel
  stack before the context switch.
- Guarded `Kernel.IPC.Wake_With_Result` so it only modifies the saved
  context of blocked threads; this stopped a ready worker's saved `a0`
  (the real function address) from being overwritten with `0`.
- `thread_test` itself now passes: worker runs, sets `Worker_Done`,
  exits, and the main thread wakes and prints `PASS thread_test`.
- Added `Akernel_User.IPC.Send` (one-way Send) to the runtime IPC
  wrapper.
- Fixed a stale `Waiting_Receiver` bug in `Kernel.IPC.Call`/`Send`:
  when the registered receiver is not actually blocked in `Receive`
  (e.g., it is doing a nested `Send`), the stale reference is now
  cleared before the caller is enqueued.
- Fixed `Kernel.IPC.Receive` so the same thread can retake the
  receiver slot if `Waiting_Receiver` points back to itself.
- Changed the kernel's `IPC_Send` trap handler so `Send` is
  fire-and-forget: it queues the message and returns `Ok` instead of
  blocking the caller when no receiver is waiting. This prevents the
  console server from deadlocking against a sink that has not
  attached yet.
- Changed the console server's `Sink_Write` to use the new `Send`
  instead of a nested `RPC.Call`.
- Updated `userspace/fuzz/fuzz.adb` to skip the new thread syscalls
  (36-38) during the random syscall phase so a stray
  `Thread_Create`/`Thread_Exit` cannot corrupt the fuzz process.
- Added a memory fence in `Thread_Test_Sync.Worker` after setting the
  shared done flag.

Current state:

- `thread_test` passes reliably in isolation (SMP1 and SMP4).
- `userspace/thread_test/` is built and installed in the initrd,
  and `Tests/Thread_Test` is now part of the default test manifest.
- `make test` with the default `QEMU_SMP=4` passes end-to-end with
  `Tests/Thread_Test` present (verified multiple consecutive runs).
- The full-manifest hang was caused by a thread free-list bug:
  `Kernel.Processes.Initialize` linked the *initial* thread slots
  (0..127, one per process slot) into the secondary thread free
  list, so the first `Thread_Create` reused an in-use initial-slot
  TCB and corrupted an existing process.  The fix initializes the
  free list to only contain the secondary slots (128..255).

Root cause fixed this session:

- The terminal (and serial server) were replying to every received
  message, including plain one-way `Send`s.  After `Sink_Write` was
  switched to the new fire-and-forget `Send`, the terminal's reply
  with `Reply_Handle = 0` returned `IPC_Invalid`, caused it to exit,
  and took down the console/shell path.  The terminal now only
  replies when `Reply_H /= 0`.

Other fixes applied:

- `Handle_IPC_Call` and `Handle_IPC_Recv` now preset the saved a0
  result to `Result_Ok` before blocking, so a missed or misplaced
  wake no longer leaves `Result_Invalid` in the caller's hands.
- `Kernel.IPC.Call`/`Send` clear a stale `Waiting_Receiver` before
  enqueuing a caller.
- `Kernel.IPC.Receive` lets the same thread retake its own receiver
  slot.
- The `IPC_Send` trap handler is fire-and-forget; `Sink_Write` uses
  it instead of a nested blocking `RPC.Call`.
- The console server no longer self-destructs when a reply cap is
  stale or a caller has died.
- `userspace/fuzz/fuzz.adb` skips syscalls 36-38 in the random phase.
- Secondary-thread kernel stacks are no longer leaked: a thread
  exiting on its own stack records the frame on a per-CPU deferred
  list, and the trap handler / idle loop drain the list once the
  hart is running on a different stack.

## Active

**Milestone 67a — `Thread_Wait` (join)**.

- [x] Kernel wait list per thread (head + next + back-pointer) so a
  caller can block until the target exits.
- [x] `Blocked_Thread_Wait` thread state; wake path sets a0 = Ok.
- [x] `Thread_Wait` syscall (40): validates `Thread_Object` cap with
  `Wait` right, returns immediately if target is already dead,
  otherwise blocks and is woken by the target's exit path.
- [x] Waiter cleanup on process exit (`Mark_Exited` removes each
  dying thread from any target's list and wakes any waiters of
  the dying threads).
- [x] `Akernel_User.Syscalls.Thread_Wait` wrapper and raw asm.
- [x] `userspace/thread_test/thread_test.adb` now also exercises
  `Thread_Wait` on the worker cap.
- [x] Fuzz skip list updated for syscall 40.
- [x] `make test` passes end-to-end under SMP4 and SMP1.

**Milestone 67b — Ravenscar runtime skeleton (done)**.

- [x] Vendored the `light-tasking-polarfiresoc` GNARL sources into
  `userspace/gnat-rts/gnarl_user/` as the starting point.
- [x] Wrote a minimal `System.OS_Interface` (`gnarl_user/s-osinte.adb`)
  that sits directly on Akernel syscalls instead of `System.BB`.
- [x] Wrote a minimal `System.Task_Primitives.Operations`
  (`gnarl_user/s-taprop.adb`) that creates threads, delays, and
  exits via the Akernel syscall layer.
- [x] Provided an Akernel-specific `System.Multiprocessors` that does
  not depend on `System.BB`.
- [x] Added the missing fields to `System.Tasking` records
  (`Global_Task_Lock_Nesting` in `Common_ATCB`, `Current_Excep` in
  `TSD`) so the tasking `System.Soft_Links` body can compile.
- [x] Added a tasking `System.Soft_Links` body and a tasking
  `System.Init` so `No_Tasking` can be removed for the tasking
  runtime build.
- [x] Added `pragma Profile (Jorvik)` to the tasking `system.ads`
  so the compiler emits Ravenscar tasking calls.
- [x] Merged the tasking runtime into the single Akernel GNAT
  runtime: `userspace/gnat-rts/runtime_build.gpr` now uses
  `gnarl_user/` before `gnat_user/` and excludes the
  non-tasking units, and the separate tasking-only project and
  `No_Tasking` runtime have been removed.
- [x] Created `userspace/task_test/` crate with a library-level
  task that delays and prints.
- [x] The runtime compiles and links; `task_test` builds and the
  kernel successfully spawns it.
- [x] Fixed the runtime `Create_Task` success check, reduced the
  tasking `Default_Stack_Size` to 1 MiB (the kernel object limit is
  256 pages), and skipped TLS allocation when `TLS_Size` is 0.
- [x] Added a `User_Thread_Cap` field to the kernel TCB and made
  `Thread_Self` return the thread cap handle, fixing the worker's
  `Self`/`Get_ATCB` lookup.
- [x] `task_test` now passes: the worker schedules, prints, delays,
  sets the done flag, and exits; the main thread wakes and prints
  `task_test: main done`.
- [x] `make test` passes end-to-end with `Tests/Thread_Test`
  present.
- [x] The non-tasking runtime (`gnat_user/system.ads` with
  `No_Tasking`, plus `s-init`/`s-soflin` non-tasking bodies and the
  separate `gnat-rts-tasking` project) has been deleted. All
  userspace Ada programs now build against the unified Ravenscar
  tasking runtime.
- [x] Fixed `gnarl_user/s-init.adb` so `Runtime_Initialize` calls
  `System.Tasking.Initialize`; this makes the tasking soft links
  (global locks via `Self`/`Get_ATCB`) work for programs that do
  not declare any Ada tasks.
- [x] Updated the Makefile to regenerate the runtime
  `ada_source_path`/`ada_object_path` files and to provide a
  `libgnarl.a` placeholder so gprbuild recognizes the tasking runtime.

**Cleanup pass (done).**

- [x] Replaced the empty `libgnarl.a` placeholder with a real
  GNAT/GNARL split: after `gprbuild` produces `libgnat.a`, the
  Makefile moves the GNARL objects (`s-taprop`, `s-taskin`,
  `s-osinte`, `a-reatim`, etc.) into `libgnarl.a` and deletes them
  from `libgnat.a`.
- [x] Dropped `Asm` from `userspace/rts/akernel_program.gpr`'s
  base language list and added a per-crate `Asm` override in
  `userspace/fuzz/fuzz.gpr` so only crates with assembly sources
  compile `Asm` (eliminates the "no sources of language Asm" warnings).
- [x] Added `.note.GNU-stack` to all `.s` files and
  `-Wl,-z,noexecstack` to the program linker switches; this removes
  the `requires executable stack` linker warning.
- [x] Added `-Wno-deprecated-declarations` and
  `-Wno-unused-variable` to the runtime C flags so the vendored
  `adaint.c` / `sysdep.c` files build silently.
- [x] Fixed every kernel Ada warning/style diagnostic:
  redundant `with`/`use type` clauses, unreferenced constants and
  local functions, unused variables, line-too-long style errors,
  multiple blank lines, and the always-false `Diff < 0` check in
  `Kernel.Notifications.Slot_Of`.
- [x] Fixed every userspace Ada warning diagnostic:
  lower-bound assumptions on string slices, the uninitialized
  aggregate in `Akernel_User.Gloss.Fill_Stat`, and the incorrect
  `pragma Unreferenced (PX)` in `Trinket.Widgets`.
- [x] Full `make clean && rm -rf userspace/gnat-rts/adalib
  userspace/gnat-rts/obj && make all` now builds the whole system
  with **zero compiler/linker warnings**, and `make test` passes
  end-to-end.
- [x] Fixed the SMP1 test-suite slowdown caused by the unified
  tasking runtime: `System.Soft_Links.Task_Lock_Soft`/
  `Task_Unlock_Soft` now short-circuit (no `Self`/priority
  syscalls) for programs that never create secondary threads.
  This restores the previous single-thread performance while
  keeping full locking once `Create_Task` has run. `make test
  QEMU_SMP=1` now completes in normal time again; `make test`
  (SMP4) and interactive boot remain passing.

**Milestone 41b — `Proc:self` / VFS client identity (done).**

- [x] Added an endpoint-level identity-stamp flag in `Kernel.IPC`.
  When set on an endpoint, a zero-badged capability call through it
  gets the caller's process id as `Message.Badge` instead of badge
  zero.
- [x] Added syscall `EP_Set_Stamp_Identity` (41); init marks the
  fileserver endpoint with it after creation.
- [x] `userspace/fileserver/fileserver.adb` forwards `Proc:` driver
  requests through a per-caller cached, minted cap carrying the
  original caller pid; other fs-driver volumes keep using the
  unminted endpoint cap to avoid per-request overhead.
- [x] `userspace/procfs/procfs.adb` resolves `Proc:self` and
  `Proc:self/status|caps|regs` from the forwarded badge.
- [x] `Process_Info(Self_Slot)` no longer requires the
  `device_resource` authority; a process can read its own pid.
- [x] `userspace/fuzz/fuzz.adb` checks its own pid against
  `Proc:self/status`.
- [x] Stabilised the suite under SMP4 after the identity plumbing:
  switched `Run_Command`'s reap poll and the teardown test's
  caller/receiver sequencing from fixed-yield counts to short
  wall-clock waits, so SMP4 scheduling does not outrun the peers.
- [x] `make all` builds with zero warnings; `make test QEMU_SMP=1`
  and `make test QEMU_SMP=4` pass end-to-end.

**Milestone 67 — MSI-X for virtio PCI (done).**

- [x] Implemented a software MSI controller on top of the RISC-V IOMMU:
  MSI/MSI-X writes are detected by address pattern, forced to fault on an
  invalid flat MSI page table, and converted into virtual kernel IRQ
  source deliveries by the fault-queue handler.
- [x] Added virtual IRQ sources (1024..2047) alongside real PLIC sources
  (0..1023); `IRQ_Ack` skips PLIC completion for virtual sources.
- [x] Added syscall `IRQ_MSI_Create` (42): returns an IRQ cap and the
  MSI address/data to program into the PCI MSI/MSI-X table entry.
- [x] Device manager parses the PCI MSI-X capability, maps the table,
  allocates one shared vector per PCI function, programs all table
  entries, and hands the MSI IRQ cap to drivers in the config message.
- [x] `Virtio.PCI` learned `Enable_MSIX`; all PCI virtio drivers
  (`virtio_blk`, `virtio_rng`, `virtio_input`, `virtio_gpu`) use the MSI
  vector when offered and fall back to INTx otherwise.
- [x] `make all` builds with zero warnings; `make test QEMU_SMP=1` and
  `make test QEMU_SMP=4` pass end-to-end.

**Milestone 68 — Trinket app port: Swing-style worker messaging (done).**

- [x] `Trinket.App_Port`: one-page process-shared ring (127 four-word
  messages `Code, A0, A1, A2`), multi-producer `Post` (PO-locked,
  drop-new) and single-consumer `Drain`; code 0 reserved for quit;
  signals bit 2 on the loop thread's bound notification.
- [x] `Trinket.Window` integrates the port: `Post`/`Set_App_Handler`,
  `Request_Quit` re-implemented as a posted quit message (safe from
  any thread), `Run` drains the port on every notification wake.
  Public API source-compatible.
- [x] Ravenscar runtime SMP-safety fixes (`userspace/gnat-rts/
  gnarl_user`): runtime task lock is a spin-lock with `Yield` backoff
  plus a per-task priority-ceiling boost recorded in a new per-ATCB
  field (the single global saved-priority slot raced across harts);
  task creation initializes the kernel-visible priority table; task
  activation restores the saved ACTIVE priority (was permanently
  raising the activator's kernel priority); runtime initialize syncs
  its priority bookkeeping with the kernel instead of trusting
  `Main_Priority`.
- [x] Kernel: unbound `Ntfn_Wait` blocking was a one-way trip —
  `Signal` only woke the bound thread. Notifications now record a
  single waiting thread (`Record_Waiter`/`Clear_Waiter`); `Signal`,
  `Release`, `Discard`, and cap cleanup wake/clear the waiter.
- [x] Kernel: fire-and-forget `Send` no longer queues the live caller
  thread (its next IPC op clobbered the buffer, badge, and queue
  links — a send followed by a report call cross-delivered the call
  to the send's receiver; deterministic SMP1 failure). The message is
  now copied into a fixed pool of queued-send slots (64, system-wide)
  chained off the endpoint; cap-carrying sends and a full pool fall
  back to the blocking rendezvous. See `docs/IPC.md`.
- [x] Headless port test `userspace/fuzz/fuzz_port` (worker tasks
  gated on per-worker notifications, watchdog task, 24 checks:
  single/two-producer FIFO, overflow, quit interception) and the
  tdemo Work button (a worker task loads/decodes an image off the
  event thread and Posts the result; the dispatch thread swaps it
  into the widget tree via the new `Widgets.Set_Image` — see
  `docs/trinket/window.md`).
- [x] `make all` builds with zero warnings; `make test QEMU_SMP=1`
  (2/2) and `make test QEMU_SMP=4` pass end-to-end.

**Milestone 69 — shell background pipelines (done).**

- [x] `run` accepts the full pipeline/redirection syntax
  (`run A | B > file`): the m46b `Run_Pipeline` split into
  `Spawn_Pipeline` (parse/wire/spawn, out-params for stage caps +
  pipe names) and `Reap_Pipeline` (blocking reap-all, RC = last
  stage, caps + pipes deleted); the foreground path is unchanged.
- [x] Jobs are process groups: `Job_Rec` carries up to 4 stage
  proc caps + owned pipe names; `Harvest` polls every stage (a
  job is done when all stages exit; the code is captured from the
  last stage whenever it happens to finish); `wait`
  blocking-reaps a whole group; `pri` applies to every live
  stage.
- [x] Background pipes are slot-scoped `PIPE:BG<j><s>` names so
  the rotating foreground `PIPE:SH<n>` pool can never truncate a
  live job's pipe; deleted when the job is reaped. A spawn
  commits to a job slot only after every stage is live (mid-spawn
  failure cleans up locally — no half-registered jobs).
- [x] `Fileserver_Pipes.Max_Pipes` 8 -> 32: background jobs hold
  their pipes until reaped (8 jobs x 3 pipes = 24, plus
  foreground shells).
- [x] Fuzz e2e via batch scripts: background
  `Type | Sort > file` verified byte-for-byte, last-stage RC
  composes with failat, two concurrent background pipelines +
  bare `wait`, BG pipes deleted on reap (Stat never creates a
  pipe, so absence is observable), bad background pipeline
  rejected with RC 10. (Write_File's staging Buf grew to 128
  bytes for the longer script texts, with a bound guard.)
- [x] `make all` builds with zero warnings; `make test
  QEMU_SMP=1` and `make test QEMU_SMP=4` pass end-to-end;
  desktop boot smoke clean.

## Active

**Milestone 70 — AmigaDOS-style script interpreter (done).**

- [x] New library crate `userspace/scripting/`: the root package
  holds the uniform-ABI handle constants + Split_Cmd (no U64
  subtype, so `use Scripting` is safe next to Syscalls);
  `Scripting.Exec` is the shell's stage/spawn/reap + pipeline
  engine extracted unchanged (chunk 1); `Scripting.Interp` is the
  interpreter core as a generic child — the host instantiates it
  with its own dispatcher and ask reader (formal subprograms, no
  accessibility trap), so script lines run builtins and nested
  `execute` re-enters with Depth + 1.
- [x] Language: .key/.k positional args + .def defaults, .set
  locals (defined-empty vs undefined — undefined <name> is a hard
  RC 10 "bad substitution"), <name> resolves locals then ENV:
  (<$name> forces ENV:; '<' only opens a reference when closed by
  '>' on the same line, so `< file` redirection and `a<b` stay
  literal); if [not] with exists / eq|ne|gt|ge|lt|le [val] /
  command forms (condition RC consumed), bare if tests the
  condition flag; else/endif 8 deep, skipped blocks never
  expanded; lab/skip [back] (skip abandons open if frames — the
  loop idiom relies on it); quit [rc]; failat <n>; echo [noline]
  (metachar lines fall through to C:Echo so > file composes);
  ask (condition flag from y/Y, RC_Warn 5 on "no").
- [x] New `Sys:C/Execute` binary (chunk 4): scripts without a
  shell, `run Sys:C/Execute s` backgrounds a script as a reapable
  job; its ask reads stdin via CLI.Get_Line so
  `echo y | Execute s` composes. The shell's ask reads the raw
  console stream (`Scripting.Console_IO.Read_Line`).
- [x] Stack fix: per-level line buffers + the locals table moved
  to the heap — five nested scripts over ~4 KiB frames each
  page-faulted the 48 KiB process stack before the depth cap
  fired. Run_Script owns the nesting counter (top-level batch
  script = Depth 1).
- [x] Fuzz e2e: byte-exact .key/.def/.set/substitution checks,
  ENV: shadowing + <$>, literal '<', bad-subst abort, nested
  execute args, every if arm, skip forward + skip-back loop
  (FZL1..3 one per pass), quit 7, inner quit 20 tripping the
  outer failat, failat 21 passing RC 20, echo > file, skipped-
  block substitution safety, the four malformed-script errors,
  C:Execute direct/piped/backgrounded, depth cap.
- [x] `make all` builds with zero warnings; `make test
  QEMU_SMP=1` and `make test QEMU_SMP=4` pass end-to-end;
  desktop boot smoke clean. Language reference:
  `docs/shell/scripting.md`.

## Active

**Milestone 71 — network stack** (plan locked 2026-08-25).

**M71a — VirtioNet driver (done).**

- [x] New crate `userspace/virtio_net/`: class-1 PCI driver on the
  virtio_blk skeleton; two split queues (RX=0/TX=1, Num=16), 16
  pre-posted 2048-byte RX slots (descriptor id == slot, repost on
  Pop), no feature negotiation beyond F_MAC (transitional device →
  legacy 10-byte `virtio_net_hdr`, confirmed working), MAC from
  device cfg, MSI-X via the shared per-function vector.
- [x] Frame service protocol on handle 7: `Op_Info=0` (MAC, MTU),
  `Op_Tx=1` (client frame memobj DMA'd directly as the second
  descriptor of a 2-chain; our zeroed header staging is the first),
  `Op_Set_Rx=2` (single consumer: ring memobj mapped for the
  driver's lifetime + netserv ntfn; frames published into
  {head, tail, dropped, slot count} + 2048-byte slots, drop-new
  with counter, ntfn bit 0 per batch).
- [x] Boot self-test: TX a crafted ARP request for 10.0.2.2
  (static slirp guest 10.0.2.15), wait for the reply —
  `PASS virtio-net arp reply ok`.
- [x] Wiring: devmgr records `Net_EP` for class 1 (first-wins,
  both spawn paths) and exports `Net_Service`; `driver pci,1af4
  Drivers/VirtioNet pci 1`; QEMU `-netdev user,id=n0 -device
  virtio-net-pci,netdev=n0,addr=0x8` (INTx swizzle 32, MSI-X
  takes over anyway).
- [x] Fuzz housekeeping: `Highest_Known` 35 → 42 (stale since
  M67), skip 42 (`irq_msi_create` fills kernel IRQ slots).
- [x] Full `make clean` + `make all` with zero warnings;
  `make test QEMU_SMP=1` and `QEMU_SMP=4` pass end-to-end.

### M71 remaining plan (locked 2026-08-25)

**M71b — Netserv skeleton (done).**

- [x] New crate `userspace/netserv/` (`System/Netserv`, manifest
  `program 10 System/Netserv console fs netdev net_server`):
  Ethernet demux, ARP (16-entry cache, learns requesters and
  repliers, answers requests, no aging, round-robin eviction),
  IPv4 (software checksums both ways, TTL 64, IHL=5 only, MF /
  fragment-offset dropped, dst must be us), ICMP echo requests
  answered and echo replies matched to the outstanding ping.
- [x] Op_Ping=40 on the service endpoint: word0 = target IPv4
  packed big-endian; reply (status, rtt in Read_Time ticks);
  status 0 ok / 1 no reply / 3 bad args. Ping self short-circuits
  (real hairpin lands with m71c sockets). ARP resolve and the
  echo wait are inline bounded poll-drains of the RX ring
  (2 s / 5 s deadlines) — the plan's "queue pending TX" is
  subsumed until m71c's decoupled socket TX needs a real queue.
- [x] Driver bring-up: Op_Info (MAC/MTU), 5-page RX ring memobj
  (8 slots) + thread-bound ntfn registered via Op_Set_Rx
  (Map+RW+Transfer mint for the ring, Write+Transfer mint for the
  ntfn; both mints deleted after the call, driver keeps its
  transferred copies for its lifetime). TX: one staging memobj,
  a Read+Manage+Transfer mint reused per Op_Tx.
- [x] Service loop: single IPC_Recv multiplexing Op_Ping, the
  file protocol (Net: registered via Op_Add_FS, empty root in
  m71b; read/write buffer caps deleted per op — procfs leaks
  them on rejected writes), and Notification_Label RX kicks.
- [x] Config: static 10.0.2.15/24 gw 10.0.2.2 dns 10.0.2.3,
  ENV:Net.Address/Gateway/DNS dotted-decimal overrides read
  through the fs token.
- [x] `Tests/Net_Test` (test-mode manifest `program 11
  Tests/Net_Test console net`): gateway ping (reply + RTT <
  1 s), self ping, unreachable 10.0.2.99 (ARP timeout →
  status 1), bad-args rejection.
- [x] Kernel fix: `Max_Notifications` 16 → 32 — the pool was
  exactly full in m71a (14 steady + fuzz's 2 test objects);
  netserv's one ntfn tipped it and starved fuzz's ntfn phase
  ("ntfn create distinct handles" FAIL, then the app-port test
  wedged). Cap accounting audited first: insert retains,
  delete/exit releases, no leak — netserv holds exactly one
  object steady-state.
- [x] Full `make clean` + `make all` zero warnings; `make test`
  SMP1 and SMP4 pass end-to-end (twice on SMP4).

**M71c — sockets + ping + Net: (done), with one amendment.**

- [x] Socket ops in netserv: `Op_Socket=20` (words
  domain/type/proto; cap0 two-page ring-pair memobj, cap1 client
  ntfn) → **(status, socket id) in reply WORDS — caps do not
  travel in IPC replies in this kernel (Kernel.IPC.Reply drops
  them; transferring there was tried and reverted: servers leave
  dead request caps in their reply buffer, and every reply site
  in every server would have needed auditing). The client mints
  its own cap on the service endpoint with badge = socket id
  instead.** Badges demux, they are not authority (the pid
  badges the file server forwards are equally self-asserted).
  Ops on the badged mint: `Op_Bind=21` (0 = ephemeral from
  49152+), `Op_Connect=22` (default peer + RX filter),
  `Op_Kick=23` (one-way Send), `Op_Poll=24` → (status, rx
  level, tx free, sticky error), `Op_Close=25`. Server → client
  ntfn bit 0 = RX readable, bit 1 = sticky error.
- [x] Ring pair: page 0 RX (server produces), page 1 TX (client
  produces); word0 head / word1 tail / word2 dropped; 4 slots ×
  1008 at offset 64; entry = len:u16, flags:u16, addr:u32,
  port:u32, ≤996 payload. TX entries carry the destination (0 =
  the Connect default); RX entries the source. Wire datagrams
  truncate at 996 (recv semantics).
- [x] UDP: closed local port → ICMP port-unreachable on the
  wire; hairpin (dst == own address) delivers internally, a
  closed hairpin port sets the sender's sticky error (1 =
  hairpin closed, 2 = ARP failed, 3 = usage). UDP checksum 0 on
  TX (legal in v4).
- [x] ICMP ping sockets (SOCK_DGRAM/IPPROTO_ICMP): netserv owns
  type/code/ident/checksum and the IP header; ident = socket id
  makes reply matching trivial; hairpin fabricates the reply.
- [x] `Akernel_User.Sockets` (Socket/Bind/Connect/Send_To/
  Recv_From/Poll/Close/Parse_IP/Ip_Image): client VA window
  16#4A00_0000# (16#4600# is the link base, 16#4800# the args
  page); waits poll the rings in 5 ms Sleep_Until slices.
- [x] Uniform command ABI gains handle 6 = netserv client
  endpoint (Scripting.Net_EP). Granted by: devmgr Spawn_Program
  (Sys: programs see it at handle 5), terminal → shells (6),
  fuzz → batch shells/commands (6; fuzz manifest token handle
  11), Scripting.Exec → commands (6). An invalid grant source
  fails the whole spawn — all spawners were extended in the same
  commit.
- [x] `Sys:C/Ping` (`ping [-c N] <ipv4>`, numeric only): RC 0
  all answered / 5 partial / 10 none-or-usage; RTT from the
  echoed timestamp payload.
- [x] `Net:` volume: status/address/gateway/dns/arp readable
  (root stat-able + enumerable; m64 is_dir in word 4);
  address/gateway/dns writable (dotted decimal, offset-0
  whole-value writes). Read/write buffer caps mapped at
  16#54A0_0000#, deleted per op. File-op dispatch is by LABEL
  (0..18), never badge — forwarded ops carry pid badges.
- [x] `Tests/Udp_Test` (manifest program 12, test mode): reads
  its own address from Net:address, hairpin A→B with source
  reporting + payload integrity, closed-port sticky error.
- [x] Fuzz e2e: `ping -c 1 10.0.2.2` RC 0, `ping -c 1 10.0.2.99`
  RC 10, `type Net:status` RC 0.
- [x] Full `make clean` + `make all` zero warnings; `make test`
  SMP1 and SMP4 pass end-to-end.

### M71 remaining plan (locked 2026-08-25)

Locked decisions: UDP+ICMP first, TCP is its own milestone (hand-rolled
Ada vs vendored lwIP decision deferred until M72); socket data plane =
per-socket shared ring pairs + notification readiness bits (app-port
style); runtime config = writable `Net:` volume served by netserv,
seeded from `ENV:Net.*` at boot; no new syscalls — everything is
endpoint protocols (socket ops are message labels, payloads move in
memobj caps/rings).

Layering:

```
Sys:C/Ping, user programs
  |  Akernel_User.Sockets  (client lib in rts/akernel)
  v  NETSRV_EP: socket ops as message labels; minted per-socket caps
  |  (badge = socket id, partmgr pattern); shared rings + client ntfn
System/Netserv  — Ethernet demux, ARP, IPv4, ICMP, UDP, Net: volume
  |  NETDEV_EP: frame protocol (Op_Info / Op_Tx / Op_Set_Rx ring+ntfn)
  v
Drivers/VirtioNet — class-1 PCI driver: RX/TX split queues, MSI-X
  v
QEMU: -netdev user,id=n0 -device virtio-net-pci,netdev=n0,addr=0x8
      (slirp: guest 10.0.2.15/24, gateway/DNS 10.0.2.2 / 10.0.2.3)
```

Chunks:

- **M71a — VirtioNet driver.** Two split queues (RX=0/TX=1, Num=16),
  RX pre-posted 2048-byte slots from a DMA memobj (repost on Pop,
  virtio_input eventq model), no feature negotiation (word 0 = 0 →
  transitional device runs legacy → 10-byte `virtio_net_hdr`; verify
  on first boot). MAC from device cfg offset 0..5. Service protocol:
  `Op_Info=0` → (status, mac_lo, mac_hi, mtu); `Op_Tx=1` (cap0 frame
  memobj, word0 length); `Op_Set_Rx=2` (cap0 RX ring memobj, cap1 ntfn
  Signal cap; single consumer; driver publishes frames, signals bit 0).
  RX ring: {head, tail} header + 2048-byte slots. Self-test: TX a
  crafted ARP request for 10.0.2.2, expect a reply frame. Wiring:
  devmgr records Net_EP for class 1 (first-wins, both spawn paths),
  `driver pci,1af4 Drivers/VirtioNet pci 1`, QEMU netdev line.
  Housekeeping: fuzz Highest_Known 35 → 42 and skip irq_msi_create.
- **M71b — Netserv skeleton.** ARP (16-entry cache, queue pending TX,
  answer requests, no aging), IPv4 (software checksums, TTL 64, drop
  frags/options), ICMP echo request+reply both ways, internal Op_Ping
  test op (RTT via Read_Time). Static config 10.0.2.15/24 gw/dns
  10.0.2.2/10.0.2.3, ENV:Net.* override. Manifest
  `program 10 System/Netserv console fs netdev net_server`; init mints
  NETSRV_EP (tokens: net_server = Receive, netdev = driver Send,
  net = client Send), pushes Op_Add_FS label Net. Single IPC_Recv
  multiplexing ops + synthetic Notification_Label RX kicks.
  Tests/Net_Test: ping the slirp gateway, assert reply + sane RTT.
- **M71c — sockets + ping + Net:.** `Op_Socket=20` (words
  domain/type/proto; cap0 ring-pair memobj, cap1 client ntfn) → minted
  socket cap (badge = socket id); ops on the socket cap: `Op_Bind=21`,
  `Op_Connect=22` (UDP default peer + filter), `Op_Kick=23` (one-way
  Send, "TX ring dirty"), `Op_Poll=24` (rx level/tx space/error),
  `Op_Close=25`. Server → client ntfn bit 0 = RX readable, bit 1 =
  error/closed. Datagram ring entry {len:u16, flags:u16, src_addr:u32,
  src_port:u32, payload…}. UDP sockets with closed-port → ICMP
  port-unreachable and hairpin loopback (dst == own addr loops
  internally — self-contained test). ICMP ping sockets =
  SOCK_DGRAM/IPPROTO_ICMP (Linux ping-socket semantics: netserv owns
  the IP header, assigns ident per socket, matches echo replies).
  `Akernel_User.Sockets` client lib (Socket/Bind/Connect/Send_To/
  Recv_From with ntfn+Sleep_Until timeout/Close/Poll). `Sys:C/Ping`:
  `ping [-c N] <ipv4>`, numeric only, Amiga RC 0/5/10. `Net:` volume
  (procfs-clone): status/address/gateway/dns/arp readable, writable
  address/gateway/dns via Op_Write. Fuzz e2e: ping gateway RC 0, UDP
  hairpin crate, type Net:status.

Later milestones (sketch):

### M72 — TCP via vendored lwIP (locked 2026-08-26)

Decision: **vendored lwIP, not hand-rolled.** Rationale: the project
needs a C-library integration path anyway (freetype is the next
candidate), so M72 doubles as its vanguard. Verified
2026-08-26: `alr exec -- riscv64-elf-gcc` 15.3.0 compiles+links
newlib code; the only stubs the link needs are exactly what
Akernel_User.Gloss (m53b) already exports; runtime_build.gpr is the
`Languages ("Ada", "C")` precedent with `-Wno-error` per-file hatches.

**Vendor policy (user-locked): no vendored code in git.** `third_party/`
is gitignored (exception: `third_party/patches/` for tracked patches);
tarballs in `third_party/download/`, extracted tree in
`third_party/lwip/`. If the tree is missing at make time: download
(curl -L, sha256-pinned) → extract → apply patches → stamp. Committed
side: the Makefile rules, `userspace/lwip/lwip.gpr` (static library
project, Source_Dirs point into ../../third_party/lwip) and
`userspace/lwip/port/*`.

**Architecture: lwIP NO_SYS raw API replaces netserv's hand-rolled
ARP/IPv4/UDP/ICMP internals; every external protocol stays
byte-identical** (ring pairs, ops 20–25, badges, Net: files).
- Port: `lwipopts.h` (NO_SYS=1, MEM_LIBC_MALLOC=1 — lwIP allocs ride
  newlib malloc → gloss _sbrk arena; LWIP_IPV6=0 — lwIP is dual-stack
  capable, our ring ABI is u32-addressed, revisit far later), `cc.h`,
  minimal `sys_arch` (sys_now off Read_Time), `akernel_netif.c`
  (linkoutput → virtio TX ring; RX → ethernet_input; **frame-level
  hairpin**: dst MAC == ours → feed frame back into ethernet_input,
  one loopback mechanism for UDP/ICMP/TCP).
- UDP socket → udp_pcb; ping sockets + Op_Ping → raw ICMP pcb (ident
  = socket id); Net:arp renders the etharp table; Net:status counters
  from lwip_stats; Net: writes → netif_set_addr (live).
- Ticker thread (Thread_Create + 50 ms Sleep_Until loop) signals the
  main loop's bound ntfn bit 2 → sys_check_timeouts(). No kernel
  changes; no new syscalls.
- TCP (m72c): tcp_pcb per socket. Op_Connect on TCP = tcp_connect +
  bounded poll-drain until the callback (NO_SYS ⇒ callbacks run in
  Drain_Ring/tick context); Op_Listen=26, Op_Accept=27 non-blocking
  (Poll reports backlog; Accept takes a fresh ring-pair memobj, reply
  carries child id, client mints badge — m71c pattern). Streams over
  the existing slot rings (recv callback chunks pbuf chains into ≤996
  slots; TX drain → tcp_write/tcp_output; graceful Op_Close with
  bounded FIN drain). Sticky errors +4 refused, 5 timeout, 6 reset.
  Tuning to ring geometry: TCP_MSS=996, TCP_WND=3984,
  TCP_SND_BUF=3984. Net:tcp netstat listing.

Chunks (each independently shippable + green):
- **M72a — plumbing (done).** gitignore + Makefile fetch rules; lwip.gpr +
  port layer; netserv.gpr withs it, lwip_init() smoke at startup,
  stack not yet switched. Gate: full suite green.
- **M72b — engine swap (done).** All m71c tests pass byte-for-byte unchanged
  (udp_test, ping ×3, Net: files, fuzz e2e) — the regression net.
  Hand-rolled ARP/IPv4/UDP/ICMP deleted.
- **M72c — TCP (done).** Tests/Tcp_Test (manifest program 13, deterministic
  hairpin: listen/accept/connect, bidirectional echo, multi-KB
  transfer, refused, orderly close) + tools/tcp_echo.py host server
  on 127.0.0.1 started by make test (guest → 10.0.2.2 via slirp) +
  fuzz `type Net:tcp`. Gates: zero-warning clean build, SMP1+SMP4.

Out of scope: DHCP, IPv6, lwIP socket/netconn APIs, cc tuning.

**M72a landed (2026-08-26).** `.gitignore` ignores `third_party/*`
except `third_party/patches/`; Makefile `LWIP_*` rules download
lwIP 2.2.1 (GitHub mirror of the savannah tag; the savannah release
mirrors 404), sha256-verify, extract, patch and stamp on demand.
`userspace/lwip/lwip.gpr` builds the vendored subset as a static
C-only library (`-Wno-error`; port files in `userspace/lwip/port/`
get `-Werror`): lwipopts.h (NO_SYS, MEM_LIBC_MALLOC → gloss _sbrk
arena, TCP_MSS/WND 996/3984), arch/cc.h (newlib stdio diagnostics;
SSIZE_MAX shim so arch.h takes unistd.h's ssize_t), arch/perf.h,
sys_arch.c (sys_now = akernel_rdtime/10^4). netserv links it and
calls lwip_init at bring-up ("netserv lwip 2.2.1 init ok").

**Found while gating: the fs<->netserv bring-up deadlock (latent
since m71c, ~50% SMP4 wedge once lwip_init widened the window).**
netserv did its blocking ENV: fs reads during bring-up while init
had already mounted Net: at spawn — so an early `Net:address` open
(udp_test) made the fs block forwarding to netserv while netserv
blocked on the fs: circular wait, whole-system wedge (forensics:
QEMU monitor physical-memory walks of the kernel thread table and
endpoint queues; queued message payloads named every actor). Fix:
init no longer pushes the Net: mount; **netserv self-registers via
Op_Add_FS as its last bring-up step**, using a new `net_register`
manifest token (Send+Transfer mint of NETSRV_EP — its Receive-only
net_server handle cannot mint Send). While serving, netserv makes
no blocking fs calls, so no cycle can form. udp_test retries its
first Net:address open for 2 s (registration window). Verified:
6/6 SMP4 + 2/2 SMP1 green incl. clean rebuild.

Watchlist addition: **kernel endpoint-queue integrity.** The wedged
machine's fs endpoint had a caller-queue tail pointing at a
non-thread heap address, and Thread_Exit never dequeues a thread
from endpoint caller queues (Dequeue_Caller skips Is_Dead nodes,
but an out-of-table link would be followed into a wild write).
Root corruption path unidentified; likely "death while queued".
Forensics tooling notes: qemu monitor `xp` reads PHYSICAL memory
(gdbstub reads fail for kernel BSS); strip ANSI echoes and parse
only `addr:` data rows (keystroke echo transients inject spurious
tokens); TCB/endpoint offsets via `gdb -batch -ex "ptype /o"`;
kernel VA→PA: text/bss -0xffffffff80000000+0x80000000, heap objects
(endpoint slab) live at 0xffffffc080xxxxxx.

**M72b landed (2026-08-28).** netserv's engine is lwIP 2.2.1 raw
API (`userspace/lwip/port/aknet_glue.c`): netif output does not
consume the caller's pbuf, input paths always consume, udp recv cb
owns its pbuf, raw recv cb nonzero = callback freed it. Hand-rolled
ARP/IPv4/UDP/ICMP deleted; the m71c suite passes byte-unchanged.
Bug crop: pbuf_ref before ip4_input on the hairpin (double-free
spin); raw-ICMP recv cb must free when "eaten"; the "udp closed
port reports error" flake (client kick is now an IPC_Call, netserv
Handle_Ping is async with Ping_Reply_H/Ping_Limit + Reply_To).

**The line-769 wedge root cause: a double schedule in Block_Current.**
Every trap-level block path must schedule exactly once. The recv/
IRQ-wait paths Set_State + Schedule_Saved_Context (one Yield), but
Sleep_Until and Thread_Wait called Block_Current — which Yielded
itself — and their trap handlers then called Schedule_Saved_Context
— a second Yield. The first Yield popped the ready-queue head and
made it Current; the second immediately re-queued it (tail) and
popped someone else. The victim never ran and lost its FIFO slot,
so one head-of-queue thread starved per sleep. Latent forever and
harmless while sleeps were rare; the M72b netserv ticker (sleeps
every tick for lwIP timers) churned it into a deterministic SMP1
livelock: fuzz→fs→netserv→virtio_net all parked behind a driver
that was popped-and-requeued every tick without running. SMP4
masked it (sibling harts pick the victim). Fix: Block_Current no
longer yields; the trap-level caller schedules once. Plus a real
forensics catch kept: Mark_Exited now unlinks a dying thread from
any endpoint caller queue (stale link corrupted queues and could
cross-deliver IPC to the slot's next occupant).

Wedge forensics, for the next time: `info virtio-queue-status
/machine/peripheral-anon/device[6]/virtio-backend <n>` names queue
PAs; HMP `gdbserver tcp::1235` starts a stub on a running VM;
runtime-spawned thread ids start at 1024 (watch modular-aliasing
in id-keyed debug counters); READ KERNEL STATE ONLY UNDER HMP
`stop` — a running-VM `xp` samples mid-transaction queue/array
states and produced hours of self-contradictory "evidence";
never run a second QEMU against the same disk.img (a timed-out
background `make test` respawned one and silently shared it).
The instr8 "PT page == RX ring frame" observation never recurred
in later runs and remains unexplained — keep on the watchlist.
Gates: SMP1 1413P/0F, SMP4 1414P/0F, zero-warning build.

**M72c landed (2026-08-28).** TCP end to end on the raw API.
New ops Op_Listen=26/Op_Accept=27 (non-blocking; the accept
callback parks the child pcb in a free table slot unclaimed and
ringless; Op_Accept transfers a fresh ring pair + ntfn on the
LISTENER's cap like Op_Socket and replies the child id, the client
mints its badge — `Accept_Connection`, `accept` being reserved).
Connect is deferred (Reply_Stash + 5 s deadline, sticky errors
4 refused / 5 timeout / 6 reset); Conn_State goes Connecting
BEFORE tcp_connect because hairpin callbacks fire synchronously.
EOF = zero-length ring slot, flags bit 0; Recv_From reports it as
Status_Ok/Count=0. Backpressure rides lwIP's refused-data: the rx
callback accepts a chain whole-or-nothing (TCP_WND 3984 == ring
capacity 4×996, load-bearing) and returns ERR_MEM otherwise, lwIP
parks it in refused_data and retries on the fast timer; CLOSED
(p==NULL → our eof cb) is delivered only after refused data
drains, so the EOF marker lands behind every byte. Tx backpressure
ERR_MEM → sent-cb + 50 ms tick retry. Tests/Tcp_Test (manifest
13): Net:address, hairpin listen/connect/accept, echo both ways,
8 KiB pattern (i*7+3 mod 256) interleaved send/recv, refused
connect, orderly close EOF, then slirp echo to the host's
tools/tcp_echo.py (make test starts it, 127.0.0.1:10007); fuzz
`type Net:tcp` netstat listing. Bug crop, all lwIP contracts now
commented in the port:
- tcp_in.c keeps parse state in file-statics, so a reentrant
  tcp_input (SYN hairpinned from inside tcp_connect) corrupts the
  in-flight handshake — the hairpin now QUEUES packets and drains
  them from top-level contexts only (the Op_Kick branch preserves
  m71c's send-then-receive ping semantics), same reason lwIP's
  loopif queues.
- tcp_process_refused_data dereferences refused_data->flags with
  no null guard (unless LWIP_WND_SCALE): aknet_tcp_kick must
  null-check first (stval=0x15 fault; pbuf.flags sits at 0x15).
- lwIP's input path MUTATES the pbuf it is handed
  (pbuf_remove_header): the hairpin must queue a COPY, never a
  pbuf_ref — a shared pbuf let tcp_input rewrite a segment still
  parked in the sender's unacked queue, which underflowed
  TCP_TCPLEN into an unpurgeable unacked entry and a nagle
  deadlock (child never sent).
- RTS Recv_From wrapped the modular copy loop for zero-length
  slots (0-1 = U64'Last → CONSTRAINT_ERROR in the first-ever
  empty slot, the EOF marker itself; process died in the LCH).
- tcp_recv/sent/err/poll all LWIP_ASSERT on LISTEN pcbs and the
  default LWIP_PLATFORM_ASSERT aborts: aknet_tcp_close skips the
  callback clearing for listeners (netserv died on listener close
  and took every later network test with it).
Gates: SMP1 1453P/0F ×8, SMP4 1453P/0F ×3, zero-warning build.

**SMP1 suite-time regression root-caused (2026-08-28): 9m36 →
4m16, now level with SMP4's ~4 min.** Two stacked costs, both in
the UP wakeup path, neither in M72c proper (15e0f45 timed the same
9m47 as e8fc564):
- IRQ-wake latency behind the hog. Drivers block in Ntfn_Wait; the
  external-IRQ path woke them boosted at the queue head but
  RETURNED to the interrupted thread — on UP, Notify_Work's IPI
  no-ops with one hart, so the waiter sat behind Tests/Spin for
  the rest of the 50 ms quantum on every device round trip (the
  boost only took effect at the next tick). Fix: new
  Kernel.Scheduler.Should_Boost_Preempt (queued boosted thread at
  priority >= an unboosted running thread) checked at
  external-interrupt exit on UP only, Handle_Preemption if set.
  SMP4 keeps tick/IPI semantics. Worth ~90 s alone.
- Spin's fair 50/50 share. The 3cf6791 "hog only fills idle" era
  predates the M70 scripting suite; CPU-bound spawn/script phases
  now dominate, and fair sharing with the hog doubles them. Fix:
  Spin demotes itself to priority -1 when CPU_Count = 1 — every
  woken thread strictly outranks it (priority preemption already
  fires at syscall tail and now IRQ exit), so it fills true idle
  only; the canary is intact (still spins forever, still hangs
  the boot if timer preemption breaks). SMP keeps priority 0.
  Worth ~4 min.
Measured: SMP1 9m36s pre-fix, 8m10s kernel-only, 4m16s both;
SMP4 4m16s, 0 FAIL everywhere.

**M73 landed (2026-08-29).** GNAT.Sockets works end to end,
including from a secondary Jorvik task.
- Vendored 17 libgnat socket units into `gnat_user/`; g-socthi
  adapted, g-stseme.adb rewritten onto newlib `strerror`.
- `akernel_gsocket.c` ports gsocket.c's `__gnat_*` helpers onto
  `Akernel_User.Sockets` IPC. Notable port semantics: BSD auto-bind
  on connect/send for unbound sockets (accepted sockets inherit the
  listener's local address); `gethostbyaddr` resolves numerically
  (dotted name via inet_ntop) because GNAT maps
  `Get_Host_By_Name(dotted)` onto it; the C DNS helper binds an
  ephemeral port first (netserv requires Bound for UDP send).
- **Clock-domain trap:** syscall 34 (`read_clock`) is the WALL clock
  (RTC s/ns); sleep deadlines live in the 10 MHz `time` CSR domain.
  The port reads ticks via `akernel_rdtime` (U-mode `csrr time`).
  Mixing them silently produces ~50 s sleeps / immediate wakeups.
- **Per-thread IPC buffer:** secondary threads get their own IPC page
  (s-osinte `Next_IPC_VA`); the kernel reads the message from the
  *calling* thread's page, but `Akernel_User.Syscalls.Message` was
  fixed at the initial thread's VA — task IPC sent an empty page.
  Fix: new syscall 43 `Sys_Thread_IPC_VA`; `Syscalls.Message` is now
  an access-returning function (implicit dereference keeps every
  `Message.Label/...` call site) with a 0-fallback for the initial
  thread.
- Socket pools bumped: netserv Max_Socks 8→16 with VA stride
  1 MiB→64 KiB (fits before Buf_Win), RTS Max_Socks 4→8.
- New `Tests/Gsock_Test` (manifest program 14, `console fs net`):
  address read, numeric gethostbyname/getaddrinfo/gethostbyaddr, UDP
  round trip + auto-bind, selector expire/readable/abort, TCP
  listen/connect/accept/echo/EOF, and a deterministic DNS hairpin —
  a Jorvik task answers an A-record query for "test.akernel" through
  the netserv loopback path.
- `s-oscons.ads` gained the full newlib errno block.
Gates: SMP1 1471P/0F, SMP4 1471P/0F, zero-warning build.

- **M73 — GNAT.Sockets (done).** Vendor g-socket/g-socthi/g-soccon/g-stsifd
  from gcc-15.3.1 libgnat into gnat_user/, port gsocket.c's __gnat_*
  helpers as akernel_gsocket.c over Akernel_User.Sockets, extend
  hand-written s-oscons.ads with AF_INET/SOCK_*/SOL_*/MSG_* (AKERNEL
  values, no host ABI). getaddrinfo numeric-only + slirp DNS helper.

Deferred: DHCP, socket servers (finger etc.), DNS resolver beyond
slirp's built-in, external ICMP (slirp does not forward it — tests
target the gateway by design).

Watchlist: virtio_net_hdr legacy-vs-modern size; RX ring overflow =
drop-new with a counter in Net:status; fixed VA windows stay literals
with the overlap guard; ARP cache / socket table sized with headroom
in the same commit; devmgr Max_Lines 8 → 6 used. **IPC_Reply drops
caps** (Kernel.IPC.Reply zeroes them): libman's reply-cap path has
never delivered — Open_Library silently falls back to Open_Via_Self
(private copies, so the shared-library cache is untested). Fixing it
means Transfer_Message on the reply direction + auditing every reply
site in every server to clear Message.Caps. **SMP4 console loss:
occasionally one verdict line vanishes entirely (bytes lost, not
garbled — "fat rename ok", "PASS thread_test"), neighbors intact,
suite otherwise green; pre-existing writer race, not counted as a
failure.** **Whole-system stall flake: two SMP1 runs early in the
m72c gate stopped mid-fuzz (pipe reader spawn-wait; elevate spawn)
with 0 FAILs, then 8/8 SMP1 + 3/3 SMP4 clean on identical bits —
signature matches the still-open endpoint-queue-integrity watchlist
entry above (short-lived spawned peers = "death while queued"
candidates); reproducer+probe loop lives at
/tmp/opencode/m72c_repro.sh + m72c_probe1.py.**

## Open candidates

1. **Register fast path** — measure IPC call/recv cost, then decide
   whether a kernel-level register read/write primitive is worthwhile.
2. **ILBM image decoder** — add a `Trinket.Images.ILBM` decoder child.

## Working rules

- Fuzz tests must be idempotent across reused disk images; validate
  driver writes with host `fsck.fat`.
- Every buffer-cap transfer must be `cap_delete`d at every layer.
- A cap handed in a message must carry `Transfer`; minted copies are
  deleted after the transfer.
- Never rendezvous back to a caller while serving them; use async
  queue + notification instead.
- Fixed-size tables are already silently full — add headroom in the
  same commit that adds a consumer.
- Userspace VA windows are fixed literals with a static overlap guard,
  never derived from table sizes.
- `initrd/root/System/Manifest` is regenerated by the Makefile —
  edit the recipe, not the generated file.
- Programs spawned both from Startup and from the shell must see the
  same uniform ABI handles.

## Build / run

- `make all && make run` — interactive GUI.
- `make test` — suite (QEMU_SMP=4 default, also gated at SMP1).
- `make disk.img` — rebuild the GPT/FAT32 data partition.
