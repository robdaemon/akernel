# Resume prompt (next session)

```text
Read docs/NEXT.md first — it holds the full milestone log
(including per-milestone gotchas burned) and the deferred list.
docs/STATE.md has the current system shape, docs/IPC.md the
kernel/userspace protocol designs.

Open candidates: kernel introspection syscalls for init state
reconstruction, plain send, register fast path, IOMMU, virtio-net,
write-back cache policy + device-level cache + real flush
(VIRTIO_BLK_F_FLUSH) when more filesystems appear, true scheduler
priorities (wakeup boost covers the IPC case).

Recently landed: scheduler wakeup boost — a thread woken by
IPC/notification re-enters at the FRONT of the ready queue (TCB
Boosted flag cleared on every block path); Spin's UP self-skip
removed, it now spins forever on all configs as the boost
regression canary, and the SMP1 suite completes in ~21 s wall
with the hog running (was 474 s pre-boost; residual is fair
50/50 in the syscall-only random phase). Burned: boost must be
"run promptly once after wake", never a persistent priority
(permanent boost starved init at boot); fuzz now awaits async
volume mounts (latent boot race). Before that: FAT32 metadata
cache + Op_Sync (22), partmgr 21 remainder (MBR, part_query,
PDn volumes, cap_mint), SMP1 speedup (50 ms quantum, cpu_count),
FAT32 write path (20b+20c), GPT layer (21). 167/167 directed
PASS at QEMU_SMP 1/4/8, fuzz failures=0, host fsck.fat clean.

Working rules burned in (details in NEXT.md):
- Commit per milestone; docs current-state only.
- Fuzz tests must be idempotent across reused disk images;
  validate driver writes with host fsck.fat on the extracted
  partition.
- Every op that transfers a buffer cap must cap_delete its copy
  per op at every layer or cap-table slots leak.
- QEMU_SMP=4 is a fine iteration config; SMP1 is no longer slow
  (wakeup boost keeps rendezvous handoffs ahead of Spin's hog).
- kill stray qemu-system-riscv64 before rerunning — it holds the
  disk.img lock.

Build/run: make all && make run (QEMU_SMP=1|4|8).
```
