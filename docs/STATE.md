# akernel project state

Thin orientation only. Details live in topic docs; read the one matching
your task instead of everything.

- `docs/NEXT.md` — current work queue (read this first)
- `docs/IPC.md` — agreed IPC/namespace/spawn-v2 design
- `docs/ARCH_RISCV64.md` — boot, MMU/address spaces, trap/syscall path, devices
- `docs/KERNEL.md` — PMM, initrd, ELF, caps, tasks, scheduler, objects, processes
- `docs/USERSPACE.md` — syscall ABI, RTS scaffold, init, drivers, fuzzer, manifest

## Goal

Ada bare-metal microkernel for hobby OS. Initial target: RISC-V64 QEMU
`virt` under OpenSBI in S-mode. Long-term: multiple architectures/boards,
user-mode drivers, capability-based resource management, initrd-loaded
userspace, per-process namespaces (Plan 9 influence), custom Ada RTS.

## Workflow rules

- Git commit between each completed step. Do not batch multiple completed
  steps without committing.
- Keep docs current-state only; no changelog narrative in STATE/topic docs.

## Build/run

```sh
make all
make run        # qemu-system-riscv64 -machine virt -kernel bin/akernel.elf \
                #   -device loader,file=initrd/out/akernel-initrd.img,addr=0x84000000
make clean
make run QEMU_MEMORY=8G QEMU_SMP=4 INITRD_ADDR=0x84000000   # knobs
```

## Current successful boot output

```text
Hello world!
kernel address space online
memory manager online
ram MiB: 4096
dtb devices online
pmm selftest online
cap table online
objects selftest online
ipc online
bootinfo online
iommu caps 0x...
iommu online, irq 0x24
iommu context online for device 0xf8   (self-test scratch id)
iommu fault ...                        (self-test induced, x2)
iommu selftest online
entering initrd init
init online from Ada
boot manifest visible
launching manifest programs
devmgr: spawned Drivers/Serial
console server online
devmgr: spawned Drivers/VirtioRng
devmgr: spawned Drivers/VirtioBlk
devmgr: spawned Drivers/VirtioInput   (keyboard instance)
devmgr: spawned Drivers/VirtioInput   (tablet instance)
devmgr: spawned Drivers/VirtioGpu
(virtio driver self-tests)
virtio-gpu console online   (console server mirrors lines to it)
fileserver spawned
fileserver online
fs name table pushed
fuzz spawned
program spawned
partmgr gpt online
fat32 online
init resumed
fuzz online          (via console server endpoint stream)
spin online          (via console server)
timer interrupt online
... 171/171 directed PASS (console stream RPC, echo IPC rounds,
grants, memory objects, RTS heap, file protocol + volumes,
spawn-from-memory-object, notifications, block volume, cap_delete,
FAT32 reads + writes + delete/truncate/mkdir/rmdir/LFN through the
VFS, partition query + per-partition raw volumes, fs sync,
virtio-input keyboard/tablet config, virtio-gpu display bring-up)
...
fuzz complete: calls=0x0000000000001000 unknowns=0x0000000000000155 failures=0x0000000000000000
fuzz exit test
```

Normal programs print through the console server (endpoint stream);
init and the kernel still use debug_putchar, as does the fuzzer's
random phase (printable garbage in the log is that fuzz traffic).

## Repository layout

```text
src/kernel/                     kernel-neutral code
src/arch/riscv64/               RISC-V64 arch code
src/board/qemu_virt_riscv64/    QEMU virt board/platform code
userspace/rts/akernel/          user-mode Ada syscall/RTS scaffold
userspace/init|serial|fuzz/     standalone Alire projects
userspace/virtio/               virtio lib crate (MMIO + PCI transports, virtqueues)
userspace/virtio_rng/           virtio-rng driver (pins the lib)
initrd/                         generated initrd root/output
tools/mkinitrd.py               wraps cpio in AKRD header
docs/                           this file + topic docs
Makefile                        top-level build/run
```

`akernel.gpr` vars: `AKERNEL_ARCH` (riscv64), `AKERNEL_BOARD`
(qemu_virt_riscv64).

## Important constants

```text
kernel link/load:       0x80200000
kernel VMA base:        0xFFFFFFFF80200000
physmap base:           0xFFFFFFC000000000
initrd load PA:         0x84000000
user stack top:         0x70000000
IPC buffer VA (design): 0x6FFF0000
bootinfo page VA:       0x6FFE0000
user VA range:          0x40000000..0x80000000
newlib _sbrk arena:     0x52000000 (53b; 16 x 256 KiB memobj chunks)
53c: env=ENV: files; argv=args page (crt0->gnat_argv);
     dirs=Op_ReadDir; cwd=ENV:CWD; relative gloss paths qualify
     Amiga-style; Dir_Seps includes : (a-direct patch)
UART PA:                0x10000000
PLIC PA:                0x0c000000
PLIC UART source:       10
QEMU virt RAM base:     0x80000000
```

## Current limitations

- Preemptive scheduler (50 ms user-thread timeslice) with wakeup
  boost: a thread woken by IPC/notification re-enters at the FRONT
  of the ready queue (boost flag cleared on every block path), so
  rendezvous handoffs never wait behind a CPU hog; kernel itself
  serialized by a big kernel lock (SMP: all harts run user code in
  parallel, kernel execution single-file; shared ready queue + IPI
  wakeup); process table 128 slots with an O(1) free
  list, 144 task slots. Capability tables are PAGED:
  16384 handles per process, 128-entry root per PCB,
  128-cap pages PMM-allocated on demand via physmap and
  freed at last close/teardown; Cap_Entry layout forced
  to 32 bytes by rep/size clause. Kernel boot-file
  table holds 256 initrd files; the init bootinfo
  region grows to 8 contiguously-mapped pages on
  demand (511 entries); spawned user threads get 12
  stack pages (48 KiB, milestone 53a: the ZCX unwinder
  needs ~8 KiB on the first raise) mapped User_RWX —
  executable because GNAT finalization lowers
  Finalize_Address of nested FD procedures to GCC
  stack trampolines (static chain in t2). Boot-file caps reach the file
  server TRANSFERRED with their Op_Set_Name messages
  (spawn grant lists cap at 32); the file server maps
  boot files on demand into one shared 256 KiB window
  (no per-file VA), 512 name slots. Introspection is
  admin-gated by capability, not by any user model:
  init holds the boot's only Admin_Object cap
  (bootinfo "admin"); Sys_Process_Info (device_resource
  gate), Sys_Cap_Info + Sys_Thread_Regs (admin gate)
  write physmap snapshots; Proc: renders them as
  <pid>/status, <pid>/caps, <pid>/regs. Userspace
  builds on ONE RTS static library
  (userspace/rts/akernel_rts.gpr, layers: glue /
  kernel ABI / service APIs) plus the Akernel_User.CLI
  command layer (args, ENV:, Amiga RC 0/5/10/20 via
  the exit-code channel exit-a0 -> PCB -> reap-a1);
  new commands scaffold with make new-crate.
- Spawn ABI v2: images are `Boot_File_Object` caps (grant lists in
  spawner's IPC buffer, rights-subset enforced); init discovers its
  caps by name in the read-only bootinfo page. Boot byte API is
  cap-based; memory objects (alloc/map/unmap, borrowed mappings,
  refcounted PMM frames) exist but boot files are not memory objects
  yet.
- No full custom GNAT RTS (light runtime +
  stubs); initrd load address fixed.
- UART/PLIC bases and the UART IRQ source come from DTB discovery
  (board constants as fallback); the kernel keeps only its own
  polled console on that UART. All device runtime objects — the
  UART included — are enumerated by init's device manager from the
  DTB (exposed as the "dtb" boot file) and the System/Drivers
  database, with per-instance MMIO/IRQ caps minted via
  io_map/irq_create (device_resource authority). Drivers/Serial is
  an ordinary spawned driver (class 0: console endpoint Receive);
  virtio devices run as user-mode drivers over virtio-pci
  (devmgr-scanned bus 0, devmgr-assigned BARs, per-region caps from
  the vendor capability list, INTx via the host interrupt-map;
  virtio-rng live; virtio-blk live with a block-backed BD0 raw
  volume; virtio-input live — keyboard + tablet feed the seat:
  events go to the Bureau compositor (Op_Key/Op_Pointer), which
  enqueues focused keys AND pointer state (packed
  content-relative, coalesced) into each window's async input
  queue
  (window protocol v3: one-page event ring memobj + thread-bound
  notification per surface, pushed at Surface_Create; Bureau
  never calls its clients; v4 adds pointer capture — a content
  press captures the pointer until release, moves clamped to
  the content rect, release always delivered) and owns pointer
  focus/raise/drag;
  virtio-gpu live — the console
  server mirrors its line-atomic output to the display over
  stream-protocol sink endpoints (Op_Attach_Sink, devmgr-wired),
  serial stays as the debug/logging copy). Trinket (milestone
  56/57) is the opt-in static widget library (libtrinket.a):
  retained tagged-type tree, client-side rendering into Bureau
  surfaces, WB3.1 double-ridge look, BDF fonts from Sys:Fonts/
  with a compiled-in Font8x8 fallback; widgets: Group (H/V
  layout + titled frame), Label, Button, Scrollbar (arrows,
  track paging, striped knob drag via v4 capture), Text_Edit
  (512x128 heap model, cursor, drag-select, full nav-key
  editing, scrolling), Listview (58). Sys:System/Tdemo demos
  it; Sys:System/
  Edit is a real text editor on it (Text_IO load/save, Save/
  Quit buttons, wired scrollbar); Sys:System/Fileman is the
  file manager (Listview + Scrollbar). Tier-1 Amiga-style
  shared libraries (58) ride the same uniform ABI: a library
  is a server program installed at Sys:Libs/<Name>,
  Akernel_User.Libs.Open_Library stages+spawns it on demand
  and collects its service cap over a rendezvous cap at
  handle 5 (Send+Receive+Transfer), Close_Library deletes
  the cap; Libserv carries the server boilerplate (wire
  convention in docs/IPC.md). Nav keys travel as codes
  16#80#..16#88#; text consumers drop codes >= 128. The
  Bureau also owns the Amiga screen-bar
  menus since 61: clients declare a tree (Op_Set_Menus,
  copied into Bureau), RMB opens the focused window's bar
  (sticky after release; hover drops/switches, left-click
  picks, off-click/RMB/Esc dismisses; kind-4 pick events),
  and the bar carries an RTC clock by the depth gadget.
  Edit has File>Save/Quit via Trinket.Menus. The
  terminal is a
  console device (CON: analog) in a Bureau window, rendered
  via Trinket since 58 (Terminal_Buffer circular scrollback
  + right-edge scrollbar + block cursor, PgUp/PgDn/Home/End
  + pointer scrolling) with Amiga-style command history
  since 60: cursor Up/Down recall a 32-entry ring by
  injecting BS+entry bytes into the Op_Read FIFO (the shell
  stays in sync untouched); Down past newest restores the
  stashed line. It echoes
  focused keys into its scrollback, serves Op_Read from its input
  FIFO, and launches System/Shell from the Sys volume (plain CLI
  program on its stream endpoint; builtins + spawn-and-await of
  FS-resident programs, nestable; bare command names resolve
  against the volume root then C/ — Sys:C/Dir lists a directory
  via the file protocol's Op_ReadDir; C/ also holds Type, Copy,
  Delete, Rename, Makedir, Info (milestone 41a — Op_Rename +
  Op_Volume_Info behind Rename/Info; commands are CLI-package
  programs with Amiga exit codes), the session/vars commands
  Set/Get/Unset/Assign plus Echo, Which, Version, Fault
  (41b — the shell thins to help/exit; CLI.Resolve_Command
  shares the Path search with Which), and the data commands
  Join, Search, Sort, List (41c), and CD (42 — the
  cwd is ENV:CWD, global so a child CD moves the
  parent's session; relative args resolve through
  CLI.Resolve_Path everywhere, "/" is the Amiga
  parent idiom, no dot components). C:Date and
  C:Wait (59) ride the goldfish RTC behind
  Sys_Read_Clock (34): gettimeofday, FAT dirent
  stamps (Op_Stat reply words 2/3, surfaced by
  List) and Ada.Calendar all carry real wall time.
  The shell
  prompt shows the cwd and "execute <script>
  [args]" runs scripts (';' comments, failat
  stop at RC >= 10, nesting cap 4; "Shell
  execute <script>" args = batch mode exiting
  with the last RC). Milestone 70 grew the
  runner into an AmigaDOS subset
  (Scripting.Interp, userspace/scripting —
  shared with the execution engine,
  Scripting.Exec, which the shell and
  C:Execute both link): .key/.k positional
  args with .def defaults, .set script locals
  (defined-empty vs undefined), <name>
  substitution resolving locals then ENV:
  (<$name> forces ENV:; undefined is a hard
  "bad substitution" error), if [not] with
  exists / eq|ne|gt|ge|lt|le [val] / command
  forms (the condition RC is consumed), bare
  if testing the condition flag, else/endif
  (8 deep, skipped blocks never expanded),
  lab/skip [back] (skip abandons open if
  frames — the loop idiom relies on it),
  quit [rc], failat <n>, echo [noline]
  (metachar lines fall through to C:Echo so
  redirection composes), and ask (condition
  flag from y/Y; RC_Warn 5 on "no" — below
  failat). C:Execute is the command form:
  programs run scripts without a shell, and
  "run Sys:C/Execute s" backgrounds a script
  as a reapable job; its ask reads stdin, so
  "echo y | Execute s" composes. C:Path (43) manages the command
  search list — ENV:Path, global (Amiga is
  per-process; no session identity here) —
  with Resolve_Command searching cwd FIRST,
  then Path entries (they replace only the
  built-in root+C: tail), else root+C:;
  Which shares the same resolver. Since 44 no
  CLI program binds a default volume: paths
  are cwd-resolved and fully qualified in
  Akernel_User.CLI (the sole boot-volume
  owner) before reaching the file server;
  bare Dir lists the cwd. Milestone 45 adds
  elevation: System/Elevated holds the admin
  cap and mints Manage-only copies into
  children it stages+spawns for
  Sys:C/Elevate (allow+log policy; the admin
  cap never enters the client namespace —
  protocol in IPC.md "Elevation"). The
  uniform command ABI is now: 1 console,
  2 fs, 3 bureau, 4 args page (always), 5
  elevation svc. Milestone 48 made the
  block layer write-back: virtio-blk
  absorbs writes into a 64-slot cache,
  flushes on eviction / idle
  write-behind / Blk_Flush=4 (driven by
  fat32 Op_Sync via partmgr), and
  negotiates VIRTIO_BLK_F_FLUSH.
  Milestone 52 added shell job
  control (run/jobs/wait, Done-state
  exit codes, orphan abandonment).
  Milestone 51 added pid generations
  (pid = gen*256 + slot base; slot
  reuse never reissues a pid).
  Milestone 50 shipped clean shutdown:
  Sys_System_Reset (admin-gated) ->
  SBI SRST; System/Shutdown +
  System/Reboot under Elevate sync all
  volumes then reset; the suite powers
  qemu off itself (exit 0) every run.
  Milestone 49 made PIPE: blocking:
  empty-ring reads and no-room writes
  defer their replies (m47 reply-cap
  duplication) in an 8-slot pending
  table drained on ring mutations;
  Op_Close wakes readers (EOF),
  Op_Delete wakes all Not_Found.
  Milestone 47 duplicated
  the reply cap: recv mints one ordinary
  free-slot reply cap per call (handle in
  a1) and reply(handle) consumes it —
  servers hold many outstanding replies
  and may defer/reorder them (the
  blocking-pipe primitive). Milestone 46
  adds Amiga
  pipes: PIPE: and NIL: are fileserver-
  internal virtual volumes (FIFO rings,
  poll semantics, Op_Close EOF), and the
  shell runs `A | B` pipelines + `>`/`<`
  redirection through an args-page
  trailer the RTS reads (Console output
  and CLI.Get_Line input route through fs
  paths; Sort is the stdin filter).
  Windows
  close via the
  title-bar close gadget (Bureau posts CLOSEWINDOW into the
  window's input queue; the client destroys its surface and
  exits). Every program spawned from
  Sys: (Startup list or shell child) gets the same namespace —
  1 = console Send (badged), 2 = fs Send, 3 = Bureau svc Send;
  a program is GUI only once it calls Surface_Create. The block
  stack is driver -> partition -> filesystem: System/Partmgr
  probes GPT (MBR primary entries as fallback, slot 0 = whole
  disk without either) and serves block protocol with
  badge-selected partition offset translation, zero-copy cap
  forwarding, plus a part_query op (slot -> first LBA / size /
  populated count); init enumerates the slots and mounts each as
  a raw PDN volume on the VFS (Op_Add_Block with a cap_mint'd
  partN-badged cap). System/Fat32 serves
  partition 1 of the GPT disk as HD0/AKDISK (reads + writes:
  subdirectory traversal, LFN matching, file create (8.3 or
  LFN + numeric-tail alias), cluster chain extension with
  mirrored FAT + FSInfo updates, delete/truncate/mkdir/rmdir
  (Op 8..11), fixed dirent timestamps; no sparse writes), over
  an 8-slot write-through metadata sector cache (FAT/dir/
  FSInfo; file data bypasses) — Op_Sync = 12 is a write-through
  no-op passthrough today, flush hook for later. The
  file server is a VFS in front, forwarding verbatim with
  per-op buffer caps cap_delete'd at every layer, and holds
  the session assign table (milestone 36: Op_Assign = 14 /
  Op_Assign_List = 15 — Amiga-style path aliases resolved
  when volume lookup fails, target substituted + resolution
  retried depth-capped; mounting the sys-labelled volume
  seeds C: and ENV:). System/Procfs serves the Proc:
  introspection volume over the same FS-driver path
  (milestone 37b): stat/open/read/readdir rendered fresh
  from process_info snapshots — "" lists "tree" + pid
  dirs, "tree" is the process forest indented by
  spawner, "<pid>/status" one snapshot as key-value
  lines; read-only.
- DMA isolation: riscv-iommu (Arch.IOMMU, qemu
  -machine iommu-sys=on) translates all PCI DMA through a 3-level
  DDT + per-device Sv39 IO page tables; IOVA = PA identity
  mappings exist only for memory-object frames explicitly exposed
  via mem_object_pa by a thread holding an MMIO cap attributed to
  that PCI requester id (io_map Device_Id argument). Everything
  else faults into the fault queue (PLIC-wired, kernel handler
  logs cause/did/iova); mappings are torn down by the memory
  object's finalizer.
- The PMM honors reserved ranges (initrd, DTB); mem_object_pa
  exposes memory-object frame PAs for DMA; spawned processes get
  4 user stack pages.
- Process introspection: process_info (syscall 30) snapshots one
  process (ids incl. spawner, lifecycle/thread state, cap count,
  IPC flags, blocked-on endpoint, call badge) into a caller
  memobj; gated by the device_resource Kernel_Object+Manage cap,
  granted down from init (basis for a userspace Proc: volume).
