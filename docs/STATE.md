# akernel project state

## Goal

Ada bare-metal microkernel for hobby OS. Initial target: RISC-V64 QEMU `virt` under OpenSBI in S-mode. Long-term: multiple architectures/boards, user-mode drivers, capability-based resource management, initrd-loaded userspace.

## Build/run

From repo root:

```sh
make all
make run
make clean
```

`make run` uses:

```sh
qemu-system-riscv64 \
  -machine virt \
  -smp 1 \
  -m 4G \
  -nographic \
  -kernel bin/akernel.elf \
  -device loader,file=initrd/out/akernel-initrd.img,addr=0x84000000
```

Override knobs:

```sh
make run QEMU_MEMORY=8G QEMU_SMP=4 INITRD_ADDR=0x84000000
```

## Current successful boot output

Important lines:

```text
Hello world!
memory manager online
ram MiB: 4096
cap table online
ipc online
scheduler online
entering initrd init
init online from Ada
boot manifest visible
launching serial driver
serial spawned
serial driver online
init resumed
timer interrupt online
```

## Repository layout

```text
src/kernel/                     kernel-neutral code
src/arch/riscv64/               RISC-V64 arch code
src/board/qemu_virt_riscv64/    QEMU virt board/platform code
userspace/rts/akernel/          current user-mode Ada syscall/RTS scaffold
userspace/init/                 standalone user init Alire project
userspace/serial/               standalone user serial driver Alire project
initrd/                         generated initrd root/output
tools/mkinitrd.py               wraps cpio in AKRD header
Makefile                        top-level build/run
```

## Architecture/board split

`akernel.gpr` uses variables:

```gpr
AKERNEL_ARCH  default riscv64
AKERNEL_BOARD default qemu_virt_riscv64
```

Source dirs:

```text
src/kernel
src/arch/<arch>
src/board/<board>
config
```

## Boot/startup

RISC-V64 startup:

```text
src/arch/riscv64/startup.s
```

OpenSBI enters kernel in S-mode:

```text
a0 = hart id
a1 = DTB physical address
```

Only first arriving HART runs. Others park in `wfi`.

Kernel links at:

```text
0x80200000
```

OpenSBI firmware is at/near `0x80000000`, so do not link kernel there.

Startup sets:
- `gp`
- boot stack
- `stvec`
- `sscratch` to trap stack
- clears `.bss`
- saves `boot_hart_id`, `boot_dtb_pa`
- builds early Sv39 identity map
- enables MMU
- calls Ada binder `main`

Early Sv39 root currently maps:

```text
root[0] low MMIO 0x00000000..0x3fffffff, supervisor RWX
root[1] temporary broad user alias 0x40000000..0x7fffffff -> PA 0x80000000..0xbfffffff, U/R/W/X
root[2..5] RAM 0x80000000..0x17fffffff, supervisor RWX, up to 4GiB RAM
```

User address spaces do **not** copy root[1]. They copy supervisor mappings only.

## Trap/syscall path

Trap vector:

```text
src/arch/riscv64/startup.s:trap_vector
```

Trap handler:

```text
src/arch/riscv64/arch-traps.adb
```

Trap entry uses `sscratch` to switch from user stack to kernel trap stack. It passes trap-frame pointer to Ada handler.

Syscall ABI:

```text
a7 = syscall number
a0..a4 = args
a0 = return/status
```

Current syscalls:

```text
0 yield
1 debug_putchar(a0 = char)
2 map_mmio(a0 = cap, a1 = va, a2 = offset, a3 = length, a4 = flags)
3 irq_wait(a0 = irq_cap)
4 irq_ack(a0 = irq_cap)
5 spawn_program(a0 = program_id, a1 = grant_mask) -> process/thread cap handle, 0 on failure
6 boot_file_size(a0 = file_id) -> byte length, U64'Last on failure
7 boot_read_byte(a0 = file_id, a1 = offset) -> byte 0..255, 256 EOF, U64'Last failure
```

Return convention for resource syscalls:

```text
0 = ok
1 = invalid/denied
2 = would block/no pending IRQ (older/nonblocking paths only)
```

`map_mmio` checks:
- current task exists
- cap valid
- cap kind `MMIO_Object`
- cap has `Map`
- requested R/W flags don't exceed cap rights
- offset/length within object
- page alignment
- VA in user range `0x40000000..0x80000000`

Then maps pages into current task address-space root as `User_RW`.

## Memory / MMU

Physical allocator:

```text
src/kernel/kernel-physical_memory.ads/.adb
```

Current allocator: simple bump frame allocator. Initialized from linker `_end` to RAM end from DTB.

Device tree parser:

```text
src/kernel/kernel-device_tree.ads/.adb
```

Generic FDT parser, not arch-specific. Board exposes only boot DTB pointer:

```text
src/board/qemu_virt_riscv64/board-device_tree.ads/.adb
```

MMU:

```text
src/arch/riscv64/arch-mmu.ads/.adb
```

Supports:
- `New_Address_Space`
- `New_User_Address_Space`
- `Map_Page`
- `Activate`

User stack top:

```text
0x70000000
```

User VA policy range currently:

```text
0x40000000..0x80000000
```

## Initrd

Separate initrd image loaded by QEMU loader device, not embedded in kernel ELF.

Fixed load PA for now:

```text
0x84000000
```

Image format:

```text
AKRD header:
  magic "AKRD"
  u32 version = 1
  u64 cpio_size
  u64 reserved
then cpio newc payload
```

Tool:

```text
tools/mkinitrd.py
```

Kernel parser:

```text
src/kernel/kernel-initrd.ads/.adb
```

Current initrd contents use Amiga-ish naming, not POSIX-ish:

```text
System/Init
System/Manifest
Drivers/Serial
```

`System/Manifest` current text format:

```text
program 1 Drivers/Serial uart_mmio uart_irq
```

Kernel boots `System/Init`. Init can now query boot files through syscalls. Current boot file id 1 is `System/Manifest`; init verifies it is visible. Init then calls `spawn_program(1, grant_mask)`. `Kernel.Processes` owns small spawned-task table and asks `Kernel.Program_Loader` for program id 1. Loader maps id 1 to boot program `Drivers/Serial` from initrd and returns image bytes. Process code loads it into its own user address space, applies caller-requested grants from `grant_mask` after checking parent owns matching resource caps, queues it in scheduler, and returns parent process/thread cap handle. Init remains alive and resumes after yielding. Initrd is hidden behind boot-file/program-loader abstractions; launch/resource policy is moving toward init.

## ELF loader

```text
src/kernel/kernel-elf.ads/.adb
```

Current real loader:

```ada
Load_Into_Address_Space
```

Behavior:
- validates ELF64 little-endian RISC-V
- iterates `PT_LOAD`
- allocates frames
- copies segment bytes
- zeroes bss/page slack
- maps pages into target root with user permissions from ELF flags
- returns entry point

There is also old `Load_User_Alias`; avoid using it except fallback/debug.

## Userspace

Standalone Alire projects:

```text
userspace/init/alire.toml
userspace/init/init.gpr
userspace/init/init.adb
userspace/serial/alire.toml
userspace/serial/serial.gpr
userspace/serial/serial.adb
```

Build to:

```text
bin/userspace/init.elf
bin/userspace/serial.elf
```

Userspace RTS/syscall scaffold:

```text
userspace/rts/akernel/
  akernel_user.ads
  akernel_user-syscalls.ads
  akernel_user-syscalls.adb
  syscalls-riscv64.s
  start-riscv64.s
  runtime_stubs-riscv64.s
  linker-riscv64.ld
```

User init currently launches serial driver:

```ada
Debug_Put_Line ("init online from Ada");
Boot_File_Size (Boot_Manifest_File);
prints "boot manifest visible" when readable
Debug_Put_Line ("launching serial driver");
Result := Spawn_Program
  (1, UART_MMIO_Grant_Bit or UART_IRQ_Grant_Bit);
prints "serial spawned" on nonzero process/thread cap handle
Yield;
prints "init resumed"
```

User serial driver currently:

```ada
Map_MMIO cap 1 at 0x50000000
print "serial driver online" via mapped UART MMIO
loop IRQ_Wait cap 2; drain UART RX; IRQ_Ack cap 2
```

RTS is not full custom GNAT RTS yet. It uses `light-rv64imafdc` plus syscall wrappers/stubs.

## Capabilities/tasks/IPC/scheduler

Capabilities:

```text
src/kernel/kernel-capabilities.ads/.adb
```

Flat per-task cap table, 256 entries. Handle 0 invalid.

Cap entry:
- valid
- kind
- object address
- rights
- badge

Rights:
- Read
- Write
- Execute
- Map
- Send
- Receive
- Wait
- Ack
- Transfer
- Manage

Tasks:

```text
src/kernel/kernel-tasks.ads/.adb
```

TCB currently has:
- id
- state
- address-space root
- saved user context snapshot
- cap table

Boot files:

```text
src/kernel/kernel-boot_files.ads/.adb
```

Current user-visible boot file API:
- file id 1 = `System/Manifest`
- `boot_file_size(file_id)` returns byte length or `U64'Last`
- `boot_read_byte(file_id, offset)` returns byte, 256 EOF, or `U64'Last`
- byte-at-a-time API avoids user pointer copying for now

Program loader:

```text
src/kernel/kernel-program_loader.ads/.adb
```

Current backend:
- reads `System/Manifest` from initrd
- current line format still allows: `program <id> <path> [grants...]`
- program id 1 maps to `Drivers/Serial`
- executable bytes come from initrd for now
- interface returns `Program_Manifest` with image `(Base, Size)`
- grant tokens are parsed into manifest but process creation now uses caller grant mask
- later backend can use VFS/package server without changing process creation path

Processes:

```text
src/kernel/kernel-processes.ads/.adb
```

`Kernel.Processes.Spawn_Program` currently:
- accepts program id and explicit grant mask from caller
- requests executable image from `Kernel.Program_Loader`
- creates address space + stack
- initializes TCB context
- grants caller-requested caps to child only if parent has matching resource caps
- queues child in scheduler
- inserts `Thread_Object` cap into parent and returns cap handle

Scheduler:

```text
src/kernel/kernel-scheduler.ads/.adb
```

Simple fixed ready queue and current task pointer. Yield path now saves/restores user trap-frame snapshots and switches `satp` for cooperative task switching. Still rough and fixed-path.

IPC:

```text
src/kernel/kernel-ipc.ads/.adb
```

Endpoint/message scaffold exists. One waiting sender/receiver, badges, caps reserved but no cap transfer yet.

## Resource objects

```text
src/kernel/kernel-objects.ads
src/kernel/kernel-interrupts.ads/.adb
```

Currently contains:

```ada
MMIO_Region:
  Physical_Base
  Length

IRQ_Line:
  Source
  Pending
  In_Flight
```

Kernel gives init cap handle 1 for UART MMIO:

```text
PA 0x10000000
Length 4096
Rights Map|Read|Write
```

Init maps it at VA:

```text
0x50000000
```

Kernel gives init cap handle 2 for UART IRQ:

```text
Source 10
Rights Wait|Ack
```

`Board.Interrupts.Handle_External_Interrupt` now claims PLIC source and calls `Kernel.Interrupts.Deliver`. If source is registered, kernel marks IRQ pending/in-flight and does not complete PLIC until user calls `irq_ack`. If source is unregistered, board code logs and completes it.

## UART/PLIC/timer

UART board driver:

```text
src/board/qemu_virt_riscv64/board-uart.ads/.adb
```

PLIC:

```text
src/board/qemu_virt_riscv64/board-plic.ads/.adb
src/board/qemu_virt_riscv64/board-interrupts.ads/.adb
```

Timer via SBI:

```text
src/arch/riscv64/arch-sbi.ads/.adb
src/arch/riscv64/sbi_asm.s
```

Timer interrupt works and prints first message/dots.

## Important constants

```text
kernel link/load:       0x80200000
initrd load PA:         0x84000000
user stack top:         0x70000000
user VA range:          0x40000000..0x80000000
UART PA:                0x10000000
PLIC PA:                0x0c000000
PLIC UART source:       10
QEMU virt RAM base:     0x80000000
```

## Temporary limitations / hacks

- PMM is bump-only, no free/reuse.
- Kernel supervisor mappings are broad identity mappings copied into user roots.
- No high-half kernel yet.
- Context switch works only as rough cooperative saved trap-frame switching.
- Small fixed spawned-task table only; no free/reuse.
- Initrd load address fixed at `0x84000000` via QEMU loader device.
- No DTB-based device capability enumeration yet.
- IRQ caps/syscalls exist but need hardening.
- No IPC syscalls yet.
- No cap transfer between processes yet.
- No IOMMU/DMA isolation.

## Recommended next steps

1. Move launch policy toward init/program-manager:
   - init can now read `System/Manifest`; next make it parse manifest and decide program ids/grants
   - kernel still parses `System/Manifest` in program loader; remove once init owns policy
   - kernel should expose bootinfo/resource caps to init
   - spawn should accept executable/source cap plus explicit grant/cap list, not global program id
   - keep initrd as one program-loader backend; later add VFS/package backend
   - distinguish process/thread/address-space objects instead of using `Thread_Object` placeholder
   - add user-visible error/status convention for failed spawn

2. Harden scheduler/context switching:
   - fix rough edges around IRQ-blocked tasks and idle path
   - add per-task kernel stacks/trap frames
   - avoid copying raw trap frames in arch-neutral task code

3. Improve blocking IRQ waits:
   - current `irq_wait` can block task and scheduler can switch, but model is young
   - `Kernel.Interrupts.Deliver` wakes IRQ waiter

3. Add IPC syscalls:
   - send/receive endpoint caps
   - use badges
   - later cap transfer

4. Add DTB-based device enumeration:
   - parse `virtio,mmio`, `ns16550a`, interrupt props
   - create resource objects/caps dynamically
   - pass bootinfo/resource caps to init

5. Improve VM isolation:
   - proper kernel virtual map instead of broad identity
   - per-task kernel stacks/trap frames
   - scheduler context switch switches `satp`
