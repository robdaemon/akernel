# Userspace

## Syscall ABI

`a7` = number, `a0..a4` args, `a0` (+`a1` for spawn) return.

```text
0  yield
1  debug_putchar(a0 = char)
2  map_mmio(a0 = as_cap, a1 = mmio_cap, a2 = va, a3 = offset, a4 = len, a5 = flags)
3  irq_wait(a0 = irq_cap)
4  irq_ack(a0 = irq_cap)
6  boot_file_size(a0 = file_id) -> len, U64'Last fail
7  boot_read_byte(a0 = file_id, a1 = offset) -> 0..255, 256 EOF, U64'Last fail
8  spawn_boot_path(a0 = path_off, a1 = path_len, a2 = grant_mask)
   -> a0 status (0 ok, 1 invalid, 2 no slot, 3 load fail, 4 cap fail,
      5 sched fail, 6 invalid parent), a1 = process cap on ok
9  exit() -> does not return
10 reap_process(a0 = process_cap) -> 0 ok, 1 invalid, 2 not exited
11 ep_create() -> endpoint cap handle, U64'Last fail
12 ipc_call(a0 = ep_cap) -> IPC result code; blocks until reply
13 ipc_recv(a0 = ep_cap) -> IPC result code; blocks until caller arrives
14 ipc_reply(a0 = 254) -> IPC result code; one-shot reply
```

IPC result codes: 0 ok, 1 invalid, 2 transfer failed, 3 endpoint gone,
4 reply gone. Messages are 96 bytes in the thread's IPC buffer page at
VA `0x6FFF0000`: label@0, 6 words@8, 4 cap handles@56 (0 = none),
badge@88 (recv only).

Return convention: 0 ok, 1 invalid/denied, 2 would-block (older
nonblocking paths only).

`map_mmio` checks: caller AS cap kind/rights/matches current root; MMIO
cap valid + Map right; R/W flags within cap rights; offset/len in object;
page alignment; VA in `0x40000000..0x80000000`; maps as `User_RW`.

Planned additions (docs/IPC.md): 11 ep_create, 12 call, 13 recv,
14 reply; spawn v2 by image cap + grant list.

## RTS scaffold

`userspace/rts/akernel/` — not a full custom GNAT RTS yet; uses
`light-rv64imafdc` plus syscall wrappers/stubs:

```text
akernel_user*.ads/.adb    syscall wrappers, MMIO helpers
syscalls-riscv64.s        ecall stubs (incl. generic stub for fuzzer)
start-riscv64.s           entry
runtime_stubs-riscv64.s   runtime stubs
linker-riscv64.ld         link script
```

Plan: real non-tasking runtime core first (exceptions, secondary stack,
heap, `Akernel.IPC` typed wrappers, streams over endpoints); tasking
runtime later (Ada rendezvous maps onto call/recv/reply). See docs/IPC.md.

## Programs

Standalone Alire projects building to `bin/userspace/*.elf`:

- `userspace/init/` — verifies manifest readable (fatal yield loop if
  not; not kernel panic), parses manifest, spawns each `program` line
  with grant mask, prints `serial spawned` for id 1, yields, resumes.
- `userspace/serial/` — maps UART MMIO (cap 1) at VA 0x50000000, prints
  `serial driver online`, loops `IRQ_Wait`/`IRQ_Ack` (cap 2) draining RX.
- `userspace/fuzz/` — syscall fuzzer (`Tests/Fuzz`, no grants): directed
  edge cases + 4096 deterministic pseudo-random syscalls. Found the
  `irq_wait` missing-`Advance_SEPC` livelock. Directed PASS incl.
  ep_create and non-blocking IPC validation; random phase skips the
  blocking IPC trio. End-to-end IPC fuzzing is a separate milestone.
- `userspace/spin/` — preemption canary (`Tests/Spin`, no grants): prints
  `spin online` then busy-loops forever; boot continuing afterwards
  proves timer preemption.

## Manifest

`System/Manifest` line format:

```text
program <id> <path> [grants...]
```

Current: `program 1 Drivers/Serial uart_mmio uart_irq` and a fuzzer
entry. Boot-launch mechanism for initrd contents only (Amiga-ish
startup-sequence role); not a general namespace mechanism — see
docs/IPC.md for namespace/session design.

Grant mask bits (userspace ABI): bit 0 = UART MMIO, bit 1 = UART IRQ.
Transitional until spawn v2 grant lists.
