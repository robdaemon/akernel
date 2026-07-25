.section .text.user, "ax"
.global user_init
.type user_init, @function
user_init:
    la t0, .Lmessage
1:
    lbu a0, 0(t0)
    beqz a0, 2f
    li a7, 1               /* debug_putchar */
    ecall
    addi t0, t0, 1
    j 1b
2:
    li a7, 0               /* yield */
    ecall
    j 2b

.Lmessage:
    .asciz "init loader pending\n"
.size user_init, . - user_init
