# Resume prompt (next session)

```text
Read docs/NEXT.md first — it holds the full milestone log
(including per-milestone gotchas burned) and the deferred list.
docs/STATE.md has the current system shape, docs/IPC.md the
kernel/userspace protocol designs.

Open candidates: partition enumeration/query op + per-partition
raw VFS volumes + MBR fallback (21 remainder), block device
caches + explicit sync op/ecall, SMP hardening, IOMMU, kernel
introspection syscalls, plain send, register fast path.

Recently landed: SMP1 speedup — quantum 100 -> 50 ms, syscall 27
cpu_count (first introspection syscall, Kernel.CPUs.Count),
Tests/Spin skips itself on UP ("spin skipped (UP)" + exit):
full fuzz suite 474 s -> 3.3 s at QEMU_SMP=1, now matching SMP4.
Before that: FAT32 write path complete (20b: writes, subdirs,
LFN reads; 20c: delete/truncate/mkdir/rmdir, LFN creation via
numeric-tail alias, fixed timestamps) and the GPT partition
layer (21: System/Partmgr between virtio-blk and fs drivers,
badge-selected partition, superfloppy fallback). 158/158
directed PASS at QEMU_SMP 1/4/8, fuzz failures=0, host fsck.fat
clean.

Working rules burned in (details in NEXT.md):
- Commit per milestone; docs current-state only.
- Fuzz tests must be idempotent across reused disk images;
  validate driver writes with host fsck.fat on the extracted
  partition.
- Every op that transfers a buffer cap must cap_delete its copy
  per op at every layer or cap-table slots leak.
- QEMU_SMP=4 is a fine iteration config; SMP1 is no longer slow
  (Spin self-skips on UP).
- kill stray qemu-system-riscv64 before rerunning — it holds the
  disk.img lock.

Build/run: make all && make run (QEMU_SMP=1|4|8).
```
