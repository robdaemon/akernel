OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5); /* R + X */
  data PT_LOAD FLAGS(6); /* R + W */
}

/*  Milestone 53b: newlib as a rescan GROUP. gprbuild drops
 *  Linker'Linker_Options silently and Switches land before the
 *  runtime libs, but ld is single-pass while libgnat/libgcc
 *  introduce malloc/strcmp/strlen references AFTER any early -lc.
 *  A GROUP is searched repeatedly as new undefined references
 *  appear, wherever later objects introduce them. */
GROUP(-lc -lm)

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
    /*  newlib (milestone 53b): __libc_init_array walks these. */
    . = ALIGN(8);
    __preinit_array_start = .;
    KEEP(*(.preinit_array*))
    __preinit_array_end = .;
    __init_array_start = .;
    KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
    KEEP(*(.init_array))
    __init_array_end = .;
    __fini_array_start = .;
    KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*)))
    KEEP(*(.fini_array))
    __fini_array_end = .;
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

  /*  Thread-local storage template: initialized (.tdata) and
   *  zero (.tbss) sections are laid out contiguously.  The
   *  .tls_copy region reserves a per-initial-thread private copy
   *  of the TLS block; crt0 copies .tdata into it and zeros .tbss.
   *  Secondary threads receive a TLS base from Thread_Create and
   *  use the same template copy at startup. */
  .tdata : ALIGN(8)
  {
    __tls_init_start = .;
    *(.tdata .tdata.*)
    __tls_init_end = .;
  } :data

  .tbss (NOLOAD) : ALIGN(8)
  {
    __tls_bss_start = .;
    *(.tbss .tbss.*)
    __tls_bss_end = .;
  } :data

  .tls_copy (NOLOAD) : ALIGN(8)
  {
    __tls_start = .;
    . += (__tls_init_end - __tls_init_start)
       + (__tls_bss_end - __tls_bss_start);
    . = ALIGN(8);
    __tls_end = .;
  } :data

  _end = .;
}
