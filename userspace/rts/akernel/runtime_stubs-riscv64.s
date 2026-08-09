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
    /* Loud failure: print "LCH:<file>:<line>" through the debug
       putchar ecall (kernel UART, no console server), then yield
       forever. A silent spin here has wedged the suite twice
       (37b fuzz slice, 38b fat32 put16) with zero evidence. */
    mv s1, a0              /* source filename (NUL-terminated) */
    mv s2, a1              /* line */
    li a0, 10
    li a7, 1
    ecall
    li a0, 'L'
    li a7, 1
    ecall
    li a0, 'C'
    li a7, 1
    ecall
    li a0, 'H'
    li a7, 1
    ecall
    li a0, ':'
    li a7, 1
    ecall
    li t2, 24              /* filename, capped */
1:
    beqz t2, 2f
    lbu a0, 0(s1)
    beqz a0, 2f
    li a7, 1
    ecall
    addi s1, s1, 1
    addi t2, t2, -1
    j 1b
2:
    li a0, ':'
    li a7, 1
    ecall
    li t0, 10000           /* line as 5 decimal digits */
    li t3, 5
3:
    divu t1, s2, t0
    remu s2, s2, t0
    addi a0, t1, '0'
    li a7, 1
    ecall
    li t1, 10
    divu t0, t0, t1
    addi t3, t3, -1
    bnez t3, 3b
    li a0, 10
    li a7, 1
    ecall
4:
    li a7, 0               /* yield */
    ecall
    j 4b
.size __gnat_last_chance_handler, . - __gnat_last_chance_handler
