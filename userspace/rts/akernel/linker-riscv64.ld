OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5); /* R + X */
  data PT_LOAD FLAGS(6); /* R + W */
}

SECTIONS
{
  . = 0x46000000;

  .text : ALIGN(4)
  {
    KEEP(*(.text.start))
    *(.text.user .text.user.*)
    *(.text .text.*)
  } :text

  .rodata : ALIGN(8)
  {
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
  } :text

  .data : ALIGN(4096)
  {
    __DATA_BEGIN__ = .;
    *(.sdata .sdata.*)
    *(.data .data.*)
    . = ALIGN(8);
    __global_pointer$ = . + 0x800;
  } :data

  .bss (NOLOAD) : ALIGN(8)
  {
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(8);
    __BSS_END__ = .;
  } :data

  _end = .;
}
