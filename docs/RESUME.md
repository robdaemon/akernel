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

Recently landed: FAT32 write path complete (20b: writes, subdirs,
LFN reads; 20c: delete/truncate/mkdir/rmdir, LFN creation via
numeric-tail alias, fixed timestamps) and the GPT partition
layer (21: System/Partmgr between virtio-blk and fs drivers,
badge-selected partition, superfloppy fallback). 157/157
directed PASS at QEMU_SMP 1/4/8, fuzz failures=0, host fsck.fat
clean.

IN FLIGHT (agreed, not started): SMP1 speedup. Evidence:
timestamped runs — full fuzz suite 0.53s at SMP4 vs 474s at SMP1
(~900x). Cause: Tests/Spin's 100ms quantum alternates with every
rendezvous handoff on UP (~600ms per IPC round trip; BIG.BIN tail
read alone 65s via uncached FAT chain walk; random phase 23s with
no IPC at all = pure spin-theft). Plan: (1) preemption quantum
100 -> 50ms (src/arch/riscv64/arch-traps.adb Timer_Interval,
NOT 10ms — context-switch thrash risk); (2) syscall 27
cpu_count returning Kernel.CPUs.Count (first kernel-introspection
syscall); Tests/Spin prints "spin skipped (UP)" and exits when
count = 1 — cleaner than per-hart-count manifests; (3) fuzz
Highest_Known 22 -> 27 + directed test cpu_count >= 1. Then full
re-validation at QEMU_SMP 1/4/8 + fsck, commit.

Working rules burned in (details in NEXT.md):
- Commit per milestone; docs current-state only.
- Fuzz tests must be idempotent across reused disk images;
  validate driver writes with host fsck.fat on the extracted
  partition.
- Every op that transfers a buffer cap must cap_delete its copy
  per op at every layer or cap-table slots leak.
- QEMU_SMP=1 runs are slow (single hart, Tests/Spin shares it);
  use a long timeout. QEMU_SMP=4 is the fast iteration config.
- kill stray qemu-system-riscv64 before rerunning — it holds the
  disk.img lock.

Build/run: make all && make run (QEMU_SMP=1|4|8).
```
