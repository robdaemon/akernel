# Resume prompt (next session)

```text
Read docs/NEXT.md first — it holds the full milestone log
(including per-milestone gotchas burned) and the deferred list.
docs/STATE.md has the current system shape, docs/IPC.md the
kernel/userspace protocol designs.

Open candidates: SMP hardening, IOMMU, kernel introspection
syscalls for init state reconstruction, plain send, register fast
path, write-back cache policy + device-level cache + real flush
(VIRTIO_BLK_F_FLUSH) when more filesystems appear.

Recently landed: FAT32 metadata cache + sync op — 8-slot
write-through sector cache for FAT/dir/FSInfo in the fat32
driver (chain walks re-fetched one FAT sector per entry; file
data bypasses), every write refreshes cached copies from the
bounce (sole-writer invariant; do not raw-write a mounted
partition), Op_Sync = 12 no-op passthrough (flush hook for
later). SMP1 guest test window ~0.28 s. Before that: partmgr 21
remainder (MBR fallback, part_query, PDn raw volumes, syscall
28 cap_mint — message-transferred caps need the Transfer
right), SMP1 speedup (quantum 50 ms, syscall 27 cpu_count,
UP-aware Spin), FAT32 write path (20b + 20c), GPT partition
layer (21). 164/164 directed PASS at QEMU_SMP 1/4/8, fuzz
failures=0, host fsck.fat clean.

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
