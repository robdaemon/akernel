.section .text.start, "ax"
.global _start
.type _start, @function
_start:
    .option push
    .option norelax
    lla gp, __global_pointer$
    .option pop
    call main
1:
    li a7, 0               /* yield */
    ecall
    j 1b
.size _start, . - _start
