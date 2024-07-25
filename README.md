# akernel

Simple Ada AArch64 kernel

## Building

Compile and install the [aarch64-elf GNAT toolchain](https://github.com/robdaemon/GNAT-FSF-builds) first.

Once that's in your `PATH`, you can generate a config:

```console
$ gprconfig --target=aarch64-elf
```

On my system, it shows several duplicates:

```console
gprconfig has found the following compilers on your PATH.
Only those matching the target and the selected compilers are displayed.
   1. GNAT for Ada in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1 (embedded-rpi3 runtime)
   2. GNAT for Ada in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1 (light-rpi3 runtime)
   3. GNAT for Ada in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1 (light-tasking-rpi3 runtime)
   4. GCC-ASM for Asm in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
   5. GCC-ASM for Asm in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
   6. GCC-ASM for Asm2 in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
   7. GCC-ASM for Asm2 in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
   8. GCC-ASM for Asm_Cpp in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
   9. GCC-ASM for Asm_Cpp in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
  10. LD for Bin_Img in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 2.42
  11. GCC for C in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
  12. GCC for C in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
Select or unselect the following compiler (or "s" to save):
```

Choose the toolchains (one at a time) until you have a list resembling:

```console
--------------------------------------------------
gprconfig has found the following compilers on your PATH.
Only those matching the target and the selected compilers are displayed.
*  2. GNAT for Ada in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1 (light-rpi3 runtime)
*  4. GCC-ASM for Asm in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
*  6. GCC-ASM for Asm2 in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
*  8. GCC-ASM for Asm_Cpp in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
* 10. LD for Bin_Img in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 2.42
* 11. GCC for C in /home/rroland/arm/gnat-aarch64-elf-linux64-14.1.0-2/bin/ version 14.1.0
Select or unselect the following compiler (or "s" to save):
```

Hit `s` to save, then you can build.

You will need [alire](https://alire.ada.dev/) at first:

```console
$ alr toolchain --select
```

You can choose the `gnat_native=14.1.3` toolchain, and `gprbuild=22.0.1` toolchains, but you won't actually
use them.

Run a build *once* so that it sets up the local config:

```console
$ alr build
$ alr clean
```

Now, you can do the real build:

```console
$ gprbuild --target=aarch64-elf
```

