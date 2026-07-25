.section .text.user, "ax"

.global akernel_sys_yield
.type akernel_sys_yield, @function
akernel_sys_yield:
    li a7, 0
    ecall
    ret
.size akernel_sys_yield, . - akernel_sys_yield

.global akernel_sys_map_mmio
.type akernel_sys_map_mmio, @function
akernel_sys_map_mmio:
    li a7, 2
    ecall
    ret
.size akernel_sys_map_mmio, . - akernel_sys_map_mmio

.global akernel_sys_irq_wait
.type akernel_sys_irq_wait, @function
akernel_sys_irq_wait:
    li a7, 3
    ecall
    ret
.size akernel_sys_irq_wait, . - akernel_sys_irq_wait

.global akernel_sys_irq_ack
.type akernel_sys_irq_ack, @function
akernel_sys_irq_ack:
    li a7, 4
    ecall
    ret
.size akernel_sys_irq_ack, . - akernel_sys_irq_ack

.global akernel_sys_spawn_program
.type akernel_sys_spawn_program, @function
akernel_sys_spawn_program:
    li a7, 5
    ecall
    ret
.size akernel_sys_spawn_program, . - akernel_sys_spawn_program

.global akernel_sys_debug_putchar
.type akernel_sys_debug_putchar, @function
akernel_sys_debug_putchar:
    li a7, 1
    ecall
    ret
.size akernel_sys_debug_putchar, . - akernel_sys_debug_putchar
