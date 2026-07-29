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

.global akernel_sys_boot_file_size
.type akernel_sys_boot_file_size, @function
akernel_sys_boot_file_size:
    li a7, 6
    ecall
    ret
.size akernel_sys_boot_file_size, . - akernel_sys_boot_file_size

.global akernel_sys_boot_read_byte
.type akernel_sys_boot_read_byte, @function
akernel_sys_boot_read_byte:
    li a7, 7
    ecall
    ret
.size akernel_sys_boot_read_byte, . - akernel_sys_boot_read_byte

.global akernel_sys_spawn_boot_path
.type akernel_sys_spawn_boot_path, @function
akernel_sys_spawn_boot_path:
    li a7, 8
    ecall
    sd a1, 0(a3)
    ret
.size akernel_sys_spawn_boot_path, . - akernel_sys_spawn_boot_path

.global akernel_sys_exit
.type akernel_sys_exit, @function
akernel_sys_exit:
    li a7, 9
    ecall
    ret
.size akernel_sys_exit, . - akernel_sys_exit

.global akernel_sys_reap_process
.type akernel_sys_reap_process, @function
akernel_sys_reap_process:
    li a7, 10
    ecall
    ret
.size akernel_sys_reap_process, . - akernel_sys_reap_process

.global akernel_sys_ep_create
.type akernel_sys_ep_create, @function
akernel_sys_ep_create:
    li a7, 11
    ecall
    ret
.size akernel_sys_ep_create, . - akernel_sys_ep_create

.global akernel_sys_debug_putchar
.type akernel_sys_debug_putchar, @function
akernel_sys_debug_putchar:
    li a7, 1
    ecall
    ret
.size akernel_sys_debug_putchar, . - akernel_sys_debug_putchar
