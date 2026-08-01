# RISC-V64 arch details

Board: QEMU `virt` under OpenSBI, S-mode. Startup:
`src/arch/riscv64/startup.s`.

## Boot

OpenSBI enters kernel with `a0` = hart id, `a1` = DTB physical address.
Only first arriving HART runs; others park in `wfi`. Kernel links at
PA `0x80200000` (OpenSBI firmware sits at/near `0x80000000`).

Startup sets `gp`, boot stack, `stvec`, `sscratch` (trap stack), clears
`.bss`, saves `boot_hart_id`/`boot_dtb_pa`, builds early Sv39 identity
map, enables MMU, calls Ada binder `main`.

Early Sv39 root (boot transition only, abandoned after
`Arch.MMU.Enter_Kernel_Address_Space`):

```text
root[2..5]    RAM 0x80000000..0x17fffffff identity, supervisor RWX
root[0x100]   physmap PA 0 (MMIO) at PHYSMAP_BASE, supervisor RW
root[0x102..5] physmap RAM at PHYSMAP_BASE + PA, supervisor RW
root[0x1FE]   kernel VMA gigapage -> PA 0x80000000, supervisor RWX (temp)
```

## Kernel address space

Kernel linked at `Kernel_Virt_Base = 0xFFFFFFFF80200000` (VMA = PA +
`0xFFFFFFFF00000000`; offset is a whole gigapage so the kernel VMA
gigapage maps the image 1:1, and the base stays inside the medlow
top-2GiB window so the precompiled light runtime still links). All
physical memory is accessed through the physmap at `Physmap_Base =
0xFFFFFFC000000000` + PA (`Arch.Phys_To_Virt`).

After PMM init, `Arch.MMU.Enter_Kernel_Address_Space` builds a dedicated
address space, publishes its satp to `kernel_satp_slot`, switches satp.
No identity mappings; least-privilege W^X:

- kernel image `.text`+`.trampoline`+`.rodata` (`__rx_start`..`__rx_end`
  linker symbols): RX 4 KiB pages
- `.data`/`.bss`/stacks: RW 4 KiB pages
- physmap gigapages (MMIO PA 0 + all RAM): RW gigapage leaves
- no user alias gigapage; initrd init is mandatory (boot halts otherwise)

Kernel root frames are PMM-owned, never freed. `Arch.MMU.Kernel_Root`
reports dedicated root after switch, early root before.
`Arch.MMU.Map_Gigapage` exists for 1 GiB leaves.

## User address spaces

Map only: trap trampoline page (kernel VMA, supervisor RX, global), own
user pages, own threads' kernel trap stacks (physmap VA, supervisor RW,
global). No early-root gigapage copies. `New_User_Address_Space` also
maps narrow supervisor windows (UART page, PLIC priority/enable pages,
PLIC context pages 0..3) needed by the trap path.

`Arch.MMU.Destroy_User_Address_Space` walks Sv39 tables, skips global
supervisor leaves, frees non-global leaf frames and page tables, frees
root.

MMU API (`src/arch/riscv64/arch-mmu.ads/.adb`): `New_Address_Space`,
`New_User_Address_Space`, `Map_Page`, `Activate`, `Satp_Value`,
`Kernel_Root`, `Map_Gigapage`, `Destroy_User_Address_Space`.

## Trap/syscall path

Trap vector `startup.s:trap_vector` lives in the page-aligned
`.trampoline` linker section (one page, exports
`trampoline_start`/`trampoline_end`), mapped at its kernel VMA in every
user address space, xv6-style. `kernel_satp_slot` (kernel satp value)
lives in the trampoline page.

`sscratch` always holds current thread kernel stack top (physmap VA, or
kernel VMA for boot trap stack) in both S-mode and U-mode; frame
addresses valid in both roots, no pointer conversion around satp
switches.

Trampoline entry: switch `sp` to current thread kernel stack; build
272-byte frame (x1..x31, `sepc` @248 frame-authoritative, `satp` @256);
load `kernel_satp_slot`, switch satp to kernel root, call Ada handler
(`src/arch/riscv64/arch-traps.adb`).

Trampoline exit: locate frame via `sscratch` (scheduled-away trap
returns through newly current thread's own stack frame), install frame
satp slot, restore registers, `sret`. `sepc` advanced in frame
(`trap_frame_advance_sepc`), never in CSR. Scheduler restore writes
saved context into newly current thread's kernel stack frame
(`trap_frame_for_stack`) and updates `sscratch`; no `Arch.MMU.Activate`
on switch path. Kernel-mode traps take same path, no-op satp-wise.

`riscv_enter_user_mode` (trampoline page): takes entry, stack, target
root satp value; switches satp, `sret`s.

`Arch.Context` owns trap-frame layout and saved `sepc`;
`Kernel.Tasks` stores opaque `Arch.Context.Thread_Context` and calls
arch context save/restore wrappers. Frame gains satp word (PC index 31,
satp index 32); context save/load are pure 34-word frame copies.

## Syscall dispatcher invariant

Handlers that `Handle_Syscall` returns from immediately (currently
`irq_wait`, `exit`, `ipc_call`, `ipc_recv`) must `Advance_SEPC`
themselves on every non-scheduling exit path; all other handlers fall
through to the dispatcher single advance. Violating this re-executes
the `ecall` forever (found by fuzzer, `irq_wait` invalid-cap case).

Trap syscall handlers validate user-supplied cap-handle integers before
converting to `Kernel.Capabilities.Handle`; out-of-range handles return
invalid/denied instead of raising constraint errors.

## Devices

- UART: `src/board/qemu_virt_riscv64/board-uart.ads/.adb`, PA 0x10000000.
- PLIC: `board-plic.*`, `board-interrupts.*`, PA 0x0c000000, UART source 10.
- Timer via SBI: `src/arch/riscv64/arch-sbi.*`, `sbi_asm.s`. 100 ms
  tick; U-mode ticks preempt the running user thread
  (`Handle_Preemption` in arch-traps: save frame, reschedule via the
  blocking-syscall machinery). S-mode ticks (idle/kernel) only re-arm.
- Device tree: generic FDT parser `kernel-device_tree.*`; board exposes
  boot DTB pointer (`board-device_tree.*`). PMM init uses DTB RAM end.
  `Find_Device` enumerates devices by compatible string (string-list
  match, parent #address-cells/#size-cells stack, reg + first
  interrupts cell): UART (`ns16550a`) and PLIC (`riscv,plic0`) bases
  and the UART IRQ source come from the DTB, with
  `board-memory_map.*`/`board-plic.*` constants as fallback defaults
  ("dtb devices online" vs "dtb devices incomplete; board defaults"
  in the boot log). Gotcha: FDT property order inside a node is
  arbitrary (qemu emits reg before compatible) — capture per-node and
  decide at node close; and #size-cells = 0 is legal (modular U32
  0 .. Cells-1 wraps, walking off RAM).
