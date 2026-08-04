# Resume prompt (next session)

```text
Read docs/NEXT.md first — it holds the full milestone log
(including per-milestone gotchas burned) and the deferred list.
docs/STATE.md has the current system shape, docs/IPC.md the
kernel/userspace protocol designs.

Open candidates: block device caches + explicit sync op/ecall
(next up — agreed order), SMP hardening, IOMMU, kernel
introspection syscalls for init state reconstruction, plain
send, register fast path.

Recently landed: partmgr 21 remainder — MBR read fallback,
part_query op (slot -> first/size/count), per-partition raw PDn
VFS volumes, and syscall 28 cap_mint (attenuate + badge a cap in
the caller's own table; a cap transferred in a message must
carry the Transfer right — a Send-only mint rolled back the
rendezvous with Transfer_Failed). Before that: SMP1 speedup
(quantum 50 ms, syscall 27 cpu_count, UP-aware Spin; fuzz suite
474 s -> 3.3 s at QEMU_SMP=1), FAT32 write path complete (20b +
20c), GPT partition layer (21). 163/163 directed PASS at
QEMU_SMP 1/4/8, fuzz failures=0, host fsck.fat clean.

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
