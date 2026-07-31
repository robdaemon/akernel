# Resume prompt (next session)

```text
Read docs/STATE.md, docs/NEXT.md, docs/IPC.md. Implement milestone 12:
spawn v2 completion — spawn from a Memory_Object cap holding an ELF
staged by the file server (fuzz test: read Tests/Spin via fs, spawn it
from the memory object, reap); then notification objects for
IRQ-driven UART RX if scope allows. Otherwise pick from NEXT.md's
later list (line-atomic console, SMP, DTB, IOMMU).

Milestone 11 landed: file protocol (9P-ish) over endpoint RPC.
System/Fileserver (new userspace program) holds all boot-file caps
(boot_files manifest token, handles 3..N) + fs endpoint Receive
(handle 1); init pushes the (handle -> name) table as Op_Set_Name
messages after spawn, then a zero-handle terminator. Kernel mem_map
now accepts Boot_File_Object caps: borrowed read-only initrd frames,
extent = ceil((lead-in + length)/4096) pages, lead-in byte offset
returned in a1. Userspace: Akernel_User.Files client
(Bind/Stat/Open/Read), stateless reads, client-owned 8-page buffer
memory object at VA 0x4400_0000 transferred per Read call (replies
cannot carry caps — reply path zeroes cap slots). Server maps boot
files RO into per-file windows at 0x4400_0000 + slot*256KB and the
client buffer at 0x4420_0000. Manifest: program 2 System/Fileserver
fs_server console boot_files; fuzz gains fs (handle 4) and
System/Manifest (handle 5) grants; echo stays handle 3.
Gotcha burned once: asm syscall stubs and Ada imports must agree on
argument registers — Mem_Map_File has 6 Ada args (a0..a5) so the
akernel_sys_mem_map_file stub moves the delta pointer a5->a6 and
injects flags=1 (RO) itself; a stub expecting a6 while Ada passes 6
args reads garbage (crashed with a6=0x74). Debug method: kernel-side
trap-frame word dump (Words : array (0..33) of U64 with Address =>
Frame; a6 = word 15).
64/64 directed PASS, fuzz failures=0.

Build/run: make all && make run. Commit per milestone; docs
current-state only.
```
