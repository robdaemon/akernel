.section .text, "ax"

/*  memcpy/memset shims deleted in milestone 53b: newlib (-lc)
 *  provides them and libc.a is processed before this archive on
 *  the link line — duplicates. */

.global akernel_mmio_read8
.type akernel_mmio_read8, @function
akernel_mmio_read8:
    lbu a0, 0(a0)
    ret
.size akernel_mmio_read8, . - akernel_mmio_read8

.global akernel_mmio_write8
.type akernel_mmio_write8, @function
akernel_mmio_write8:
    sb a1, 0(a0)
    ret
.size akernel_mmio_write8, . - akernel_mmio_write8

.global putchar
.type putchar, @function
putchar:
    li a7, 1
    ecall
    ret
.size putchar, . - putchar
