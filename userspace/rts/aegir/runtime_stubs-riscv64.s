.section .text, "ax"

/*  memcpy/memset shims deleted in milestone 53b: newlib (-lc)
 *  provides them and libc.a is processed before this archive on
 *  the link line — duplicates. */

.global aegir_mmio_read8
.type aegir_mmio_read8, @function
aegir_mmio_read8:
    lbu a0, 0(a0)
    ret
.size aegir_mmio_read8, . - aegir_mmio_read8

.global aegir_mmio_write8
.type aegir_mmio_write8, @function
aegir_mmio_write8:
    sb a1, 0(a0)
    ret
.size aegir_mmio_write8, . - aegir_mmio_write8

.global putchar
.type putchar, @function
putchar:
    li a7, 1
    ecall
    ret
.size putchar, . - putchar

.section .note.GNU-stack, "", @progbits
