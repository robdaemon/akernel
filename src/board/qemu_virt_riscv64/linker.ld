OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x80200000, LENGTH = 126M
}

PHDRS
{
  text PT_LOAD FLAGS(5); /* R + X */
  data PT_LOAD FLAGS(6); /* R + W */
}

SECTIONS
{
  . = ORIGIN(RAM);
  __rx_start = .;

  .text : ALIGN(4)
  {
    KEEP(*(.text.boot))
    *(.text .text.*)
  } > RAM :text

  . = ALIGN(4096);
  trampoline_start = .;
  .trampoline : ALIGN(4096)
  {
    *(.trampoline .trampoline.*)
  } > RAM :text
  trampoline_end = .;

  .rodata : ALIGN(8)
  {
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
  } > RAM :text

  . = ALIGN(4096);
  __rx_end = .;

  .data : ALIGN(4096)
  {
    __DATA_BEGIN__ = .;
    *(.sdata .sdata.*)
    *(.data .data.*)
    . = ALIGN(8);
    __global_pointer$ = . + 0x800;
  } > RAM :data

  .bss (NOLOAD) : ALIGN(8)
  {
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(8);
    __BSS_END__ = .;
  } > RAM :data

  . = ALIGN(16);
  . += 64K;
  __stack_top = .;

  . = ALIGN(16);
  . += 64K;
  __trap_stack_top = .;

  _end = .;
}
