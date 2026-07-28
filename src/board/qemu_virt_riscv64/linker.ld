OUTPUT_ARCH(riscv)
ENTRY(_start)

KERNEL_VIRT_BASE = 0xFFFFFFFF80200000;
KERNEL_PHYS_BASE = 0x80200000;
KERNEL_DELTA     = KERNEL_VIRT_BASE - KERNEL_PHYS_BASE;

SECTIONS
{
  . = KERNEL_VIRT_BASE;
  __rx_start = .;

  .text : AT(KERNEL_PHYS_BASE)
  {
    KEEP(*(.text.boot))
    *(.text .text.*)
  }

  . = ALIGN(4096);
  trampoline_start = .;
  .trampoline : AT(ADDR(.trampoline) - KERNEL_DELTA)
  {
    *(.trampoline .trampoline.*)
  }
  trampoline_end = .;

  .rodata : AT(ADDR(.rodata) - KERNEL_DELTA)
  {
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
  }

  . = ALIGN(4096);
  __rx_end = .;

  .data : AT(ADDR(.data) - KERNEL_DELTA)
  {
    __DATA_BEGIN__ = .;
    *(.sdata .sdata.*)
    *(.data .data.*)
    . = ALIGN(8);
    __global_pointer$ = . + 0x800;
  }

  .bss (NOLOAD) : AT(ADDR(.bss) - KERNEL_DELTA)
  {
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(8);
    __BSS_END__ = .;
  }

  . = ALIGN(16);
  . += 64K;
  __stack_top = .;

  . = ALIGN(16);
  . += 64K;
  __trap_stack_top = .;

  _end = .;
}
