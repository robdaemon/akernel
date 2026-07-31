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

.global akernel_sys_spawn
.type akernel_sys_spawn, @function
akernel_sys_spawn:
    li a7, 8
    ecall
    sd a1, 0(a2)
    ret
.size akernel_sys_spawn, . - akernel_sys_spawn

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

.global akernel_sys_ipc_call
.type akernel_sys_ipc_call, @function
akernel_sys_ipc_call:
    li a7, 12
    ecall
    ret
.size akernel_sys_ipc_call, . - akernel_sys_ipc_call

.global akernel_sys_ipc_recv
.type akernel_sys_ipc_recv, @function
akernel_sys_ipc_recv:
    li a7, 13
    ecall
    ret
.size akernel_sys_ipc_recv, . - akernel_sys_ipc_recv

.global akernel_sys_ipc_reply
.type akernel_sys_ipc_reply, @function
akernel_sys_ipc_reply:
    li a7, 14
    ecall
    ret
.size akernel_sys_ipc_reply, . - akernel_sys_ipc_reply

.global akernel_sys_mem_alloc
.type akernel_sys_mem_alloc, @function
akernel_sys_mem_alloc:
    li a7, 15
    ecall
    ret
.size akernel_sys_mem_alloc, . - akernel_sys_mem_alloc

.global akernel_sys_mem_map
.type akernel_sys_mem_map, @function
akernel_sys_mem_map:
    li a7, 16
    ecall
    ret
.size akernel_sys_mem_map, . - akernel_sys_mem_map

.global akernel_sys_mem_unmap
.type akernel_sys_mem_unmap, @function
akernel_sys_mem_unmap:
    li a7, 17
    ecall
    ret
.size akernel_sys_mem_unmap, . - akernel_sys_mem_unmap

.global akernel_sys_debug_putchar
.type akernel_sys_debug_putchar, @function
akernel_sys_debug_putchar:
    li a7, 1
    ecall
    ret
.size akernel_sys_debug_putchar, . - akernel_sys_debug_putchar
