# Resume prompt (next session)

```text
Read docs/STATE.md, docs/NEXT.md, docs/IPC.md. Implement milestone 10:
RTS heap on memory objects — real non-tasking runtime core (heap,
secondary stack) backed by mem_alloc/mem_map; then file protocol
(9P-ish) over streams if scope allows.

Milestone 9 landed: Kernel.Memory (refcounted slab + PMM frames,
1..64 zeroed pages/object), Memory_Object cap kind (rights
Map+Read+Write+Transfer+Manage at creation), syscalls 15 mem_alloc /
16 mem_map / 17 mem_unmap. Borrowed mappings marked with PTE RSW
bit 0 (PTE_Borrowed, arch-mmu): AS teardown and Unmap_Borrowed_Page
never free object frames; object finalizer returns frames to PMM on
last cap close. Unmap refuses AS-owned pages (Not_Mapped). Sv39
write-without-read rejected. RTS wrappers Mem_Alloc/Mem_Map/Mem_Unmap
in akernel_user-syscalls.*; fuzz directed cases cover alloc bounds,
map validation, touch (zeroed+writable), unmap rules. 54/54 directed
PASS, fuzz failures=0.

Key files: src/kernel/kernel-memory.*, src/arch/riscv64/arch-mmu.*
(Borrowed param on Map_Page, Unmap_Borrowed_Page), arch-traps.adb
(Handle_Mem_*), userspace/rts/akernel/akernel_user-syscalls.*.
Gotchas: fuzz Raw_Ecall has A0..A5 defaults, always named
association; console prints round-trip through the caller's IPC
message buffer (snapshot replies before printing).
Build/run: make all && make run. Commit per milestone; docs
current-state only.
```
