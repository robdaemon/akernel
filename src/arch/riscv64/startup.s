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

    /* Build early Sv39 identity map.
       root[0] maps 0x0000_0000..0x3fff_ffff: MMIO, including UART0.
       root[2..5] maps 0x8000_0000..0x17fff_ffff: up to 4 GiB RAM.
       1 GiB leaves, flags V/R/W/X/G/A/D. */
    la t0, early_l2_page_table
    li t1, 0x000000ef
    sd t1, 0(t0)
    li t1, 0x200000df
    sd t1, 8(t0)
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

.global trap_vector
.type trap_vector, @function
trap_vector:
    csrr x5, sstatus
    andi x5, x5, (1 << 8)      /* SPP: previous mode was S */
    bnez x5, .Ltrap_from_s
    csrrw sp, sscratch, sp
.Ltrap_from_s:
    addi sp, sp, -272
    sd x1,    0(sp)
    sd x5,  248(sp)
    sd x5,   32(sp)
    csrr x5, sscratch
    sd x5,    8(sp)
    sd x3,   16(sp)
    sd x4,   24(sp)
    sd x6,   40(sp)
    sd x7,   48(sp)
    sd x8,   56(sp)
    sd x9,   64(sp)
    sd x10,  72(sp)
    sd x11,  80(sp)
    sd x12,  88(sp)
    sd x13,  96(sp)
    sd x14, 104(sp)
    sd x15, 112(sp)
    sd x16, 120(sp)
    sd x17, 128(sp)
    sd x18, 136(sp)
    sd x19, 144(sp)
    sd x20, 152(sp)
    sd x21, 160(sp)
    sd x22, 168(sp)
    sd x23, 176(sp)
    sd x24, 184(sp)
    sd x25, 192(sp)
    sd x26, 200(sp)
    sd x27, 208(sp)
    sd x28, 216(sp)
    sd x29, 224(sp)
    sd x30, 232(sp)
    sd x31, 240(sp)

    mv a0, sp
    call riscv_trap_handler

    ld x5,  248(sp)
    bnez x5, .Ltrap_return_s
    ld x5,    8(sp)
    csrw sscratch, x5
.Ltrap_return_s:
    ld x1,    0(sp)
    ld x3,   16(sp)
    ld x4,   24(sp)
    ld x5,   32(sp)
    ld x6,   40(sp)
    ld x7,   48(sp)
    ld x8,   56(sp)
    ld x9,   64(sp)
    ld x10,  72(sp)
    ld x11,  80(sp)
    ld x12,  88(sp)
    ld x13,  96(sp)
    ld x14, 104(sp)
    ld x15, 112(sp)
    ld x16, 120(sp)
    ld x17, 128(sp)
    ld x18, 136(sp)
    ld x19, 144(sp)
    ld x20, 152(sp)
    ld x21, 160(sp)
    ld x22, 168(sp)
    ld x23, 176(sp)
    ld x24, 184(sp)
    ld x25, 192(sp)
    ld x26, 200(sp)
    ld x27, 208(sp)
    ld x28, 216(sp)
    ld x29, 224(sp)
    ld x30, 232(sp)
    ld x31, 240(sp)
    ld x5,  248(sp)
    addi sp, sp, 272
    bnez x5, .Ltrap_sret
    csrrw sp, sscratch, sp
.Ltrap_sret:
    sret
.size trap_vector, . - trap_vector

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
