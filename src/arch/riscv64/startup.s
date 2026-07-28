.section .text.boot, "ax"
.global _start
.type _start, @function
_start:
    /* OpenSBI enters here in S-mode with:
       a0 = hart id, a1 = DTB physical address.
       Run only first hart that reaches kernel. Park all others. */
    la t0, hart_lottery
    li t1, 1
    amoswap.d.aq t2, t1, (t0)
    bnez t2, .Lpark_hart

.option push
.option norelax
    la gp, __global_pointer$
.option pop
    la sp, __stack_top

    /* Keep boot args in callee-saved temporaries while .bss is cleared. */
    mv s0, a0
    mv s1, a1

    /* No interrupts until Ada has real handlers. */
    csrw sie, zero

    /* Install S-mode trap vector. Direct mode. */
    la t0, trap_vector
    csrw stvec, t0
    la t0, __trap_stack_top
    csrw sscratch, t0

    /* Clear .bss. */
    la t0, __bss_start
    la t1, __BSS_END__
.Lclear_bss:
    bgeu t0, t1, .Lbss_done
    sd zero, 0(t0)
    addi t0, t0, 8
    j .Lclear_bss
.Lbss_done:

    /* Keep boot args for later FDT/SBI work. */
    la t0, boot_hart_id
    sd s0, 0(t0)
    la t0, boot_dtb_pa
    sd s1, 0(t0)

    /* Build early Sv39 identity map, used only until the dedicated
       kernel address space replaces it shortly after PMM init.
       root[0] maps 0x0000_0000..0x3fff_ffff: MMIO, including UART0.
       root[2..5] maps 0x8000_0000..0x17fff_ffff: up to 4 GiB RAM.
       1 GiB leaves, flags V/R/W/X/G/A/D. */
    la t0, early_l2_page_table
    li t1, 0x000000ef
    sd t1, 0(t0)
    li t1, 0x200000ef
    sd t1, 16(t0)
    li t1, 0x300000ef
    sd t1, 24(t0)
    li t1, 0x400000ef
    sd t1, 32(t0)
    li t1, 0x500000ef
    sd t1, 40(t0)

    /* Enable Sv39. satp = MODE(Sv39=8) | PPN(root). */
    srli t0, t0, 12
    li t1, 0x8000000000000000
    or t0, t0, t1
    /* Publish kernel satp for the trap trampoline. */
    la t1, kernel_satp_slot
    sd t0, 0(t1)
    csrw satp, t0
    sfence.vma zero, zero

    call main

.Lhalt:
    wfi
    j .Lhalt

.Lpark_hart:
    wfi
    j .Lpark_hart
.size _start, . - _start

/* Trap trampoline.  This page is mapped into every user address space
   at its identity (physical) address so that satp switching works.
   Frame layout (272 bytes), built on the per-thread kernel stack which
   is also mapped into the owning user address space:
     word 0..30  x1..x31 at (reg - 1) * 8   (word 1 = interrupted sp)
     word 31     sepc (offset 248), frame-authoritative
     word 32     satp (offset 256), root to return to
     word 33     pad (offset 264)
   sscratch invariant: always holds the current thread kernel stack
   top, in both S-mode and U-mode. */
.section .trampoline, "ax"
.align 3
.global kernel_satp_slot
kernel_satp_slot:
    .skip 8

.global trap_vector
.type trap_vector, @function
trap_vector:
    csrrw t0, sscratch, t0   /* t0 = kernel stack top, sscratch = user t0 */
    addi  t0, t0, -272
    sd    t1, 40(t0)         /* user t1 (x6) */
    csrr  t1, sscratch       /* user t0 */
    sd    t1, 32(t0)         /* user t0 (x5) */
    addi  t1, t0, 272
    csrw  sscratch, t1       /* sscratch = kernel stack top again */

    sd    x1,   0(t0)
    sd    sp,   8(t0)        /* interrupted sp */
    sd    x3,  16(t0)
    sd    x4,  24(t0)
    sd    x7,  48(t0)
    sd    x8,  56(t0)
    sd    x9,  64(t0)
    sd    x10, 72(t0)
    sd    x11, 80(t0)
    sd    x12, 88(t0)
    sd    x13, 96(t0)
    sd    x14, 104(t0)
    sd    x15, 112(t0)
    sd    x16, 120(t0)
    sd    x17, 128(t0)
    sd    x18, 136(t0)
    sd    x19, 144(t0)
    sd    x20, 152(t0)
    sd    x21, 160(t0)
    sd    x22, 168(t0)
    sd    x23, 176(t0)
    sd    x24, 184(t0)
    sd    x25, 192(t0)
    sd    x26, 200(t0)
    sd    x27, 208(t0)
    sd    x28, 216(t0)
    sd    x29, 224(t0)
    sd    x30, 232(t0)
    sd    x31, 240(t0)

    csrr  t1, sepc
    sd    t1, 248(t0)
    csrr  t1, satp
    sd    t1, 256(t0)

    /* Switch to kernel (early root) address space. */
.Lkernel_satp_hi:
    auipc t1, %pcrel_hi(kernel_satp_slot)
    ld    t1, %pcrel_lo(.Lkernel_satp_hi)(t1)
    csrw  satp, t1
    sfence.vma zero, zero

    mv    sp, t0
    mv    a0, t0
    call  riscv_trap_handler

    /* Exit: use sscratch so a scheduled-away trap returns through the
       newly current thread kernel stack frame. */
    csrr  t0, sscratch
    addi  t0, t0, -272

    ld    t1, 256(t0)
    csrw  satp, t1           /* switch to return address space */
    sfence.vma zero, zero

    ld    t1, 248(t0)
    csrw  sepc, t1

    ld    x1,   0(t0)
    ld    x3,  16(t0)
    ld    x4,  24(t0)
    ld    x6,  40(t0)
    ld    x7,  48(t0)
    ld    x8,  56(t0)
    ld    x9,  64(t0)
    ld    x10, 72(t0)
    ld    x11, 80(t0)
    ld    x12, 88(t0)
    ld    x13, 96(t0)
    ld    x14, 104(t0)
    ld    x15, 112(t0)
    ld    x16, 120(t0)
    ld    x17, 128(t0)
    ld    x18, 136(t0)
    ld    x19, 144(t0)
    ld    x20, 152(t0)
    ld    x21, 160(t0)
    ld    x22, 168(t0)
    ld    x23, 176(t0)
    ld    x24, 184(t0)
    ld    x25, 192(t0)
    ld    x26, 200(t0)
    ld    x27, 208(t0)
    ld    x28, 216(t0)
    ld    x29, 224(t0)
    ld    x30, 232(t0)
    ld    x31, 240(t0)
    ld    sp,   8(t0)        /* interrupted sp; no sp use after this */
    ld    t0,  32(t0)        /* t0 (x5) last; self-clobbering load */
    sret
.size trap_vector, . - trap_vector

/* a0 = user entry, a1 = user stack, a2 = user address space satp value.
   Must run from the trampoline page: it switches satp before sret. */
.global riscv_enter_user_mode
.type riscv_enter_user_mode, @function
riscv_enter_user_mode:
    csrw  sepc, a0
    csrr  t0, sstatus
    li    t1, ~(1 << 8)      /* clear SPP: return to U-mode */
    and   t0, t0, t1
    li    t1, (1 << 5)       /* SPIE: interrupts enabled after sret */
    or    t0, t0, t1
    csrw  sstatus, t0
    csrw  satp, a2
    sfence.vma zero, zero
    mv    sp, a1
    sret
.size riscv_enter_user_mode, . - riscv_enter_user_mode

.section .bss, "aw", @nobits
.align 12
.global early_l2_page_table
early_l2_page_table:
    .skip 4096

.align 3
.global boot_hart_id
boot_hart_id:
    .skip 8
.global boot_dtb_pa
boot_dtb_pa:
    .skip 8
.global last_trap_scause
last_trap_scause:
    .skip 8
.global last_trap_sepc
last_trap_sepc:
    .skip 8
.global last_trap_stval
last_trap_stval:
    .skip 8

.section .data, "aw"
.align 3
hart_lottery:
    .dword 0
