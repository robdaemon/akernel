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

**Milestone 70 — AmigaDOS-style script interpreter (planned,
chunked; work starts after this entry).**

Decisions taken: AmigaDOS subset (if/else/endif, lab/skip, quit,
failat, echo, `<var>` substitution, `.key` args, `.set` locals);
shared interpreter package used by BOTH the shell's `execute`
builtin and a new `Sys:C/Execute` binary; script-local variables
with ENV: fallback; `ask` included. Locals resolve before ENV:;
`<$name>` forces ENV:. Undefined `<name>` is a hard error (RC 10,
aborts the script). Substitution only fires on `<name>` with no
space after `<` — pipeline operators are standalone tokens, so
`< file` redirection is untouched. `set`/`get`/`unset` externals
keep their ENV: semantics (existing fuzz scripts depend on it).

`.set` directive: `.set <name> <value...>` sets a script local
(substitution applied first — `.set b <a>` copies; value trimmed,
<= 128 chars); `.set <name>` with no value clears it to empty
(distinct from undefined, which errors). Interpreter directive:
always RC 0, never trips failat, not executed inside skipped
blocks. Locals also come from `.key`/`.k` positional args and
`.def name=value` defaults (16 slots, names <= 32).

Chunk plan (each chunk = one commit, full gates:
zero-warning `make all`, `make test` SMP4 + `QEMU_SMP=1`
timeout-wrapped with log verification, desktop boot smoke):

- [x] **Chunk 1 — `Scripting.Exec` extraction (pure refactor).**
  New crate `userspace/scripting/`; move Stage/Spawn_Cmd/Reap/Exec,
  Has_Metachar, Spawn_Pipeline/Reap_Pipeline/Delete_Pipes/
  Run_Pipeline, Proc_Set/Pipe_Set/Pipe_Name_Str, Stage_VA,
  Max_Stages out of shell.adb. Shell `with`s it; job control keeps
  the shared types. No behavior change; suite proves parity.
- [x] **Chunk 2 — `Scripting.Interp` core: parity + substitution
  + locals.** Slurp/line-scan/comments/failat-stop/nesting-cap
  parity with old Run_Script; `execute` splits path from args;
  `.key`/`.k`/`.def`/`.set`; `<name>`/`<$name>` substitution with
  bad-substitution abort. Shell's `execute` switches to
  `Interp.Run` (Run callback = shell `Execute`, so builtins work
  in scripts). Fuzz: args+substitution byte-verified, ENV:
  fallback, `<$>`, `.set` set/copy/clear, bad-subst abort; old
  script tests pass unchanged.
- [ ] **Chunk 3 — Control flow.** `if [not] <cmd>` (RC consumed,
  true iff RC < failat), `if [not] <a> eq|ne|gt|ge|lt|le <b>`
  (case-insensitive; `val` = numeric), `if [not] exists <path>`,
  `else`, `endif` (8-deep stack; skip mode tracks nesting),
  `lab`/`skip [back]`, `quit [rc]`, `failat <n>`,
  `echo [noline]`. Fuzz: taken/not-taken markers, nested if/else,
  if-command doesn't abort on RC, skip forward, skip-back loop
  bounded by if-exists chain, `quit 7`, inner `quit 20` trips the
  outer failat, `failat 21` lets RC 20 pass (Elevate NoSuch
  trick).
- [ ] **Chunk 4 — C:Execute + ask.** Shared `Read_Line` console
  helper (Op_Read poll + yield, bounded 120). `ask <prompt>` sets
  the condition flag (y/Y), RC 0/5 (5 < failat: no abort); bare
  `if`/`if not` tests the flag. New `userspace/execute/` crate ->
  `Sys:C/Execute` (thin: args -> Interp.Run with Scripting.Exec
  dispatch + nested `execute` special-case); Makefile
  INITRD_CRATES/manifest. Fuzz: `echo y | Sys:C/Execute
  askscript` -> "yes" marker (and `n` -> "no"), `run C:Execute
  script` + `wait` RC composition, depth-cap abort. If ask-over-
  pipe fights us: ask ships interactive-only (boot smoke) and the
  piped test becomes a follow-up.
- [ ] **Chunk 5 — Docs + sweep.** `help` text, shell.adb header
  comment, `docs/USERSPACE.md`, this RESUME entry finalized,
  remove "Script interpreter" from Open candidates, any test gaps
  found in chunks 2-4.

## Open candidates

1. **Register fast path** — measure IPC call/recv cost, then decide
   whether a kernel-level register read/write primitive is worthwhile.
2. **virtio-net driver + socket-like protocol** — network stack
   starting with a raw virtio-net device and a simple packet channel.
3. **Script interpreter** — a small AmigaDOS/ARexx-style shell script
   engine.
4. **ILBM image decoder** — add a `Trinket.Images.ILBM` decoder child.

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
