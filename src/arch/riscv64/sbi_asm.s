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

.global riscv_read_sstatus
.type riscv_read_sstatus, @function
riscv_read_sstatus:
    csrr a0, sstatus
    ret
.size riscv_read_sstatus, . - riscv_read_sstatus

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

.global trap_frame_advance_sepc
.type trap_frame_advance_sepc, @function
trap_frame_advance_sepc:
    /* sepc is frame-authoritative; advance the frame slot. */
    ld t0, 248(a0)
    addi t0, t0, 4
    sd t0, 248(a0)
    ret
.size trap_frame_advance_sepc, . - trap_frame_advance_sepc

.global trap_frame_for_stack
.type trap_frame_for_stack, @function
trap_frame_for_stack:
    /* a0 = kernel stack top; returns frame base below it.  The word
       at top - 8 (just above the frame) is the hart slot and is not
       part of the frame. */
    addi a0, a0, -280
    ret
.size trap_frame_for_stack, . - trap_frame_for_stack

.global riscv_current_hart
.type riscv_current_hart, @function
riscv_current_hart:
    /* Hart slot invariant: while kernel code runs, sscratch points at
       a kernel stack whose top - 8 word holds this hart's index
       (written by boot asm for per-hart stacks, by the scheduler for
       thread stacks). */
    csrr t0, sscratch
    ld a0, -8(t0)
    ret
.size riscv_current_hart, . - riscv_current_hart

.global riscv_spin_lock
.type riscv_spin_lock, @function
riscv_spin_lock:
    /* a0 = lock word address.  Big kernel lock: 0 = free, 1 = held. */
    li t1, 1
1:
    amoswap.d.aq t0, t1, (a0)
    bnez t0, 1b
    ret
.size riscv_spin_lock, . - riscv_spin_lock

.global riscv_spin_unlock
.type riscv_spin_unlock, @function
riscv_spin_unlock:
    amoswap.d.rl zero, zero, (a0)
    ret
.size riscv_spin_unlock, . - riscv_spin_unlock

.global sbi_send_ipi
.type sbi_send_ipi, @function
sbi_send_ipi:
    /* SBI sPI extension (0x735049) send_ipi(hart_mask, hart_mask_base). */
    li a7, 0x735049
    li a6, 0
    ecall
    ret
.size sbi_send_ipi, . - sbi_send_ipi

.global sbi_hart_start
.type sbi_hart_start, @function
sbi_hart_start:
    /* SBI HSM extension (0x48534D) hart_start(hartid, addr, opaque);
       returns the SBI error code in a0. */
    li a7, 0x48534D
    li a6, 0
    ecall
    ret
.size sbi_hart_start, . - sbi_hart_start

.global riscv_read_sip
.type riscv_read_sip, @function
riscv_read_sip:
    csrr a0, sip
    ret
.size riscv_read_sip, . - riscv_read_sip

.global riscv_clear_soft_pending
.type riscv_clear_soft_pending, @function
riscv_clear_soft_pending:
    li t0, (1 << 1)      /* sip.SSIP */
    csrc sip, t0
    ret
.size riscv_clear_soft_pending, . - riscv_clear_soft_pending

.global riscv_enable_software_interrupts
.type riscv_enable_software_interrupts, @function
riscv_enable_software_interrupts:
    li t0, (1 << 1)      /* sie.SSIE (no sstatus.SIE) */
    csrs sie, t0
    ret
.size riscv_enable_software_interrupts, . - riscv_enable_software_interrupts

.global riscv_enable_timer_software_sie
.type riscv_enable_timer_software_sie, @function
riscv_enable_timer_software_sie:
    /* Secondary harts: enable timer + software in sie only.  Unlike
       riscv_enable_timer_interrupts this leaves sstatus.SIE clear:
       kernel-mode wfi must wake without trapping (a trap would build
       a frame on top of the active one). */
    li t0, (1 << 5) | (1 << 1)   /* sie.STIE | sie.SSIE */
    csrs sie, t0
    ret
.size riscv_enable_timer_software_sie, . - riscv_enable_timer_software_sie

.global riscv_enter_via_frame
.type riscv_enter_via_frame, @function
riscv_enter_via_frame:
    /* Enter a scheduled thread through its kernel-stack trap frame
       (sscratch already points at the thread stack, the frame is
       restored).  Used by secondary harts picking their first
       thread: same sret path as a trap return. */
    csrr t0, sstatus
    li t1, ~(1 << 8)     /* clear SPP: return to U-mode */
    and t0, t0, t1
    li t1, (1 << 5)      /* SPIE: interrupts enabled after sret */
    or t0, t0, t1
    csrw sstatus, t0
    j trap_return
.size riscv_enter_via_frame, . - riscv_enter_via_frame

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

.global trap_frame_get_a5
.type trap_frame_get_a5, @function
trap_frame_get_a5:
    ld a0, 112(a0)
    ret
.size trap_frame_get_a5, . - trap_frame_get_a5

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

.global trap_frame_set_a1
.type trap_frame_set_a1, @function
trap_frame_set_a1:
    sd a1, 80(a0)
    ret
.size trap_frame_set_a1, . - trap_frame_set_a1

.global trap_frame_save_context
.type trap_frame_save_context, @function
trap_frame_save_context:
    li t0, 34
1:
    ld t1, 0(a0)
    sd t1, 0(a1)
    addi a0, a0, 8
    addi a1, a1, 8
    addi t0, t0, -1
    bnez t0, 1b
    ret
.size trap_frame_save_context, . - trap_frame_save_context

.global trap_frame_load_context
.type trap_frame_load_context, @function
trap_frame_load_context:
    mv t3, a1
    li t0, 34
1:
    ld t1, 0(t3)
    sd t1, 0(a0)
    addi a0, a0, 8
    addi t3, t3, 8
    addi t0, t0, -1
    bnez t0, 1b
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

.global riscv_fence_rw
.type riscv_fence_rw, @function
riscv_fence_rw:
    fence rw, rw
    ret
.size riscv_fence_rw, . - riscv_fence_rw

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


.global riscv_try_lock
.type riscv_try_lock, @function
riscv_try_lock:
    /* a0 = lock word; returns 0 if claimed, 1 if already held. */
    li t1, 1
    amoswap.d.aq t0, t1, (a0)
    snez a0, t0
    ret
.size riscv_try_lock, . - riscv_try_lock

.global riscv_jump_to_idle
.type riscv_jump_to_idle, @function
riscv_jump_to_idle:
    /* a0 = per-hart main stack top VA, a1 = per-hart trap stack top
       VA, a2 = idle loop entry.  Abandons the current (blocked
       thread's) kernel stack entirely: another hart may resume that
       thread and its next trap will reuse the stack. */
    mv sp, a0
    csrw sscratch, a1
    jr a2
.size riscv_jump_to_idle, . - riscv_jump_to_idle
