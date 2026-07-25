.section .text, "ax"

.global memcpy
.type memcpy, @function
memcpy:
    mv t0, a0
    beqz a2, 2f
1:
    lb t1, 0(a1)
    sb t1, 0(t0)
    addi t0, t0, 1
    addi a1, a1, 1
    addi a2, a2, -1
    bnez a2, 1b
2:
    ret
.size memcpy, . - memcpy

.global memset
.type memset, @function
memset:
    mv t0, a0
    beqz a2, 2f
1:
    sb a1, 0(t0)
    addi t0, t0, 1
    addi a2, a2, -1
    bnez a2, 1b
2:
    ret
.size memset, . - memset

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

.global __gnat_exit
.type __gnat_exit, @function
__gnat_exit:
1:
    li a7, 0               /* yield */
    ecall
    j 1b
.size __gnat_exit, . - __gnat_exit

.global __gnat_last_chance_handler
.type __gnat_last_chance_handler, @function
__gnat_last_chance_handler:
1:
    li a7, 0               /* yield */
    ecall
    j 1b
.size __gnat_last_chance_handler, . - __gnat_last_chance_handler
