# Resume prompt (next session)

```text
Read docs/NEXT.md first — it holds the full milestone log
(including per-milestone gotchas burned) and the deferred list.
docs/STATE.md has the current system shape, docs/IPC.md the
kernel/userspace protocol designs.

Open candidates: kernel introspection syscalls for init state
reconstruction, plain send, register fast path, virtio-net,
virtio-input (keyboard/tablet for interactivity — PCI transport
is in), MSI-X for virtio-pci, write-back cache policy +
device-level cache + real flush (VIRTIO_BLK_F_FLUSH) when more
filesystems appear, true scheduler priorities (wakeup boost
covers the IPC case).

Recently landed: riscv-iommu + DMA isolation (25) — Arch.IOMMU
kernel driver (3-level DDT, per-device Sv39 IO page tables,
IOVA = PA identity), mem_object_pa is the DMA authorization
point (io_map gained a Device_Id arg; only frames explicitly
exposed by a thread holding an attributed MMIO cap are reachable
by that device, everything else faults into the PLIC-wired fault
queue); memory-object finalizers tear mappings down via
per-object device backlinks; boot self-test probes translations
through the DBG TR_REQ registers. Before that: PCI virtio
transport (24) — drivers moved off virtio-mmio onto virtio-pci
(rng addr=0x3, blk addr=0x4, INTx) because qemu's riscv-iommu
translates PCI DMA only; devmgr scans bus 0 (per-function 4 KiB
io_map probe windows, 64-page io_map cap), assigns BARs itself
(no firmware PCI init on riscv virt), discovers virtio regions
from the vendor capability list, pushes a driver-config first
message (notify_off_multiplier, IRQ source, requester id) on the
service endpoint. Burned: transitional PCI ids are a legacy
table (rng = 0x1005, 0x1004 = legacy SCSI), NOT 0x1000+virtio_id
— devmgr normalizes both id spaces to the virtio id carried in
the line's class field. 167/167 directed PASS at QEMU_SMP
1/4/8, fuzz failures=0, host fsck.fat clean.

Working rules burned in (details in NEXT.md):
- Commit per milestone; docs current-state only.
- Fuzz tests must be idempotent across reused disk images;
  validate driver writes with host fsck.fat on the extracted
  partition.
- Every op that transfers a buffer cap must cap_delete its copy
  per op at every layer or cap-table slots leak.
- QEMU_SMP=4 is a fine iteration config; SMP1 is no longer slow
  (wakeup boost keeps rendezvous handoffs ahead of Spin's hog).
- Kill stray qemu-system-riscv64 before rerunning — it holds the
  disk.img lock. Use pkill -x or a pattern that does not match
  the invoking shell's own command line.

Build/run: make all && make run (QEMU_SMP=1|4|8); qemu runs with
-machine virt,iommu-sys=on and virtio-pci devices.
```
