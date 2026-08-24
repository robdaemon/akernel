.section .text.user, "ax"

/* Generic syscall stub for fuzzing:
   fuzz_ecall(num, a0, a1, a2, a3, a4, a5) -> a0
   Post-ecall a1 is captured into fuzz_last_a1 (spawn cap out). */
.global fuzz_ecall
.type fuzz_ecall, @function
fuzz_ecall:
    mv t0, a0
    mv a0, a1
    mv a1, a2
    mv a2, a3
    mv a3, a4
    mv a4, a5
    mv a5, a6
    mv a7, t0
    ecall
    la t0, fuzz_last_a1
    sd a1, 0(t0)
    ret
.size fuzz_ecall, . - fuzz_ecall

.section .data
.align 8
.global fuzz_last_a1
.type fuzz_last_a1, @object
fuzz_last_a1:
    .dword 0
.size fuzz_last_a1, . - fuzz_last_a1

.section .note.GNU-stack, "", @progbits
