.section .text, "ax"

.global sbi_set_timer
.type sbi_set_timer, @function
sbi_set_timer:
    /* Legacy SBI set_timer(time_value). Portable on OpenSBI. */
    li a7, 0
    ecall
    ret
.size sbi_set_timer, . - sbi_set_timer

.global riscv_read_time
.type riscv_read_time, @function
riscv_read_time:
    csrr a0, time
    ret
.size riscv_read_time, . - riscv_read_time

.global riscv_enable_timer_interrupts
.type riscv_enable_timer_interrupts, @function
riscv_enable_timer_interrupts:
    li t0, (1 << 5)      /* sie.STIE */
    csrs sie, t0
    li t0, (1 << 1)      /* sstatus.SIE */
    csrs sstatus, t0
    ret
.size riscv_enable_timer_interrupts, . - riscv_enable_timer_interrupts

.global riscv_enable_external_interrupts
.type riscv_enable_external_interrupts, @function
riscv_enable_external_interrupts:
    li t0, (1 << 9)      /* sie.SEIE */
    csrs sie, t0
    li t0, (1 << 1)      /* sstatus.SIE */
    csrs sstatus, t0
    ret
.size riscv_enable_external_interrupts, . - riscv_enable_external_interrupts

.global riscv_disable_interrupts
.type riscv_disable_interrupts, @function
riscv_disable_interrupts:
    li t0, (1 << 1)      /* sstatus.SIE */
    csrc sstatus, t0
    ret
.size riscv_disable_interrupts, . - riscv_disable_interrupts

.global riscv_wfi
.type riscv_wfi, @function
riscv_wfi:
    wfi
    ret
.size riscv_wfi, . - riscv_wfi

.global riscv_read_scause
.type riscv_read_scause, @function
riscv_read_scause:
    csrr a0, scause
    ret
.size riscv_read_scause, . - riscv_read_scause

.global riscv_read_sepc
.type riscv_read_sepc, @function
riscv_read_sepc:
    csrr a0, sepc
    ret
.size riscv_read_sepc, . - riscv_read_sepc

.global riscv_read_stval
.type riscv_read_stval, @function
riscv_read_stval:
    csrr a0, stval
    ret
.size riscv_read_stval, . - riscv_read_stval

.global riscv_advance_sepc
.type riscv_advance_sepc, @function
riscv_advance_sepc:
    csrr t0, sepc
    addi t0, t0, 4
    csrw sepc, t0
    ret
.size riscv_advance_sepc, . - riscv_advance_sepc

.global trap_frame_get_a0
.type trap_frame_get_a0, @function
trap_frame_get_a0:
    ld a0, 72(a0)
    ret
.size trap_frame_get_a0, . - trap_frame_get_a0

.global trap_frame_get_a1
.type trap_frame_get_a1, @function
trap_frame_get_a1:
    ld a0, 80(a0)
    ret
.size trap_frame_get_a1, . - trap_frame_get_a1

.global trap_frame_get_a2
.type trap_frame_get_a2, @function
trap_frame_get_a2:
    ld a0, 88(a0)
    ret
.size trap_frame_get_a2, . - trap_frame_get_a2

.global trap_frame_get_a3
.type trap_frame_get_a3, @function
trap_frame_get_a3:
    ld a0, 96(a0)
    ret
.size trap_frame_get_a3, . - trap_frame_get_a3

.global trap_frame_get_a4
.type trap_frame_get_a4, @function
trap_frame_get_a4:
    ld a0, 104(a0)
    ret
.size trap_frame_get_a4, . - trap_frame_get_a4

.global trap_frame_get_a7
.type trap_frame_get_a7, @function
trap_frame_get_a7:
    ld a0, 128(a0)
    ret
.size trap_frame_get_a7, . - trap_frame_get_a7

.global trap_frame_set_a0
.type trap_frame_set_a0, @function
trap_frame_set_a0:
    sd a1, 72(a0)
    ret
.size trap_frame_set_a0, . - trap_frame_set_a0

.global trap_frame_save_context
.type trap_frame_save_context, @function
trap_frame_save_context:
    li t0, 31
1:
    ld t1, 0(a0)
    sd t1, 0(a1)
    addi a0, a0, 8
    addi a1, a1, 8
    addi t0, t0, -1
    bnez t0, 1b
    csrr t1, sepc
    sd t1, 0(a1)
    ret
.size trap_frame_save_context, . - trap_frame_save_context

.global trap_frame_load_context
.type trap_frame_load_context, @function
trap_frame_load_context:
    mv t3, a1
    li t0, 31
1:
    ld t1, 0(t3)
    sd t1, 0(a0)
    addi a0, a0, 8
    addi t3, t3, 8
    addi t0, t0, -1
    bnez t0, 1b
    ld t1, 0(t3)
    csrw sepc, t1
    ret
.size trap_frame_load_context, . - trap_frame_load_context

.global riscv_activate_satp
.type riscv_activate_satp, @function
riscv_activate_satp:
    srli a0, a0, 12
    li t0, 0x8000000000000000
    or a0, a0, t0
    csrw satp, a0
    sfence.vma zero, zero
    ret
.size riscv_activate_satp, . - riscv_activate_satp

.global riscv_reset_trap_stack
.type riscv_reset_trap_stack, @function
riscv_reset_trap_stack:
    la t0, __trap_stack_top
    csrw sscratch, t0
    ret
.size riscv_reset_trap_stack, . - riscv_reset_trap_stack

.global riscv_set_trap_stack
.type riscv_set_trap_stack, @function
riscv_set_trap_stack:
    csrw sscratch, a0
    ret
.size riscv_set_trap_stack, . - riscv_set_trap_stack

.global riscv_enter_user_mode
.type riscv_enter_user_mode, @function
riscv_enter_user_mode:
    csrw sepc, a0
    mv sp, a1
    csrr t0, sstatus
    li t1, ~(1 << 8)       /* clear SPP: return to U-mode */
    and t0, t0, t1
    li t1, (1 << 5)        /* SPIE: interrupts enabled after sret */
    or t0, t0, t1
    csrw sstatus, t0
    sret
.size riscv_enter_user_mode, . - riscv_enter_user_mode
