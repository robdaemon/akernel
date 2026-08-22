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
- [x] Provide an automated way to verify `Tests/Thread_Test` (done:
  `make test` runs `thread_test_check`).
- [ ] Add `Tests/Thread_Test` to the auto-spawn manifest and make the
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
- `userspace/thread_test/` is built and installed in the initrd.
- `make test` with the default `QEMU_SMP=4` now passes end-to-end
  and automatically verifies threads via a new `thread_test_check`
  target that runs `Tests/Thread_Test` in a minimal isolated
  manifest.
- Adding `Tests/Thread_Test` directly to the `INITRD_MODE=test`
  manifest still hangs the full suite: after `PASS thread_test`,
  `partmgr` and `fat32` start but block on their first console
  write, which means the console server stopped processing new
  callers once the secondary thread entered the system.  The root
  cause is still unknown; the isolated check avoids it while still
  exercising the thread primitives in CI.

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

Remaining work:

- Root-cause why adding `Tests/Thread_Test` to the full test
  manifest stops the console server from serving `partmgr`/`fat32`
  startup prints.  Likely a secondary-thread lifecycle side effect
  or scheduling/IPC race exposed by the extra concurrent thread.

## Open candidates

Pick one after M66:

1. **Proc:self / client identity through the VFS** — let a filesystem
   server know which process is calling (badge or process id on every
   request) so `Proc:` self-references and per-process views work.
2. **Register fast path** — measure IPC call/recv cost, then decide
   whether a kernel-level register read/write primitive is worthwhile.
3. **virtio-net driver + socket-like protocol** — network stack
   starting with a raw virtio-net device and a simple packet channel.
4. **MSI-X support** — move virtio PCI devices off shared INTx onto
   per-vector MSI-X.
5. **Script interpreter** — a small AmigaDOS/ARexx-style shell script
   engine.
6. **Background pipelines** — extend shell `run` to chains with `|`
   and `PIPE:`.
7. **ILBM image decoder** — add a `Trinket.Images.ILBM` decoder child.

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
