# Resume prompt (next session)

```text
Read docs/NEXT.md first — it holds the full milestone log
(including per-milestone gotchas burned) and the deferred list.
docs/STATE.md has the current system shape, docs/IPC.md the
kernel/userspace protocol designs.

Open candidates: the deferred list:
kernel introspection syscalls
for init state reconstruction, plain send, register fast path,
virtio-net, MSI-X for virtio-pci (INTx shared chains today),
write-back cache policy + VIRTIO_BLK_F_FLUSH when more
filesystems appear, true scheduler priorities (wakeup boost
covers the IPC case), endpoint-teardown failing of queued
callers (a shell whose terminal closes stays blocked in its
read call — inert but unkillable).

Recently landed: MILESTONE 32 COMPLETE — window close +
C:Dir. The left title-bar gadget is close: Bureau enqueues
CLOSEWINDOW (v3 queue kind 3); terminal/demo Surface_Destroy
+ exit (Bureau never kills the window). File protocol gains
Op_ReadDir (stateless per-index, path "" = volume root);
fat32 enumerates skipping deleted/LFN/label entries (LFN
supplies the name). New crate userspace/dir -> Sys:C/Dir —
user ruling: commands live in C/, Amiga-style; the shell
resolves bare names against the volume root then C/. Burn:
Resolve_Volume rejected volume-only names ("BD0:"), exactly
what readdir-of-root needs — relaxed. Verified live: close
clicks destroy windows; Sys:> Dir lists the volume (LFNs,
dir tags, sizes). Before that: cursor artifacting fix — Bureau paints now go
through Composite_Band (erase sprite before painting an
intersecting band, redraw after); the old re-save-after-paint
path polluted the under-rect with sprite pixels on partial
overlaps and ghosted arrows around updating windows. Makefile
gained QEMU_ARGS (default -nographic; QEMU_ARGS="-display
gtk" for interactive runs). Before that: pointer events to
focused clients — v3 queue
kind 2, packed content-relative value (x16|y16|buttons8),
delivered only inside window content, coalesced in place
(undrained newest pointer event overwritten; moves can't flood
the ring). Demo paints a tracking 5x5 marker (white = button0
held); verified live by screendump pixel check.

Before that: MILESTONE 31 COMPLETE (a+b) — interactive
shell + uniform program ABI. Every program spawned from Sys:
(Startup list or shell child) gets the same namespace: 1 =
console Send (badged), 2 = fs Send, 3 = Bureau svc Send; a
program is GUI only once it calls Surface_Create (the
OpenWindow analog). Spawn_Gui_Client and all special-case
grant ABIs are gone. The terminal (a console device, the CON:
analog — launching it starts System/Shell) runs on the uniform
ABI and runtime-creates + self-attaches its stream sink
endpoint (Op_Attach_Sink accepts any badge since 31b). Shell:
builtins help/version/exit, bare path = stage+spawn+reap-poll,
nests; children inherit all three caps — "System/Demo" typed
at the Sys:> prompt opens its window (verified live). Line
discipline (echo, BS) lives in the terminal, never the shell. Boot mirror + shell share the
pane via the same sink endpoint, badge-multiplexed. Input
became ASYNC first — window protocol v3: per-window one-page
event queue memobj + thread-bound notification pushed at
Surface_Create; Bureau enqueues focused keys + signals, NEVER
calls the client. Burns: (1) v2's blocking key forward
deadlocked A<->B against client Surface_Update calls, and the
wedge CASCADED through the console-server sink RPC into a
system-wide output freeze (fuzz "froze" — it was the mirror);
(2) Notification_Full_Rights lacked Transfer — ntfn caps could
never cross a message; (3) LATENT: the notification cap-close
hook UNBOUND the thread on any cap_delete of a minted copy —
unbind is thread-lifetime, now gated on Thread_Dying (only
Discard_Slot sets it). Verified live: click-focus terminal,
sendkey help/version/System/Shell — echo, help text, nested
shell, all screendump-verified. 174 PASS SMP1+SMP4, fuzz
failures=0, host fsck clean. Before that: MILESTONE 30
COMPLETE — multi-window + focus: window protocol v2 (4 slots,
per-window geometry + input EP at Surface_Create cap slot 0 +
Op_Set_Title=25, real Destroy), Bureau z-order band compositor
(all drawing clipped to the damage band), click-to-focus/raise,
title-bar dragging, Demo second client (Sys:System/Demo,
generic GUI grant ABI 1=Bureau svc / 2=sink Receive / 3=sink
Send). Burns: 29b left nothing rebuilding bureau/terminal
(disk.img depended on rule-less ELF files -> stale v1 Bureau
booted); phony disk.img deps rebuilt onto the existing GPT
(recipe now rm -f's); terminal requests 87x29 cells explicitly
(v2 clamps to screen bounds, 1024x768 exceeds the 8-chunk cap);
Ada declaration-order again for the drag state. Before that:
MILESTONE 29 COMPLETE — boot from the Sys filesystem: FAT32
partition is BD0/Sys (raw whole-device volume moved to
WD0:disk after a device-name collision hung the boot; raw
partitions stay PD0); disk.img carries :System/Bureau +
:System/Terminal + :System/Startup (one path per line); devmgr
records GPU_Svc at class-16 and init calls Start_Display after
the mounts — images staged via the file server into memory
objects and spawned from the object caps (memstage pattern, no
kernel work), same grant layout, staging cap deleted;
Bureau/Terminal removed from the initrd (cpio 812 -> 717 KiB).
Burned: init ran on ONE 4 KiB stack page — Start_Display
overflowed it (store fault at stack_base - 8); init now gets
4 stack pages like spawned processes, big buffers
library-level.

Working rules burned in (details in NEXT.md):
- Commit per milestone; docs current-state only.
- Fuzz tests must be idempotent across reused disk images;
  validate driver writes with host fsck.fat on the extracted
  partition.
- Every op that transfers a buffer cap must cap_delete its copy
  per op at every layer or cap-table slots leak.
- Servers must never call back into a caller while serving it
  (rendezvous A<->B deadlock; the wedge cascades through sink
  RPCs). Async channels = shared-memory queue + notification,
  drained outside any rendezvous.
- A cap handed over in a message must carry the Transfer right;
  minted copies are cap_delete'd after the transfer — and
  cap-close hooks must not assume thread death (Thread_Dying).
- QEMU_SMP=4 is a fine iteration config; SMP1 is no longer slow
  (wakeup boost keeps rendezvous handoffs ahead of Spin's hog).
- Kill stray qemu-system-riscv64 before rerunning — it holds the
  disk.img lock. Use pkill -f "[q]emu-system-riscv64" (bracket
  form; a self-matching pattern kills the invoking shell).
- QMP input-send-event for absolute pointer (HMP mouse_move
  sends nothing to the virtio tablet); run target exposes
  -qmp unix:/tmp/qqmp.sock + -monitor unix:/tmp/qmon.sock.
  HMP sendkey needs shift- prefixes for capitals/symbols
  (shift-s, shift-;). Pixels are B8G8R8A8 = LE u32 AARRGGBB;
  decode screendump PPM bytes straight (R,G,B); trust the
  user's eyes over a decoder script.

Build/run: make all && make run (QEMU_SMP=1|4|8); disk.img is a
'run' dep (not in 'all'). qemu runs with -machine
virt,iommu-sys=on and virtio-pci devices.
```
