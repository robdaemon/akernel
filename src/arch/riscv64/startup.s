/* High-half boot.  The kernel image is linked at KERNEL_VIRT_BASE
   (0xFFFFFFFF80200000; VA - PA = 0xFFFFFFFF00000000, a whole gigapage,
   so the kernel VMA gigapage maps the image 1:1) and loaded by QEMU
   at 0x80200000.  _start runs
   with the MMU off at physical addresses, so every symbol access
   before the satp switch must be PC-relative (lla).  After the satp
   switch the CPU still executes the identity-mapped instructions, so
   PC-relative addressing still yields PAs; high VAs are formed by
   adding KERNEL_DELTA to lla results before jumping to main.  The
   early root is transitional only:
     root[2..5]    identity RAM gigapages (satp-switch instructions)
     root[0x100]   physmap gigapage for PA 0x00000000.. (MMIO)
     root[0x102..5] physmap gigapages for RAM PA 0x80000000..
     root[0x1FE]   kernel VMA gigapage -> PA 0x80000000 (temp RWX)
   Ada main runs at high VAs and soon replaces this with the dedicated
   W^X kernel address space. */

.equ KERNEL_DELTA, 0xFFFFFFFF00000000  /* KERNEL_VIRT_BASE - 0x80200000 */
.equ PHYSMAP_BASE, 0xFFFFFFC000000000  /* Arch.Physmap_Base */

.section .text.boot, "ax"
.global _start
.type _start, @function
_start:
    /* OpenSBI enters here in S-mode with:
       a0 = hart id, a1 = DTB physical address.
       Run only first hart that reaches kernel. Park all others. */
    lla t0, hart_lottery
    li t1, 1
    amoswap.d.aq t2, t1, (t0)
    bnez t2, .Lpark_hart

    /* Keep boot args in callee-saved temporaries while .bss is cleared. */
    mv s0, a0
    mv s1, a1

    /* No interrupts until Ada has real handlers. */
    csrw sie, zero

    /* Install S-mode trap vector, physical address for now. */
    lla t0, trap_vector
    csrw stvec, t0
    lla t0, __trap_stack_top
    csrw sscratch, t0

    /* Clear .bss via physical addresses. */
    lla t0, __bss_start
    lla t1, __BSS_END__
.Lclear_bss:
    bgeu t0, t1, .Lbss_done
    sd zero, 0(t0)
    addi t0, t0, 8
    j .Lclear_bss
.Lbss_done:

    /* Keep boot args for later FDT/SBI work. */
    lla t0, boot_hart_id
    sd s0, 0(t0)
    lla t0, boot_dtb_pa
    sd s1, 0(t0)

    /* Build early transitional Sv39 map (see header comment).
       1 GiB leaves, flags V/R/W/X/G/A/D = 0xef, V/R/W/G/A/D = 0xe7. */
    lla t0, early_l2_page_table
    /* identity RAM 0x80000000..0x17fffffff (transition only) */
    li t1, 0x200000ef
    sd t1, 16(t0)
    li t1, 0x300000ef
    sd t1, 24(t0)
    li t1, 0x400000ef
    sd t1, 32(t0)
    li t1, 0x500000ef
    sd t1, 40(t0)
    /* physmap: PA 0 (MMIO) at PHYSMAP_BASE */
    li t2, 0x800
    add t2, t2, t0
    li t1, 0x000000e7
    sd t1, 0(t2)
    /* physmap: RAM 0x80000000.. at PHYSMAP_BASE + PA */
    li t1, 0x200000e7
    sd t1, 16(t2)
    li t1, 0x300000e7
    sd t1, 24(t2)
    li t1, 0x400000e7
    sd t1, 32(t2)
    li t1, 0x500000e7
    sd t1, 40(t2)
    /* kernel VMA gigapage -> PA 0x80000000 */
    li t2, 0xff0
    add t2, t2, t0
    li t1, 0x200000ef
    sd t1, 0(t2)

    /* Enable Sv39. satp = MODE(Sv39=8) | PPN(root). */
    srli t0, t0, 12
    li t1, 0x8000000000000000
    or t0, t0, t1
    /* Publish kernel satp for the trap trampoline. */
    lla t1, kernel_satp_slot
    sd t0, 0(t1)
    csrw satp, t0
    sfence.vma zero, zero

    /* Identity-mapped from here until the jump below.  PC-relative
       addressing still yields physical addresses, so form kernel VAs
       by adding KERNEL_DELTA, then jump to high-half main. */
    li t2, KERNEL_DELTA
    lla sp, __stack_top
    add sp, sp, t2
.option push
.option norelax
    lla gp, __global_pointer$
    add gp, gp, t2
.option pop
    lla t0, trap_vector
    add t0, t0, t2
    csrw stvec, t0
    lla t0, __trap_stack_top
    add t0, t0, t2
    csrw sscratch, t0
    sd zero, -8(t0)         /* hart slot: boot hart is index 0 */
    lla t0, main
    add t0, t0, t2
    jalr ra, 0(t0)

.Lhalt:
    wfi
    j .Lhalt

.Lpark_hart:
    wfi
    j .Lpark_hart
.size _start, . - _start

/* Secondary hart entry, reached via SBI HSM hart_start from the
   primary.  Entered in S-mode with the MMU off:
     a0 = raw hart id, a1 = PA of this hart's boot info block
   Boot info block (Kernel.CPUs.Boot_Info, physical memory):
     +0   trap kernel stack top PA (PMM-allocated, hart slot at -8)
     +8   hart index (Kernel.CPUs index, not the raw hart id)
     +16  main kernel stack top PA
   Stacks come from the PMM, so their runtime addresses are physmap
   VAs (PHYSMAP_BASE + PA) once the MMU is on.  The final kernel root
   keeps one identity RX gigapage covering the kernel image so the
   satp switch below does not fault the handful of instructions that
   still execute at physical addresses. */
.section .text.boot, "ax"
.global secondary_boot
.type secondary_boot, @function
secondary_boot:
    csrw sie, zero

    mv   s0, a1               /* boot info block PA */
    ld   t0, 0(s0)            /* trap stack top PA */
    ld   t3, 8(s0)            /* hart index */
    ld   t4, 16(s0)           /* main stack top PA */
    sd   t3, -8(t0)           /* hart slot: this hart's index */
    csrw sscratch, t0

    /* Switch to the kernel address space.  The slot sits in the
       trampoline page; lla still yields its physical address, which
       the MMU-off load below reads directly. */
    lla t1, kernel_satp_slot
    ld t1, 0(t1)
    csrw satp, t1
    sfence.vma zero, zero

    /* High VAs from here (identity gigapage bridged the switch);
       PMM frames live at PHYSMAP_BASE + PA. */
    li t2, PHYSMAP_BASE
    add t0, t0, t2
    csrw sscratch, t0
    add sp, t4, t2
    li t2, KERNEL_DELTA
.option push
.option norelax
    lla gp, __global_pointer$
    add gp, gp, t2
.option pop
    lla t0, trap_vector
    add t0, t0, t2
    csrw stvec, t0
    lla t0, secondary_main
    add t0, t0, t2
    jalr ra, 0(t0)

2:  wfi
    j 2b
.size secondary_boot, . - secondary_boot

/* Trap trampoline.  This page is mapped at its kernel VMA in every
   user address space (supervisor RX, global), so satp switching keeps
   execution valid.  Frame layout (280 bytes), built on the per-thread
   kernel stack:
     word 0..30  x1..x31 at (reg - 1) * 8   (word 1 = interrupted sp)
     word 31     sepc (offset 248), frame-authoritative
     word 32     satp (offset 256), root to return to
     word 33     pad (offset 264)
   The word at stack_top - 8 (just above the frame) is the hart slot:
   the index of the hart currently running on this stack.  It is
   written by the boot asm for per-hart stacks and by the scheduler
   every time a thread is switched in, so kernel code can always
   recover its hart index from sscratch (riscv_current_hart).
   sscratch invariant: always holds the current thread kernel stack
   top as a physmap VA (PHYSMAP_BASE + PA; user roots map their own
   kernel stack at that VA) or a kernel VMA for the boot trap stack.
   Every frame address is therefore valid in both the owning user root
   and the kernel address space, so no pointer conversion is needed
   around satp switches. */
.section .trampoline, "ax"
.align 3
.global kernel_satp_slot
kernel_satp_slot:
    .skip 8

.global trap_vector
.type trap_vector, @function
trap_vector:
    csrrw t0, sscratch, t0   /* t0 = kernel stack top, sscratch = user t0 */
    addi  t0, t0, -280
    sd    t1, 40(t0)         /* user t1 (x6) */
    csrr  t1, sscratch       /* user t0 */
    sd    t1, 32(t0)         /* user t0 (x5) */
    addi  t1, t0, 280
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

    /* Switch to kernel address space.  Frame and slot both live at
       kernel VAs reachable from the current root. */
.Lkernel_satp_hi:
    auipc t1, %pcrel_hi(kernel_satp_slot)
    ld    t1, %pcrel_lo(.Lkernel_satp_hi)(t1)
    csrw  satp, t1
    sfence.vma zero, zero

    mv    sp, t0
    mv    a0, t0
    call  riscv_trap_handler

    /* Release the big kernel lock here, not inside the C handler:
       the handler's return path just finished reading the old
       thread's kernel stack, and after the unlock another hart may
       resume that thread, whose next trap reuses the stack.  From
       here on this path touches no stack at all. */
    lla   t0, kernel_lock_owner
    li    t1, -1
    sd    t1, 0(t0)
    lla   t0, kernel_lock_word
    amoswap.d.rl t1, zero, (t0)

    /* Exit: use sscratch so a scheduled-away trap returns through the
       newly current thread kernel stack frame.  The frame is valid in
       the current space and in the space named by its satp slot.
       trap_return is a separate global entry: a secondary hart that
       just picked its first thread restores its context into the
       thread kernel stack frame, points sscratch at that stack, and
       jumps here (no trap frame of its own exists). */
.global trap_return
trap_return:
    csrr  t0, sscratch
    addi  t0, t0, -280
    ld    t1, 256(t0)
    csrw  satp, t1
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
   Runs from the trampoline page, which user roots map at this kernel
   VMA, so execution stays valid across the satp switch. */
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
