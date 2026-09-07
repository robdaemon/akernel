.section .text.user, "ax"

.global aegir_sys_yield
.type aegir_sys_yield, @function
aegir_sys_yield:
    li a7, 0
    ecall
    ret
.size aegir_sys_yield, . - aegir_sys_yield

.global aegir_sys_map_mmio
.type aegir_sys_map_mmio, @function
aegir_sys_map_mmio:
    li a7, 2
    ecall
    ret
.size aegir_sys_map_mmio, . - aegir_sys_map_mmio

.global aegir_sys_irq_wait
.type aegir_sys_irq_wait, @function
aegir_sys_irq_wait:
    li a7, 3
    ecall
    ret
.size aegir_sys_irq_wait, . - aegir_sys_irq_wait

.global aegir_sys_irq_ack
.type aegir_sys_irq_ack, @function
aegir_sys_irq_ack:
    li a7, 4
    ecall
    ret
.size aegir_sys_irq_ack, . - aegir_sys_irq_ack

.global aegir_sys_boot_file_size
.type aegir_sys_boot_file_size, @function
aegir_sys_boot_file_size:
    li a7, 6
    ecall
    ret
.size aegir_sys_boot_file_size, . - aegir_sys_boot_file_size

.global aegir_sys_boot_read_byte
.type aegir_sys_boot_read_byte, @function
aegir_sys_boot_read_byte:
    li a7, 7
    ecall
    ret
.size aegir_sys_boot_read_byte, . - aegir_sys_boot_read_byte

.global aegir_sys_spawn
.type aegir_sys_spawn, @function
aegir_sys_spawn:
    li a7, 8
    ecall
    sd a1, 0(a2)
    ret
.size aegir_sys_spawn, . - aegir_sys_spawn

.global aegir_sys_exit
.type aegir_sys_exit, @function
aegir_sys_exit:
    li a7, 9
    ecall
    ret
.size aegir_sys_exit, . - aegir_sys_exit

.global aegir_sys_reap_process
.type aegir_sys_reap_process, @function
aegir_sys_reap_process:
    li a7, 10
    ecall
    ret
.size aegir_sys_reap_process, . - aegir_sys_reap_process

.global aegir_sys_reap_process_code
.type aegir_sys_reap_process_code, @function
# a0 = process cap, a1 = code out pointer; reap returns the
# child's exit code in a1, clobbering the pointer — save it first.
aegir_sys_reap_process_code:
    mv t0, a1
    li a7, 10
    ecall
    sd a1, 0(t0)
    ret
.size aegir_sys_reap_process_code, . - aegir_sys_reap_process_code

.global aegir_sys_ep_create
.type aegir_sys_ep_create, @function
aegir_sys_ep_create:
    li a7, 11
    ecall
    ret
.size aegir_sys_ep_create, . - aegir_sys_ep_create

.global aegir_sys_ep_set_stamp_identity
.type aegir_sys_ep_set_stamp_identity, @function
aegir_sys_ep_set_stamp_identity:
    li a7, 41
    ecall
    ret
.size aegir_sys_ep_set_stamp_identity, . - aegir_sys_ep_set_stamp_identity

.global aegir_sys_ipc_call
.type aegir_sys_ipc_call, @function
aegir_sys_ipc_call:
    li a7, 12
    ecall
    ret
.size aegir_sys_ipc_call, . - aegir_sys_ipc_call

.global aegir_sys_ipc_recv
.type aegir_sys_ipc_recv, @function
aegir_sys_ipc_recv:
    mv t0, a1
    li a7, 13
    ecall
    sd a1, 0(t0)
    ret
.size aegir_sys_ipc_recv, . - aegir_sys_ipc_recv

.global aegir_sys_ipc_send
.type aegir_sys_ipc_send, @function
aegir_sys_ipc_send:
    li a7, 29
    ecall
    ret
.size aegir_sys_ipc_send, . - aegir_sys_ipc_send

.global aegir_sys_ipc_reply
.type aegir_sys_ipc_reply, @function
aegir_sys_ipc_reply:
    li a7, 14
    ecall
    ret
.size aegir_sys_ipc_reply, . - aegir_sys_ipc_reply

.global aegir_sys_mem_alloc
.type aegir_sys_mem_alloc, @function
aegir_sys_mem_alloc:
    li a7, 15
    ecall
    ret
.size aegir_sys_mem_alloc, . - aegir_sys_mem_alloc

.global aegir_sys_mem_map
.type aegir_sys_mem_map, @function
aegir_sys_mem_map:
    li a7, 16
    ecall
    ret
.size aegir_sys_mem_map, . - aegir_sys_mem_map

.global aegir_sys_mem_unmap
.type aegir_sys_mem_unmap, @function
aegir_sys_mem_unmap:
    li a7, 17
    ecall
    ret
.size aegir_sys_mem_unmap, . - aegir_sys_mem_unmap

.global aegir_sys_ntfn_create
.type aegir_sys_ntfn_create, @function
aegir_sys_ntfn_create:
    li a7, 18
    ecall
    ret
.size aegir_sys_ntfn_create, . - aegir_sys_ntfn_create

.global aegir_sys_ntfn_wait
.type aegir_sys_ntfn_wait, @function
aegir_sys_ntfn_wait:
    li a7, 19
    ecall
    ret
.size aegir_sys_ntfn_wait, . - aegir_sys_ntfn_wait

.global aegir_sys_ntfn_signal
.type aegir_sys_ntfn_signal, @function
aegir_sys_ntfn_signal:
    li a7, 20
    ecall
    ret
.size aegir_sys_ntfn_signal, . - aegir_sys_ntfn_signal

.global aegir_sys_ntfn_bind_thread
.type aegir_sys_ntfn_bind_thread, @function
aegir_sys_ntfn_bind_thread:
    li a7, 21
    ecall
    ret
.size aegir_sys_ntfn_bind_thread, . - aegir_sys_ntfn_bind_thread

.global aegir_sys_irq_bind_ntfn
.type aegir_sys_irq_bind_ntfn, @function
aegir_sys_irq_bind_ntfn:
    li a7, 22
    ecall
    ret
.size aegir_sys_irq_bind_ntfn, . - aegir_sys_irq_bind_ntfn

.global aegir_sys_io_map
.type aegir_sys_io_map, @function
aegir_sys_io_map:
    li a7, 23
    ecall
    ret
.size aegir_sys_io_map, . - aegir_sys_io_map

.global aegir_sys_irq_create
.type aegir_sys_irq_create, @function
aegir_sys_irq_create:
    li a7, 24
    ecall
    ret
.size aegir_sys_irq_create, . - aegir_sys_irq_create

.global aegir_sys_irq_msi_create
.type aegir_sys_irq_msi_create, @function
# a0 = resource cap, a1 = device id, a2 = vector index,
# a3 = address out pointer, a4 = data out pointer.
# Returns the IRQ cap in a0; address/data are returned in a1/a2
# and stored through the caller's out pointers.
aegir_sys_irq_msi_create:
    mv t0, a3
    mv t1, a4
    li a7, 42
    ecall
    sd a1, 0(t0)
    sd a2, 0(t1)
    ret
.size aegir_sys_irq_msi_create, . - aegir_sys_irq_msi_create

.global aegir_sys_mem_object_pa
.type aegir_sys_mem_object_pa, @function
aegir_sys_mem_object_pa:
    li a7, 25
    ecall
    ret
.size aegir_sys_mem_object_pa, . - aegir_sys_mem_object_pa

.global aegir_sys_cap_delete
.type aegir_sys_cap_delete, @function
aegir_sys_cap_delete:
    li a7, 26
    ecall
    ret
.size aegir_sys_cap_delete, . - aegir_sys_cap_delete

.global aegir_sys_mem_map_file
.type aegir_sys_mem_map_file, @function
aegir_sys_mem_map_file:
    mv a6, a5    /* delta ptr (6th Ada arg) */
    li a5, 1     /* flags: read-only (boot files) */
    li a7, 16
    ecall
    sd a1, 0(a6)
    ret
.size aegir_sys_mem_map_file, . - aegir_sys_mem_map_file

.global aegir_sys_debug_putchar
.type aegir_sys_debug_putchar, @function
aegir_sys_debug_putchar:
    li a7, 1
    ecall
    ret
.size aegir_sys_debug_putchar, . - aegir_sys_debug_putchar

.global aegir_sys_cpu_count
.type aegir_sys_cpu_count, @function
aegir_sys_cpu_count:
    li a7, 27
    ecall
    ret
.size aegir_sys_cpu_count, . - aegir_sys_cpu_count

.global aegir_sys_cap_mint
.type aegir_sys_cap_mint, @function
aegir_sys_cap_mint:
    li a7, 28
    ecall
    ret
.size aegir_sys_cap_mint, . - aegir_sys_cap_mint

.global aegir_sys_process_info
.type aegir_sys_process_info, @function
aegir_sys_process_info:
    li a7, 30
    ecall
    ret
.size aegir_sys_process_info, . - aegir_sys_process_info

.global aegir_sys_cap_info
.type aegir_sys_cap_info, @function
aegir_sys_cap_info:
    li a7, 31
    ecall
    ret
.size aegir_sys_cap_info, . - aegir_sys_cap_info

.global aegir_sys_thread_regs
.type aegir_sys_thread_regs, @function
aegir_sys_thread_regs:
    li a7, 32
    ecall
    ret
.size aegir_sys_thread_regs, . - aegir_sys_thread_regs

.global aegir_sys_system_reset
.type aegir_sys_system_reset, @function
aegir_sys_system_reset:
    li a7, 33
    ecall
    ret
.size aegir_sys_system_reset, . - aegir_sys_system_reset

.global aegir_sys_read_clock
.type aegir_sys_read_clock, @function
aegir_sys_read_clock:
    mv t0, a0
    li a7, 34
    ecall
    sd a1, 0(t0)
    ret
.size aegir_sys_read_clock, . - aegir_sys_read_clock

.global aegir_sys_set_priority
.type aegir_sys_set_priority, @function
aegir_sys_set_priority:
    mv t0, a2
    li a7, 35
    ecall
    sd a1, 0(t0)
    ret
.size aegir_sys_set_priority, . - aegir_sys_set_priority

.global aegir_sys_thread_create
.type aegir_sys_thread_create, @function
aegir_sys_thread_create:
    li a7, 36
    ecall
    ret
.size aegir_sys_thread_create, . - aegir_sys_thread_create

.global aegir_sys_thread_exit
.type aegir_sys_thread_exit, @function
aegir_sys_thread_exit:
    li a7, 37
    ecall
    ret
.size aegir_sys_thread_exit, . - aegir_sys_thread_exit

.global aegir_sys_thread_self
.type aegir_sys_thread_self, @function
aegir_sys_thread_self:
    li a7, 38
    ecall
    ret
.size aegir_sys_thread_self, . - aegir_sys_thread_self

#  m73: calling thread's IPC buffer user VA (secondary threads get
#  their own page below the legacy 0x6FFF_0000 window).
.global aegir_sys_thread_ipc_va
.type aegir_sys_thread_ipc_va, @function
aegir_sys_thread_ipc_va:
    li a7, 43
    ecall
    ret
.size aegir_sys_thread_ipc_va, . - aegir_sys_thread_ipc_va

.global aegir_sys_sleep_until
.type aegir_sys_sleep_until, @function
aegir_sys_sleep_until:
    li a7, 39
    ecall
    ret
.size aegir_sys_sleep_until, . - aegir_sys_sleep_until

.global aegir_sys_thread_wait
.type aegir_sys_thread_wait, @function
aegir_sys_thread_wait:
    li a7, 40
    ecall
    ret
.size aegir_sys_thread_wait, . - aegir_sys_thread_wait

/*  Generic secondary-thread entry trampoline.  Userspace sets the
    Thread_Create entry PC to this address and passes the real thread
    function address in the argument word.  We establish gp and then
    tail-call the function; if it returns, we invoke Thread_Exit. */
.global aegir_thread_entry
.type aegir_thread_entry, @function
aegir_thread_entry:
    .option push
    .option norelax
    lla gp, __global_pointer$
    .option pop
    mv t0, a0
    jalr t0
    /*  Thread_Exit (syscall 37) if the function returns. */
    li a7, 37
    ecall
1:
    j 1b
.size aegir_thread_entry, . - aegir_thread_entry

.section .note.GNU-stack, "", @progbits
