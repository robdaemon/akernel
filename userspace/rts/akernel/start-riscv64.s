.section .text.start, "ax"
.global _start
.type _start, @function
_start:
    call main
1:
    li a7, 0               /* yield */
    ecall
    j 1b
.size _start, . - _start
