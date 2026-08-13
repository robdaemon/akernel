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

.global akernel_sys_reap_process_code
.type akernel_sys_reap_process_code, @function
# a0 = process cap, a1 = code out pointer; reap returns the
# child's exit code in a1, clobbering the pointer — save it first.
akernel_sys_reap_process_code:
    mv t0, a1
    li a7, 10
    ecall
    sd a1, 0(t0)
    ret
.size akernel_sys_reap_process_code, . - akernel_sys_reap_process_code

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
    mv t0, a1
    li a7, 13
    ecall
    sd a1, 0(t0)
    ret
.size akernel_sys_ipc_recv, . - akernel_sys_ipc_recv

.global akernel_sys_ipc_send
.type akernel_sys_ipc_send, @function
akernel_sys_ipc_send:
    li a7, 29
    ecall
    ret
.size akernel_sys_ipc_send, . - akernel_sys_ipc_send

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

.global akernel_sys_ntfn_create
.type akernel_sys_ntfn_create, @function
akernel_sys_ntfn_create:
    li a7, 18
    ecall
    ret
.size akernel_sys_ntfn_create, . - akernel_sys_ntfn_create

.global akernel_sys_ntfn_wait
.type akernel_sys_ntfn_wait, @function
akernel_sys_ntfn_wait:
    li a7, 19
    ecall
    ret
.size akernel_sys_ntfn_wait, . - akernel_sys_ntfn_wait

.global akernel_sys_ntfn_signal
.type akernel_sys_ntfn_signal, @function
akernel_sys_ntfn_signal:
    li a7, 20
    ecall
    ret
.size akernel_sys_ntfn_signal, . - akernel_sys_ntfn_signal

.global akernel_sys_ntfn_bind_thread
.type akernel_sys_ntfn_bind_thread, @function
akernel_sys_ntfn_bind_thread:
    li a7, 21
    ecall
    ret
.size akernel_sys_ntfn_bind_thread, . - akernel_sys_ntfn_bind_thread

.global akernel_sys_irq_bind_ntfn
.type akernel_sys_irq_bind_ntfn, @function
akernel_sys_irq_bind_ntfn:
    li a7, 22
    ecall
    ret
.size akernel_sys_irq_bind_ntfn, . - akernel_sys_irq_bind_ntfn

.global akernel_sys_io_map
.type akernel_sys_io_map, @function
akernel_sys_io_map:
    li a7, 23
    ecall
    ret
.size akernel_sys_io_map, . - akernel_sys_io_map

.global akernel_sys_irq_create
.type akernel_sys_irq_create, @function
akernel_sys_irq_create:
    li a7, 24
    ecall
    ret
.size akernel_sys_irq_create, . - akernel_sys_irq_create

.global akernel_sys_mem_object_pa
.type akernel_sys_mem_object_pa, @function
akernel_sys_mem_object_pa:
    li a7, 25
    ecall
    ret
.size akernel_sys_mem_object_pa, . - akernel_sys_mem_object_pa

.global akernel_sys_cap_delete
.type akernel_sys_cap_delete, @function
akernel_sys_cap_delete:
    li a7, 26
    ecall
    ret
.size akernel_sys_cap_delete, . - akernel_sys_cap_delete

.global akernel_sys_mem_map_file
.type akernel_sys_mem_map_file, @function
akernel_sys_mem_map_file:
    mv a6, a5    /* delta ptr (6th Ada arg) */
    li a5, 1     /* flags: read-only (boot files) */
    li a7, 16
    ecall
    sd a1, 0(a6)
    ret
.size akernel_sys_mem_map_file, . - akernel_sys_mem_map_file

.global akernel_sys_debug_putchar
.type akernel_sys_debug_putchar, @function
akernel_sys_debug_putchar:
    li a7, 1
    ecall
    ret
.size akernel_sys_debug_putchar, . - akernel_sys_debug_putchar

.global akernel_sys_cpu_count
.type akernel_sys_cpu_count, @function
akernel_sys_cpu_count:
    li a7, 27
    ecall
    ret
.size akernel_sys_cpu_count, . - akernel_sys_cpu_count

.global akernel_sys_cap_mint
.type akernel_sys_cap_mint, @function
akernel_sys_cap_mint:
    li a7, 28
    ecall
    ret
.size akernel_sys_cap_mint, . - akernel_sys_cap_mint

.global akernel_sys_process_info
.type akernel_sys_process_info, @function
akernel_sys_process_info:
    li a7, 30
    ecall
    ret
.size akernel_sys_process_info, . - akernel_sys_process_info

.global akernel_sys_cap_info
.type akernel_sys_cap_info, @function
akernel_sys_cap_info:
    li a7, 31
    ecall
    ret
.size akernel_sys_cap_info, . - akernel_sys_cap_info

.global akernel_sys_thread_regs
.type akernel_sys_thread_regs, @function
akernel_sys_thread_regs:
    li a7, 32
    ecall
    ret
.size akernel_sys_thread_regs, . - akernel_sys_thread_regs

.global akernel_sys_system_reset
.type akernel_sys_system_reset, @function
akernel_sys_system_reset:
    li a7, 33
    ecall
    ret
.size akernel_sys_system_reset, . - akernel_sys_system_reset
