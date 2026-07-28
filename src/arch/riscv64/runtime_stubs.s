.section .text, "ax"

.global putchar
.type putchar, @function
putchar:
    li t0, 0xFFFFFFC010000000  /* UART0 through the physmap */
    sb a0, 0(t0)
    ret
.size putchar, . - putchar

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

.global mmio_read8
.type mmio_read8, @function
mmio_read8:
    lbu a0, 0(a0)
    ret
.size mmio_read8, . - mmio_read8

.global mmio_write8
.type mmio_write8, @function
mmio_write8:
    sb a1, 0(a0)
    ret
.size mmio_write8, . - mmio_write8

.global mmio_read32
.type mmio_read32, @function
mmio_read32:
    lwu a0, 0(a0)
    ret
.size mmio_read32, . - mmio_read32

.global mmio_write32
.type mmio_write32, @function
mmio_write32:
    sw a1, 0(a0)
    ret
.size mmio_write32, . - mmio_write32

.global __gnat_exit
.type __gnat_exit, @function
__gnat_exit:
1:
    wfi
    j 1b
.size __gnat_exit, . - __gnat_exit

.global __gnat_last_chance_handler
.type __gnat_last_chance_handler, @function
__gnat_last_chance_handler:
1:
    wfi
    j 1b
.size __gnat_last_chance_handler, . - __gnat_last_chance_handler
