.section .text.start, "ax"
.global _start
.type _start, @function
_start:
    .option push
    .option norelax
    lla gp, __global_pointer$
    .option pop
    call akernel_register_frames
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
