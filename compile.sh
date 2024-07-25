#!/bin/bash
aarch64-elf-gnatmake -o akernel.elf --RTS=/home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/aarch64-elf/lib/gnat/embedded-rpi3 src/akernel.adb
