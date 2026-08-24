.section .text.start, "ax"
.global _start
.type _start, @function
_start:
    .option push
    .option norelax
    lla gp, __global_pointer$
    .option pop

    /*  TLS setup (milestone 66c).  The kernel sets tp for secondary
        threads before entry; the initial thread arrives with tp == 0
        and uses the static .tls_copy buffer.  In both cases crt0
        copies the .tdata template into the per-thread buffer and
        zeros .tbss. */
    bnez tp, 2f
    lla tp, __tls_start
2:
    /*  Copy .tdata template to tp. */
    lla t0, __tls_init_start
    lla t1, __tls_init_end
    mv  t2, tp
3:
    bgeu t0, t1, 4f
    ld   t3, 0(t0)
    sd   t3, 0(t2)
    addi t0, t0, 8
    addi t2, t2, 8
    j    3b
4:
    /*  Zero .tbss at tp + (__tls_bss_start - __tls_init_start). */
    lla t0, __tls_bss_start
    lla t1, __tls_bss_end
    lla t3, __tls_init_start
    sub  t2, t0, t3
    add  t2, tp, t2
5:
    bgeu t0, t1, 6f
    sd   zero, 0(t2)
    addi t0, t0, 8
    addi t2, t2, 8
    j    5b
6:
    call akernel_register_frames
    /*  53c: tokenize the args page into gnat_argc/gnat_argv (argv.c)
        for Ada.Command_Line. */
    call akernel_init_args
    /*  newlib (milestone 53b): run preinit/init arrays (and _init)
        before main so libc's constructor machinery is up. */
    call __libc_init_array
    call main
    /*  main returning = program done: exit with its status (a0)
        instead of parking in the old yield loop. */
    call akernel_sys_exit
1:
    j 1b
.size _start, . - _start

.section .note.GNU-stack, "", @progbits
