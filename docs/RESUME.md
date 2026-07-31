# Resume prompt (next session)

```text
Read docs/STATE.md, docs/NEXT.md, docs/IPC.md. Implement milestone 11:
file protocol (9P-ish) over streams — a server exposing initrd files
(open/read/close RPCs), boot files as memory objects, bulk transfer
beyond the 40-byte stream chunk (shared memory-object frames in the
IPC cap slots). Otherwise pick from NEXT.md's later list
(notifications, line-atomic console, SMP, DTB, IOMMU).

Milestone 10 landed: custom userspace s-memory.adb overrides the
light runtime bump allocator — free-list heap at VA 0x4000_0000
(below text at 0x4600_0000), 8-byte size/flag headers, first-fit +
split + coalesce, grown via mem_alloc(64 pages)/mem_map page-by-page
(borrowed frames), 8 chunks = 2 MiB cap, Storage_Error past that.
Gotchas discovered: heap state must live in .bss with lazy init
(adainit never runs — _start calls main directly); s-memory.adb is
only compiled when in the program's dependency closure (forced via
private with System.Memory on the Akernel_User root spec, pragma
Pure dropped); s-memory.adb must NOT with Akernel_User.Syscalls
(binder circularity via pragma Elaborate_Body) — it imports the raw
asm syscall symbols directly; free-list next pointer lives at block
payload (after the 8-byte header), never at the header word; light
runtime = No_Exception_Propagation, so no exception-based tests.
58/58 directed PASS (heap new/free/churn/cross-object growth/
near-limit fill), fuzz failures=0.

Build/run: make all && make run. Commit per milestone; docs
current-state only.
```
