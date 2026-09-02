# M83 Plan — IPC/stack geometry

Status: PLANNED (not started). Decisions taken with the user on 2026-09-02.
Delete this file when the M83 entry lands in RESUME.md.

## Goal

Relocate the user main stack to the top of the user VA window and grow it
from 12 pages (48 KiB) to 64 pages (256 KiB). The IPC buffer page stays at
`0x6FFF_0000` (see Decisions). Reserve `0x7000_0000..0x7FF0_0000` for the
M80d helper arena (docs/LIMIT_FIXES.md:152-155).

```
0x7FF0_0000 .. 0x8000_0000   main stack, 64 pages, top = 0x8000_0000
0x6FFF_0000                  IPC buffer page (unchanged)
0x7000_0000 .. 0x7FF0_0000   free (reserved: M80d helper arena)
```

## Why

Spawned processes get a 12-page (48 KiB) stack descending from
`0x7000_0000`; the IPC buffer page at `0x6FFF_0000` leaves only 3 spare
pages below, so 15 pages is the hard ceiling (comment at
src/kernel/kernel-processes.adb:151-153). M82g hit a real overflow (store
fault at 0x6FFF3FF0 in the ZCX unwinder); M82h had to move big engine
records to package state as a workaround. The 256 MiB hole at
`0x7000_0000..0x8000_0000` is free everywhere (census:
docs/LIMIT_FIXES.md:82).

## Research findings (verified)

- sp comes from the kernel trap frame — NO linker-script or startup-asm
  changes. Stack constants are kernel-only:
  - src/kernel/kernel-processes.adb:141 `Stack_Top = 16#7000_0000#`,
    :154 `Stack_Pages = 12`, spawn loop at :421-443, entry sp at :565.
  - src/kernel/akernel.adb:89 `User_Stack_Top` (DUPLICATE constant) and
    init stack loop `for I in 2 .. 4` at :648 — init has only 4 pages.
- IPC buffer: `Kernel.Tasks.IPC_Buffer_VA = 16#6FFF_0000#`
  (src/kernel/kernel-tasks.ads:43). User mirrors:
  userspace/rts/akernel/akernel_user-syscalls.ads:357 and
  userspace/gnat-rts/gnarl_user/s-osinte.adb:94 (`Initial_IPC_VA`).
  Discovery syscall 43 exists (m73); `Message` accessor falls back to the
  fixed constant when the kernel answers 0 — init never gets
  Set_IPC_Buffer_VA, so the fallback is load-bearing for init.
- Two RTS call sites still use the fixed constant instead of syscall 43:
  `Thread_Create_Write_Params` (akernel_user-syscalls.adb:511) and
  `Set_Grant` (:631).
- The ELF loader has NO VA bounds check (src/kernel/kernel-elf.adb:229-345)
  — a crafted ELF could map over the relocated stack.
- fuzz.adb:3342-3343 asserts a blocked thread's sp is in
  [0x6FFF_8000, 0x7000_0000) — must follow the new range. Comment-only
  references to refresh: fuzz.adb:587,1323, scripting-interp.adb:138,
  netserv_engine.adb:196, thread_test.adb:19, trinket-window.adb:17.
- Secondary (tasking) threads are unaffected: userspace-allocated stacks
  at runtime-chosen VAs (s-osinte.adb:257-315); their per-thread IPC pages
  descend from 0x6FFE_0000 (s-osinte.adb:206,346), AWAY from 0x6FFF_0000.
- User page faults are FATAL (arch-traps.adb Dispatch_Trap halts the
  machine) — no demand paging, no guard page; stacks are eager PMM frames.
- RAM is not a constraint: QEMU_MEMORY = 4G; 64 pages x ~30 processes is
  ~8 MiB eager.
- mem_map/Thread_Create enforce user VAs in [0x4000_0000, 0x8000_0000)
  (arch-traps.adb:1584-1592, kernel-processes.adb:1002-1014).

## Implementation steps

1. **Kernel constants**: hoist `Stack_Top`/`Stack_Pages` into
   kernel-processes.ads (kills the akernel.adb duplication); set top to
   `16#8000_0000#`, pages to 64. Init (akernel.adb) uses the shared
   constants — its stack grows 4 -> 64 pages too. Update the collision
   comment (the 0x6FFF_0000 ceiling no longer applies).
2. **ELF loader guard** (kernel-elf.adb): reject PT_LOAD segments outside
   [0x4000_0000, 0x8000_0000) or intersecting [stack_base, 0x8000_0000).
3. **RTS hardening**: Thread_Create_Write_Params and Set_Grant use the
   syscall-43 discovered VA (the `Message` accessor pattern) instead of
   the fixed constant. The constant itself stays — init's fallback needs
   it.
4. **Userspace fallout**: update the fuzz sp-range check (fuzz.adb:3342)
   to [0x7FF0_0000, 0x8000_0000); refresh the comment-only references
   listed above.
5. **Acceptance test** (fuzz.adb, own procedure per M82g/h frame
   discipline): deep recursion consuming ~150 KiB of stack (e.g. 1 KiB
   frame x depth 150, result accumulated into a volatile/printed value so
   the compiler cannot elide it). Fatal before this change; must PASS.
6. **Verify**: `make test` then `make test-replay` (each ~6.5-7 min now —
   capture to /tmp/opencode/*.log, don't treat long runs as wedges;
   rm -f /tmp/qmon.sock /tmp/qqmp.sock before manual QEMU runs).
7. **Docs + commit**: docs/STATE.md:118 (user stack top), docs/IPC.md:43
   ("just below user stack top" becomes false), RESUME.md entry (blurb
   below); delete this plan file; commit as M83.

## Out of scope

- IPC buffer relocation (see Decisions).
- Demand paging / guard pages — user faults stay fatal (separate
  milestone if ever wanted).
- Secondary-thread stack sizing (s-osinte) — independent mechanism.

## Decisions (user, 2026-09-02)

- **Stack size 256 KiB (64 pages)** — 5x headroom over the 48 KiB that
  nearly sufficed; 512 KiB was the alternative.
- **IPC buffer NOT relocated.** No functional disadvantage: the growth
  ceiling disappears with the stack move alone; neighbors are cooperative
  (bootinfo grows up from 0x6FFE_0000 max 8 pages, secondary IPC pages
  descend from 0x6FFE_0000, away from it); discovery via syscall 43
  already works. The only wart — two RTS spots on the fixed constant — is
  fixed by step 3 without moving anything.

## RESUME.md blurb (for the M83 commit)

```
- **M83 done** (this commit): IPC/stack geometry. The user main stack
  moves from 0x7000_0000 to the top of the user window
  (Stack_Top = 0x8000_0000) and grows 12 -> 64 pages (48 -> 256 KiB) —
  the IPC buffer page at 0x6FFF_0000 capped the old layout at 15 pages
  and M82g actually overflowed it (0x6FFF3FF0). Stack_Top/Stack_Pages
  live in kernel-processes.ads now; init (previously 4 pages with a
  duplicated constant in akernel.adb) shares them. The IPC buffer page
  is NOT relocated — the stack move alone removes the ceiling — but the
  last two fixed-constant userspace references
  (Thread_Create_Write_Params, Set_Grant) now discover the VA through
  syscall 43 like everything else. The ELF loader rejects segments
  outside [0x4000_0000, 0x8000_0000) or overlapping the stack (it had
  no VA bounds check at all). 0x7000_0000..0x7FF0_0000 stays free,
  reserved for M80d's helper arena. fuzz: blocked-thread sp range
  follows the new layout; new deep-recursion check (~150 KiB — fatal
  before this change). NNNN PASS / 0 FAIL; test-replay green.
```
