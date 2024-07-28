#!/bin/bash
qemu-system-aarch64 -M raspi3b -m 1G -kernel bin/akernel.elf -serial null -serial mon:stdio -nographic $*
