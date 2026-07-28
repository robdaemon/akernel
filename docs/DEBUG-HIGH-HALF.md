# Debug state: high-half kernel VA bring-up (uncommitted WIP)

Goal: high-half kernel VAs (KERNEL_VIRT_BASE = 0xFFFFFFFF80000000,
KERNEL_DELTA = VIRT - 0x80200000, physmap at 0xFFFFFFC000000000 + PA).

Design details are in the conversation; `src/arch/riscv64/arch.ads`
has the constants. Early root (startup.s) is transitional: identity
RAM root[2..5] (satp-switch instrs only), physmap gigapages
root[0x100] (MMIO PA 0) and root[0x102..0x105] (RAM), kernel VMA
gigapage root[0x1FE] -> PA 0x80000000. Dedicated root built by
`Arch.MMU.Enter_Kernel_Address_Space`: kernel VMA RX/RW + physmap
gigapages, no identity. Trampoline page mapped at its kernel VMA in
user roots; user kstacks still mapped at PA in user roots; trampoline
asm converts frame pointers via PHYSMAP_BASE with unsigned-compare
heuristic (< PHYSMAP_BASE => PA frame).

## Current symptom

Boot prints:

```
Hello world!
dtb=0 pmm=2 mmu=1 base=0x0000000080000000 size=0x0000000100000000 first=0x0000000180542030
cap table online
ipc online
scheduler online
entering initrd init
<hangs: init never prints>
```

- base/size CORRECT (2 GiB / 4 GiB).
- pmm=2 = Invalid_Range: PMM.Initialize rejected range.
- `first` = 0x180542030 = First_Free passed to PMM. Expected
  0x80342030 (= _end VMA 0xffffffff80142030 - Kernel_Delta
  0xffffffff77e00000). 0x180542030 >= Limit 0x180000000 explains
  Invalid_Range. Everything downstream (Enter_Kernel_Address_Space
  skipped via gate, ELF skipped, garbage ELF_Result) follows from this.

## Evidence / contradiction

- Disasm of the PMM.Initialize call site in _ada_akernel:
  `auipc a0,0x142; addi -1580` -> a0 = 0xffffffff80142030 (_end VMA, correct)
  `lui a5,0x801; slli a5,0x9` -> a5 = 0x100200000 (= 2^64 - Kernel_Delta)
  `add a0,a0,a5` -> should wrap to 0x80342030 (correct).
- But runtime print of the SAME expression (Arch.Kernel_Virt_To_Phys
  of Kernel_End'Address) yields 0x180542030. Printed value equals
  disasm-computed value + 0x100200000 (i.e. negated Delta added twice?
  or auipc result different at runtime).

## Next steps

1. Bind to a single named variable and use it for both call and print:
   `First_Free : constant U64 := Arch.Kernel_Virt_To_Phys (U64
   (System.Storage_Elements.To_Integer (Kernel_End'Address)));`
   print it, pass it to Initialize. Removes dual-evaluation doubt.
2. If still wrong, inspect at runtime with gdb: breakpoint at
   `kernel__physical_memory__initialize` (symbol; VMA bp address from
   `nm bin/akernel.elf`, NOT stale disasm), print $a0/$a1.
3. Also verify _end value at runtime vs nm (print
   Kernel_End'Address directly via new Board.UART.Put_Hex).
4. Once First_Free right, expect: kernel address space online,
   memory manager online, pmm selftest online, full boot + UART IRQ
   keystroke test. Then remove debug prints, fix `use type` duplicate
   warnings (arch-mmu.adb, arch-traps.adb vs arch.ads clause), review
   arch-mmu.adb temporary Board.UART debug print in
   Enter_Kernel_Address_Space failure path (keep or drop), update
   docs (STATE.md/NEXT.md), commit.

## Tooling notes

- `alr build` does NOT notice linker script changes: run `make clean`
  after editing `src/board/qemu_virt_riscv64/linker.ld` (or rm
  bin/akernel.elf to force relink). Verified active: nm shows VMA
  0xffffffff80000000, LMA 0x80200000.
- riscv gdb via `alr exec -- gdb` (gdb 17). QEMU gdbstub:
  `qemu-system-riscv64 ... -s -S` then `target remote :1234`.
  Debug info IS present in ELF (.debug_* orphan sections).
  gdb batch quirks: `continue` errors "Cannot execute while target is
  running"; `set mi-async off` first line helps; breakpoint `commands`
  blocks with printf+continue also flaky. Hardware bp `hbreak` tried.
  Stale qemu processes hold :1234 - kill with
  `pkill -f "[q]emu-system-riscv64"` (bracket avoids self-match;
  plain `pkill -f qemu` kills own shell).
- Board.UART.Put_Hex(U64) now exists (spec+body) - use for debug.

## Uncommitted working tree (all part of this step)

- src/arch/riscv64/arch.ads (new constants/helpers)
- src/arch/riscv64/startup.s (high-half boot + trampoline physmap)
- src/arch/riscv64/sbi_asm.s (trap_frame_advance_sepc,
  trap_frame_for_stack, pure-copy context save/load)
- src/arch/riscv64/runtime_stubs.s (putchar physmap UART)
- src/arch/riscv64/arch-mmu.ads/.adb (Map_Gigapage, physmap
  To_Address, VMA trampoline map, new Enter_Kernel_Address_Space,
  TEMP Board.UART debug print in failure path)
- src/arch/riscv64/arch-traps.adb (frame sepc advance, restore into
  new kstack frame via Phys_To_Virt)
- src/arch/riscv64/arch-context.ads/.adb (34-word frame, PC idx 31,
  satp idx 32)
- src/arch/riscv64/arch-user_mode.ads/.adb (User_Satp param)
- src/board/qemu_virt_riscv64/linker.ld (high VMA + AT LMA)
- src/board/qemu_virt_riscv64/board-uart.adb/.ads (physmap base,
  Put_Hex)
- src/board/qemu_virt_riscv64/board-plic.adb (physmap base)
- src/board/qemu_virt_riscv64/board-device_tree.adb (DTB phys VA)
- src/kernel/akernel.adb (PMM init PA conv, smoke block removed,
  fallback removed, TEMP debug prints)
- src/kernel/kernel-physical_memory.adb (physmap link access)
- src/kernel/kernel-elf.adb (physmap dest writes)
- src/kernel/kernel-initrd.ads (physmap base)
- src/kernel/kernel-tasks.ads/.adb (Initialize_Context User_Satp)
- src/kernel/kernel-processes.adb (kstack mapped in child root,
  Satp_Value)
- deleted src/arch/riscv64/user_init.s
