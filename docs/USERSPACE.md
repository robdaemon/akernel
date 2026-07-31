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
```

IPC result codes: 0 ok, 1 invalid, 2 transfer failed, 3 endpoint gone,
4 reply gone. Messages are 96 bytes in the thread's IPC buffer page at
VA `0x6FFF0000`: label@0, 6 words@8, 4 cap handles@56 (0 = none),
badge@88 (recv only).

Init also gets a read-only bootinfo page at VA `0x6FFE0000`: magic
`AKINFO01`@0, entry count@8, then 64-byte entries (handle@0, kind@8,
rights mask@16, name length@24, name bytes@32, max 32 chars) listing
every kernel-granted cap by name (uart/mmio, uart/irq, one
Boot_File_Object per initrd file).

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
  not; not kernel panic), parses manifest, builds a grant list per
  `program` line (bootinfo names / ipc_test / console tokens),
  spawns, yields, resumes. Mints the badged ipc_test endpoint and
  the console endpoint (session-manager badge pattern).
- `userspace/serial/` — console server: maps UART MMIO (cap 1),
  holds Receive on the console endpoint (cap 2), serves stream
  protocol writes to the UART (read ops get EOF). Writes are
  line-atomic: per-client buffers keyed by the console cap badge
  (init badges each grant with the program id) flush on newline or
  a full 160-byte buffer; the kernel debug_putchar path buffers per
  thread (newline/full/exit flush). UART RX drained
  opportunistically on each write (single thread cannot wait on both
  IRQ and endpoint; IRQ-driven RX waits on notification objects).
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
  livelock. 74/74 directed PASS (incl. memory-object alloc/map/
  touch/unmap, RTS heap new/free/churn/growth, file-protocol
  stat/open/read/volume cases, and spawn-from-memory-object with
  reap against an fs-staged Tests/Memstage).
- `userspace/fileserver/` — file server (`System/Fileserver`,
  granted fs endpoint Receive at cap 1, console Send at 2, every
  boot-file cap from 3 via the `boot_files` token): serves the
  9P-ish file protocol (docs/IPC.md) — Stat/Open by name, stateless
  Read into the client-owned buffer memory object whose cap rides
  cap slot 0. Maps boot files as borrowed read-only pages (mem_map
  boot-file branch + lead-in offset); init pushes the handle->name
  table as Op_Set_Name messages after spawn.
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

Current: serial with `uart/mmio console_server`, a `volume RD0
Initrd ci` directive, fileserver with
`fs_server console boot_files`, fuzzer with
`ipc_test console Tests/Echo fs System/Manifest`, spin with
`console`, plus a
`# file Tests/Echo` comment line (skipped by init; keeps the path
resolvable for the fuzzer's spawn). Boot-launch mechanism for
initrd contents only (Amiga-ish startup-sequence role); not a
general namespace mechanism — see docs/IPC.md for namespace/session
design.

Grant tokens map to grant-list entries: a bootinfo entry name
grants that cap with the kernel-assigned rights; `ipc_test` grants
init's badged test endpoint (full rights, badge 0xEC40); `console`
grants Send on the console endpoint, `console_server` grants
Receive on it (Drivers/Serial only); `fs` grants Send on the
file-server endpoint, `fs_server` grants Receive on it
(System/Fileserver only); `boot_files` grants every boot-file cap
in bootinfo order (System/Fileserver only — init pushes the
matching name table over the fs endpoint after spawn).
