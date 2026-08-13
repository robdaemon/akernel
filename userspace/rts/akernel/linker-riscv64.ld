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
    __text = .;
    KEEP(*(.text.start))
    *(.text.user .text.user.*)
    *(.text .text.*)
  } :text

  /*  ZCX unwinding (milestone 53a): crt0 registers .eh_frame with
      libgcc's __register_frame at startup (the bb .eh_frame_hdr
      binary search is out — bare-metal ld 2.46 has no
      --eh-frame-hdr); .eh_frame and .gcc_except_table must survive
      into the binary. */
  .eh_frame : ALIGN(8)
  {
    __EH_FRAME_BEGIN__ = .;
    KEEP(*(.eh_frame))
    /*  Zero initial-length word terminates the FDE chain walk
        (crtend supplies this on hosted targets; without it
        __register_frame_info_bases parses into .gcc_except_table
        and the count/fill mismatch overflows libgcc's malloc'd
        fde_array over the heap — the 53a corruption bug). */
    QUAD(0)
  } :text

  .gcc_except_table : ALIGN(8)
  {
    KEEP(*(.gcc_except_table .gcc_except_table.*))
  } :text

  .rodata : ALIGN(8)
  {
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
  } :text

  .data : ALIGN(4096)
  {
    __data = .;
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
