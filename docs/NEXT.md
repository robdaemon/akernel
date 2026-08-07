# Next step

Implement IPC per the agreed design in `docs/IPC.md` (read it first).
Design decisions locked: sync rendezvous, IPC buffer canonical ABI,
call/recv/reply trio with reply cap at handle 254, cap transfer in
messages, dynamic endpoints + object refcounting, namespace grant lists
at spawn, init as fatal-fault domain with authority concentrated in
kernel cap tables.

## Milestone order

1. ~~Object refcounting infra~~ — done: `Object_Header` +
   `Pinned_Refcount` in `Kernel.Objects`, endpoint `Retain`/`Release`,
   `Retain_Cap` in cap-insert wrappers, dispatcher releases once
   (caps closed at exit/reap cleanup).
2. ~~Dynamic endpoints~~ — done: `ep_create` (syscall 11) +
   RTS wrapper; PMM-backed slab pool (grows per frame, RAM-limited,
   free-list reuse, frames never returned); finalizer wakes waiters
   and frees slot on last release.
3. ~~Per-thread IPC buffer page~~ — done: VA `0x6FFF0000`, allocated
   + zeroed + mapped at spawn (init + children), PA in TCB, kernel
   access via physmap; freed by AS teardown. One buffer per AS while
   single-threaded.
4. ~~`call`/`recv`/`reply`~~ — done (4b): FIFO blocked-caller queue
   per endpoint (not single-waiter), rendezvous transfer buffer->
   buffer, badge stamping, cap transfer with rollback, reply cap at
   254 with full lifecycle (consumed/failed/overwrite/endpoint-gone),
   wake-with-status via saved-context a0.
5a. ~~Preemption~~ — done: 100 ms timer tick preempts running user
    threads (SPP check; kernel threads/idle stay cooperative), reusing
    blocking-syscall context machinery; `Tests/Spin` canary proves a
    forever-spinner no longer hangs the system.
    Amended later (SMP1 speedup): quantum 100 -> 50 ms; syscall 27
    cpu_count (first kernel introspection, returns
    Kernel.CPUs.Count); Tests/Spin prints "spin skipped (UP)" and
    exits on a single hart — its canary role there only stole
    quanta from rendezvous handoffs (full fuzz suite 474 s ->
    3.3 s at QEMU_SMP=1, ~140x, matching SMP4 wall time).
5b. ~~SMP~~ — done: seL4-style big kernel lock (Kernel.Lock) taken at
    trap entry and released by the trap trampoline itself; user code
    runs truly in parallel. DTB /cpus enumeration drives topology
    (metadata cap 64; per-hart kernel stacks PMM-allocated), SBI HSM
    starts secondaries into an idle/scheduling loop on per-hart
    stacks, wakers IPI via SBI sPI on ready-queue empty->nonempty,
    per-hart timer arms, PLIC external handling stays on the boot
    hart. Two SMP invariants burned in: a hart must never idle on a
    blocked thread's kernel stack (another hart can resume it and the
    next trap clobbers the sleeper's frames), and the BKL must be
    released only after the handler's C stack is fully popped (the
    trampoline does it). 89/89 directed PASS at QEMU_SMP 1/2/4/8,
    fuzz failures=0.
5. ~~Fuzzer~~ — done: grant-list spawn replaced grant_mask outright
   (syscall 8 a2 = grant count; entries in spawner's IPC buffer,
   rights-subset enforced); end-to-end echo (badge stamping,
   round-trip, one-shot reply cap, cap transfer + handle rewrite,
   reap), grant validation cases (unopened handle, escalation,
   unknown bits, count limit); 40/40 directed PASS. Session-manager
   badge pattern exercised: init mints badged endpoint to fuzzer.
6. ~~Spawn ABI v2 remainder~~ — done: `Boot_File_Object` image caps
   (one pinned static per initrd file, enumerated at boot), syscall 8
   now `spawn(a0 = image_cap, a1 = grant_count)` (path slices and
   `Kernel.Program_Loader` retired), read-only bootinfo page at
   `0x6FFE0000` lists init's caps as (handle, kind, rights, name)
   entries (init hardcodes no handle numbers), boot byte API is
   cap-based (a0 = boot file cap with Read). Init resolves manifest
   program paths to image caps via bootinfo names; fuzzer spawns echo
   from a granted image cap; 40/40 directed PASS.
7. ~~RTS core~~ — done: `Akernel_User.IPC` typed wrappers (generic
   over request/response payload records marshalled into the message's
   6-word area, 48-byte limit); echo server migrated (wire protocol
   unchanged, raw-ecall fuzzer still validates it); `Boot_Cap` /
   `Boot_Cap_Rights` bootinfo lookup in the RTS; init composes child
   namespaces from manifest tokens that are plain bootinfo entry
   names (kernel-assigned rights), only `ipc_test` stays a special
   badged-endpoint token. 40/40 directed PASS.
8. ~~RTS streams~~ — done: `Akernel_User.Streams` `Endpoint_Stream`
   (Ada.Streams `Root_Stream_Type` over endpoint caps; vendored
   `a-stream`/`a-ioexce` into the RTS, per-program `-gnatg`);
   `Akernel_User.Console` Put/Put_Line over it; init mints the
   console endpoint (`console` = Send, `console_server` = Receive
   manifest tokens); Drivers/Serial is the console server (UART RX
   opportunistic; IRQ-driven RX waits on notifications); fuzz, echo,
   spin migrated off debug_putchar. 42/42 directed PASS.

9. ~~Memory objects~~ — done: `Kernel.Memory` (refcounted slab +
   PMM frames, 1..64 zeroed pages per object), `Memory_Object` cap
   kind (Map/Read/Write/Transfer/Manage at creation), syscalls
   15/16/17 mem_alloc/mem_map/mem_unmap; borrowed mappings marked
   with PTE RSW bit 0 (AS teardown and unmap never free object
   frames; object finalizer returns them to the PMM on last cap
   close); unmap refuses AS-owned pages. 54/54 directed PASS.

10. ~~RTS heap on memory objects~~ — done: custom `s-memory.adb`
    overrides the light runtime bump allocator: free-list heap at
    VA 0x4000_0000 (below text), first-fit + splitting + coalescing,
    grown on demand via mem_alloc(64)/mem_map (8 chunks = 2 MiB
    cap), pulled into every program's closure by a private with on
    the Akernel_User root spec. `new`/Unchecked_Deallocation work in
    all userspace programs (heap state is .bss + lazy init, since
    adainit never runs). Secondary stack already functional via the
    light runtime's default pool. Exceptions remain
    No_Exception_Propagation (last-chance handler). 58/58 directed
    PASS.

11. ~~File protocol (9P-ish) over streams~~ — done:
    System/Fileserver holds every boot-file cap (`boot_files`
    manifest token; init pushes the handle->name table over the fs
    endpoint as Op_Set_Name messages after spawn) and serves
    Stat/Open/Read by name. mem_map accepts Boot_File_Object caps:
    borrowed read-only initrd frames, true-page-span extent, lead-in
    byte offset returned in a1 (`akernel_sys_mem_map_file` stub
    injects flags=read-only — Ada's 6th arg lands in a5, so the
    stub moves the delta pointer to a6 and sets a5). Reads are
    stateless; bulk data moves through a client-owned buffer memory
    object transferred per Read (replies cannot carry caps). 64/64
    directed PASS.

Next candidates (order open):

12. ~~Spawn v2 completion~~ — done: spawn accepts Memory_Object caps
    (Kernel.ELF.Source abstracts image bytes over physmap ranges and
    object frames; fuzz stages Tests/Memstage via the file server
    into an object, spawns from it, reaps). Remaining: none.
13. ~~Line-atomic console writes~~ — done: serial server buffers per
    client (badge = program id, newline/full-buffer flush); kernel
    debug_putchar buffers per thread (TCB, newline/full/exit flush).
14. ~~Notification objects~~ — done: Notification_Object caps
    (ntfn_create/wait/signal/bind_thread, irq_bind_ntfn),
    thread-bound delivery as a synthetic IPC_Recv message
    (Label = U64'Last); UART RX in Drivers/Serial is IRQ-driven
    through it (uart/irq grant).
15. ~~DTB device enumeration~~ — done: `Kernel.Device_Tree.Find_Device`
    (compatible string-list match, per-node capture decided at node
    close since FDT property order is arbitrary, parent
    #address-cells/#size-cells stack, #size-cells=0 handled); UART
    base + IRQ source and PLIC base come from the DTB
    (`Kernel.Boot_Resources.Initialize`, `Board.UART.Set_Base`,
    `Board.PLIC.Set_Base`, `Board.Interrupts.Initialize (source)`),
    board constants are fallback defaults. 89/89 directed PASS, fuzz
    failures=0.
16. ~~Device plumbing~~ — done: PMM reserved ranges (initrd, DTB —
    latent clobber fix); `Kernel.Devices` dynamic MMIO/IRQ objects on
    a PMM slab (boot UART migrated, IRQ finalizer unregisters the
    source); syscalls 23/24/25 io_map / irq_create / mem_object_pa,
    gated by the `device_resource` Kernel_Object cap (Manage right,
    init only); DTB exposed as pseudo boot file "dtb"; Map_MMIO now
    maps borrowed (device frames never reach the PMM). 93/93
    directed PASS, fuzz failures=0.
17. ~~Virtio-rng end-to-end~~ — done: `userspace/virtio` Alire lib
    crate (MMIO register level generic over Reg_Read/Reg_Write,
    split-ring virtqueues as flat volatile array overlays — record
    Pack is unreliable on volatile types); init's device manager
    (Device_Tree userspace FDT walker over the mapped "dtb" file +
    Device_Manager parsing `System/Drivers` lines `driver
    <compatible> <path> <probe> <class>`, virtio probe = device id
    @0x08) spawns Drivers/VirtioRng with console/mmio/irq handles
    1..3; driver runs a 16-byte entropy request through a 4-page DMA
    object (mem_object_pa for device-side addresses). QEMU virt
    exposes 8 virtio-mmio slot nodes, one populated; probing
    tolerates the empties. qemu needs
    `-global virtio-mmio.force-legacy=false` (mmio defaults to the
    v1 legacy interface otherwise). 94/94 directed PASS at QEMU_SMP
    1/4/8, fuzz failures=0.

Next candidates (order open):

18. Virtio-blk driver + block protocol (in progress):
    18a. ~~IRQ-driven driver + self-test~~ — done: Drivers/VirtioBlk
         (System/Drivers line `driver virtio,mmio Drivers/VirtioBlk
         virtio 2`, handle 3 = IRQ cap bound to a thread-bound
         notification; PLIC claim completed via IRQ_Ack in the wait
         loop). disk.img generated by the Makefile (sector 0
         "AKBLKIMG" + 0xA5, sector s = byte (s+j) mod 256), qemu
         `-drive if=none + virtio-blk-device`. Self-test: signature
         sector, pattern sector 7, write/readback round-trip on
         sector 3, capacity 2048. Latent lib bug fixed:
         Virtio.Queues.Free zeroed descriptor words before reading
         their links, corrupting the free list into a self-loop
         (Alloc returned No_Desc mid-chain -> wild descriptor index
         -> silent exception hang); Free now pushes each descriptor
         individually. Driver-side gotcha: Ntfn_Wait can only be
         woken by Signal when the notification is thread-bound
         (Ntfn_Bind_Thread) — unbound, bits accumulate but nobody
         wakes; stale bits from fast-path IRQs masked this until a
         request truly blocked. 98/98 directed PASS at QEMU_SMP
         1/4/8, fuzz failures=0.
    18b. ~~Block protocol + block-backed volume~~ — done: devmgr
         grants every spawned driver a fresh service endpoint at
         handle 4 (Receive) and keeps init's Send side of the
         class-2 (block) instance; init pushes it to the file
         server as Op_Add_Block (Op_Mount words + endpoint cap in
         slot 0). Block protocol labels: 0 info -> (status,
         capacity sectors), 1 read / 2 write (sector, count<=8) +
         buffer memory-object cap (IPC transfer copies rights
         verbatim, so Manage travels and the driver can
         mem_object_pa the client's frame). Fileserver mounts BD0
         (label Disk) exposing the raw device as the single file
         "disk": stat/open/read resolve through sector RPCs with a
         one-page bounce buffer, including unaligned offsets.
         Latent bug fixed: spawn allocated ONE 4 KiB user stack
         page; fuzz overflowed it with an on-stack 512-byte buffer
         (store fault at stack window - 8) — spawn now maps 4
         stack pages. 104/104 directed PASS at QEMU_SMP 1/4/8,
         fuzz failures=0.
19. ~~Retire the uart/mmio + uart/irq bootinfo tokens onto the generic
    devmgr path~~ — done: `driver ns16550a Drivers/Serial none 0`
    in System/Drivers; class 0 means the console server, so the
    devmgr grants it the console endpoint Receive side at handle 1
    (other drivers get a Send side badged with the driver id) and
    Drivers/Serial moved to the generic driver handle ABI
    (1 console, 2 MMIO, 3 IRQ, 4 service endpoint). Kernel no
    longer mints uart/mmio + uart/irq caps for init: boot-file caps
    are handles 1..N, device_resource at N+1, Kernel.Boot_Resources
    deleted (bootstrap's cap-table smoke test inserts the static
    device_resource header — any object does; the UART IRQ line
    registers when the devmgr irq_create's it). Ordering fix: the devmgr must run
    BEFORE the manifest programs — spawning the file server first
    deadlocked init's fs name push against the file server's first
    console write (no console server existed yet). 104/104 directed
    PASS at QEMU_SMP 1/4/8, fuzz failures=0.
20. Real filesystem on the block device (in progress):
    ~~Prerequisite cap_delete~~ — done: syscall 26 closes one of the
    caller's own cap-table slots via Kernel.Tasks.Close_Cap (same
    per-kind cleanup as the exit/reap path); the blk driver deletes
    each request's transferred buffer cap after the RPC (was one
    leaked slot per transfer). Fuzz random phase ranges over 0..26
    now with cap_delete skipped (a random delete could close the
    fuzzer's own granted caps). 108/108 directed PASS at QEMU_SMP
    1/4/8, fuzz failures=0.
    20a. ~~FAT32 read-only as an independent fs driver~~ — done:
         System/Fat32 (manifest `program 5 System/Fat32 console blk
         fat32_server`): handle 2 = virtio-blk service Send, handle
         3 = init-minted service endpoint Receive; init pushes its
         Send side to the file server as Op_Add_FS (device HD0,
         label AKDISK). The file server is now a VFS: fs-driver
         volumes forward stat/open/read verbatim (path repacked,
         client buffer cap transferred onward — every layer
         cap_deletes its copy after the op; the same per-op leak
         existed in the file server's own read paths and is fixed
         there too, per-op map/unmap instead of a cached mapping).
         Driver probes the BPB (0x55AA, "FAT32   ", cluster size
         <= 8 sectors), serves flat-root 8.3 reads with FAT chain
         walks through a bounce page. disk.img is now a 64 MiB
         FAT32 image (host mkfs.vfat + mtools: README.TXT, BIG.BIN
         64 KiB multi-cluster pattern); the virtio-blk self-test
         runs its write suite only on legacy AKBLKIMG images and
         read-only checks otherwise. Raw device stays BD0:disk.
         114/114 directed PASS at QEMU_SMP 1/4/8, fuzz failures=0.
    20b. ~~Write path, subdirectories, LFN~~ — done: Op_Write = 7
         (same wire shape as Op_Read, buffer consumed). VFS:
         boot-file volumes read-only (Status_Bad_Args), raw "disk"
         writes bounce read-modify-write partial sectors, fs-driver
         volumes forward verbatim. Fat32 driver: subdirectory
         traversal ('/'-separated components), LFN matching
         (UCS-2 assembly, case-insensitive, short-name fallback),
         file create (8.3 component names, free-dirent scan +
         directory chain extension), write with sector
         read-modify-write, cluster chain extension (free-entry
         scan from the FSInfo hint, both FAT mirrors updated,
         FSInfo free count/next-free maintained), dirent
         cluster/size writeback. No sparse writes (offset > size
         rejected). Image gains SUBDIR/HELLO.TXT (mmd) and
         LongFileName.txt (host LFN); fuzz adds 16 directed tests
         (subdir/lfn reads, create/overwrite/extend/stat/readback,
         subdir create, sparse+bad-parent rejection, raw-disk
         write+readback) — idempotent across reused images.
         Host fsck.fat validates the driver's writes clean.
         130/130 directed PASS at QEMU_SMP 1/4/8, fuzz failures=0.
    20c. ~~Delete/truncate, mkdir/rmdir, LFN creation,
         timestamps~~ — done: Op_Delete/Truncate/Mkdir/Rmdir =
         8..11 (path in words 0..5 like Op_Stat, no buffer cap;
         VFS forwards to fs-driver volumes, boot-file and raw
         block volumes reject). Client wrappers
         Files.Delete/Truncate/Mkdir/Rmdir. Delete frees the FAT
         chain (raw zero entries, FSInfo free count/next-free
         updated) and marks the dirent AND its LFN run 0xE5
         (Find_In_Dir now tracks the run start chain-wise);
         truncate additionally zeroes start cluster + size.
         Mkdir creates an entry with one cluster holding "." and
         ".." (root child's ".." = 0); rmdir requires an empty
         chain (only dot entries and deleted slots). Creation
         takes non-8.3 components via a numeric-tail alias
         ("NAME~1.EXT", collision scan 1..9) plus LFN entries
         (VFAT checksum, UCS-2, 0x0000 terminator + 0xFFFF fill).
         Dirent timestamps carry a fixed 2025-01-01 (no RTC).
         Two FAT-semantics bugs burned: (1) extending a directory
         whose last cluster ends in a 0x00 terminator and writing
         the new entries into the fresh cluster puts them behind
         the end-of-directory marker — unreachable to every
         reader, orphan chain to fsck; free-slot runs must span
         the cluster link and overwrite the terminator (entries
         now written chain-wise with per-sector RMW). (2)
         Delete_Dirent marked the LFN run in the bounce page,
         then Next_Cluster's FAT read clobbered the unwritten
         marks (orphaned LFN parts at fsck); each cluster's
         marks are flushed before advancing. Also fixed a 20b
         latent bug: Set_Fat_Entry wrote links as
         Val | 0x0F000000 — reserved top nibble set on non-EOC
         entries makes mtools/fsck flag the chain; only the low
         28 bits are written now (top preserved). Fuzz gains 27
         directed tests, idempotent across reused images. Host
         fsck.fat clean. 157/157 directed PASS at QEMU_SMP 1/4/8,
         fuzz failures=0.

21. ~~GPT partition layer~~ — done: System/Partmgr sits between the
    virtio-blk driver and filesystem drivers. Manifest `program 5
    System/Partmgr console blk part_server` (blk token moved here
    from fat32): probes LBA 1 for "EFI PART", walks the entry
    array, first 8 non-empty entries become slots; without a GPT
    header slot 0 maps the whole device (superfloppy fallback).
    Serves the same block protocol (0 info / 1 read / 2 write) on
    one endpoint; clients select the partition by cap BADGE — new
    `partN` manifest tokens grant Send on the part service with
    badge 16#1000#+N. Sector offset translation + bounds checks;
    request buffer caps forwarded zero-copy to blk, local copy
    cap_delete'd per op. fat32's manifest line becomes `console
    part0 fat32_server`; driver code unchanged. disk.img is now a
    GPT disk (host sgdisk: partition 1 at sector 2048, 60 MiB
    FAT32 via mkfs.vfat --offset 2048 + mtools @@1048576); raw
    BD0:disk fuzz checks switched to the GPT header (sector 1,
    "EFI PART") and the raw-write test moved to the pre-partition
    gap sector. Kernel Max_Process_Slots 8 -> 16 (partmgr pushed
    peak concurrent processes past 8; spawn failed No_Slot).
    130/130 directed PASS at QEMU_SMP 1/4/8, fuzz failures=0.
    Remainder done: MBR read fallback (no GPT -> 0x55AA signature
    at LBA 0 -> up to 4 primary entries, else superfloppy slot 0),
    part_query op (3: slot in words 0 -> status/first-LBA/size/
    populated-count), per-partition raw volumes (init enumerates
    slots via a minted query cap and pushes Op_Add_Block per slot:
    device "PDN", label "PartN", partN-badged Send cap).
    New syscall 28 cap_mint(source, rights_mask, badge) derives an
    attenuated + badged cap in the caller's own table (same
    validation as spawn grant lists) — the session-manager pattern
    needed a way to badge caps after spawn. Bug burned: a cap
    handed over in a message must carry the Transfer right; a
    Send-only minted cap failed the kernel's transfer check and
    rolled back the whole rendezvous (fileserver recv returned
    Transfer_Failed mid-boot). 163/163 directed PASS at QEMU_SMP
    1/4/8, fuzz failures=0.
22. ~~FAT32 metadata cache + sync op~~ — done: fat32 gained an
    8-slot write-through sector cache (MRU/LRU eviction) for
    metadata only: FAT sectors (chain walks re-fetched the same
    FAT sector once per entry — with 1-sector clusters BIG.BIN's
    whole ~110-entry chain lives in ONE sector), directory
    clusters (lookup scans), FSInfo. Every driver write funnels
    through Meta_Write, which refreshes any cached copy of the
    written sectors from the bounce, so the cache can never go
    stale against the driver's own writes (sole-writer
    invariant; a raw PDN write to a mounted partition bypasses
    and can stale it — do not raw-write a mounted partition).
    File data reads/writes bypass the cache (streaming, never
    repeated). Placement was the design question: a fat32-local
    cache beats partmgr/blk-level caches here because the pain
    was repeated metadata fetches, not streaming, and lower
    layers would lose the zero-copy buffer-cap DMA path and
    inherit BD0-vs-partition aliasing; revisit when a second fs
    driver appears. New file-protocol op Op_Sync = 12 (no words;
    fileserver fans out to all fs-driver volumes; fat32 replies
    ok — write-through no-op today, flush hook for future
    write-back or VIRTIO_BLK_F_FLUSH). SMP1 guest test window
    (fuzz online -> complete) ~0.28 s. 164/164 directed PASS at
    QEMU_SMP 1/4/8, fuzz failures=0, host fsck.fat clean.
23. ~~Scheduler wakeup boost~~ — done: a thread woken by IPC or
    notification re-enters at the FRONT of the shared ready queue
    (Scheduler.Push Boost param; Wake boosts; per-thread Boosted
    flag in the TCB, cleared on EVERY block path — including the
    four arch-traps sites that block directly and bypass
    Scheduler.Block_Current). Rendezvous handoffs no longer queue
    behind a CPU hog: on UP a spinning thread used to steal a
    50 ms quantum per handoff (~600 ms per IPC-heavy test line,
    474 s suite). Spin's UP self-skip is removed — it now spins
    forever on every config as the boost regression canary, and
    the SMP1 suite completes in ~21 s wall with the hog running
    (residual cost is fair 50/50 sharing in the syscall-only
    fuzz random phase, zero per-rendezvous stalls). Bugs burned:
    (1) boost preserved across timer preemption + never cleared
    on the direct arch-traps block paths = PERMANENT boost —
    boosted ping-pong starved init/fat32 at boot (SMP1 boot
    stall, SMP4 memstage reap starvation FAIL); boost must be
    "run promptly once after wake", not a persistent priority.
    (2) Latent boot race exposed: fuzz outraced init's async
    volume pushes; the suite now awaits each volume's stat with
    yields before probing it (3 new directed checks).
    167/167 directed PASS at QEMU_SMP 1/4/8 (x2 at 1), fuzz
    failures=0, host fsck.fat clean.

24. ~~PCI virtio transport~~ — done: virtio drivers moved off
    virtio-mmio onto virtio-pci (rng addr=0x3, blk addr=0x4,
    transitional -> INTx, no MSI-X) because QEMU's riscv-iommu
    translates PCI DMA only (iommu-map on the pci host node;
    virtio-mmio nodes carry no iommus property) — PCI was a hard
    prerequisite for IOMMU DMA isolation. New Virtio.PCI transport
    package mirrors the MMIO API (common-config structure,
    width-exact field accesses — no 32-bit RMW on mixed-width
    fields; queue_enable/queue_notify_off; notify_off_multiplier
    applied inside the driver's Notify_Write because it is a
    runtime value from the devmgr). Devmgr matches the
    pci-host-ecam-generic node and scans bus 0: io_map caps are
    limited to 64 pages, so each function's 4 KiB config page is
    io_map'd/probed then unmapped + cap_delete'd (no whole-ECAM
    window; the ECAM never reaches drivers). BARs are assigned by
    the devmgr itself (no firmware PCI init on riscv virt) into
    the MMIO32/MMIO64 windows with MEM+BME command bits; the
    vendor capability list yields the common/notify/ISR/device-cfg
    regions granted as per-region io_map caps. System/Drivers pci
    lines are `driver pci,<vid4> <path> pci <class>` with the
    class field carrying the virtio device id — matching
    normalizes transitional (legacy table: 0x1005 = rng, 0x1004 =
    legacy SCSI, NOT 0x1000+id) and modern (0x1040+id) PCI ids.
    Fixed PCI driver ABI: 1 console, 2 common-cfg, 3 notify,
    4 ISR, 5 device-cfg, 6 IRQ, 7 service endpoint; the devmgr's
    first service-endpoint message is a driver config
    (notify_off_multiplier, IRQ source, PCI device id) answered
    with a status-0 reply — the rendezvous also orders the devmgr
    after driver startup. INTx via the host interrupt-map swizzle
    (PLIC source 32 + (dev + pin - 1) mod 4); the ISR register
    read clears the virtio interrupt cause at the device.
    167/167 directed PASS at QEMU_SMP 1/4/8, fuzz failures=0,
    host fsck.fat clean.

25. ~~riscv-iommu + DMA isolation~~ — done: Arch.IOMMU kernel
    driver (spec 1.0 memory-mapped variant, encodings
    cross-checked against Linux drivers/iommu/riscv/bits.h).
    Probed from the DTB ("riscv,iommu" @ 0x3010000, wired IRQ
    vector 0 = PLIC 36); qemu runs with -machine iommu-sys=on.
    3-level DDT with on-demand leaf pages, one device context per
    PCI requester id (tc=V, iohgatp bare, SADE=0 with A/D preset
    in PTEs, MSI translation off — drivers use INTx), per-device
    Sv39 IO page table, IOVA = PA identity. The authorization
    point is mem_object_pa: io_map gained a Device_Id argument
    (a3; RTS default = unattributed), the devmgr attributes every
    PCI region cap to its requester id, and the syscall maps the
    queried frame for every attributed device the CALLER holds a
    cap for (drivers have exactly one); the memory object records
    per-object device backlinks (Note_DMA_Mapping, 8 slots) so the
    finalizer unmaps before frames return to the PMM. Callers
    without device caps see no side effects. Command queue drives
    IODIR.INVAL_DDT / IOTINVAL.VMA / IOFENCE.C per change; fault
    queue drains on the PLIC-wired interrupt via a new
    Kernel.Interrupts kernel-handler slot (board completes the
    claim immediately; userspace sources still complete in
    irq_ack). Boot self-test through the DBG translation-probe
    registers (TR_REQ_IOVA/CTL/RESPONSE on a scratch device id):
    unmapped IOVA faults, mapped frame resolves to its PPN,
    unmapped again faults — and the two induced fault records
    exercise the IRQ path too. From DDTP mode 3LVL on, any DMA to
    a non-authorized frame faults instead of touching memory;
    the full block stack (blk self-test + all fuzz sector
    traffic) runs translated. 167/167 directed PASS at QEMU_SMP
    1/4/8, fuzz failures=0, host fsck.fat clean.

26. ~~virtio-input (keyboard + tablet)~~ — done: one VirtioInput
    driver image serves every virtio-input function (qemu
    -device virtio-keyboard-pci,addr=0x5 + virtio-tablet-pci,addr=0x6;
    System/Drivers line class 18 spawns one instance per
    function, role discovered from the ID_NAME config string).
    Eventq only (8 posted 8-byte event buffers, descriptor id ==
    slot id, reposted on completion), IRQ-driven over INTx. Burned:
    QEMU implements the LINUX virtio_input.h config layout — the
    device config region is the CURRENTLY SELECTED blob
    (select/subsel/size at 0x00..0x02, payload at 0x08;
    EV_BITS=0x11, ABS_INFO=0x12), not the ids-at-0x00 draft
    layout, and there is NO event-type bitmap at EV_BITS subsel 0
    (probe concrete types: EV_KEY bitmap has KEY_A, EV_ABS bitmap
    has ABS_X, ABS_INFO max != 0). Keyboard: US keymap + shift/
    capslock, chars delivered to the console server through a new
    stream-protocol label Op_Input (3) into a bounded input FIFO
    the UART RX now also feeds; client Op_Read drains it (was
    output-only). Pointer (tablet = absolute, right for a display
    console; mouse supported via EV_REL if ever plugged): events
    debug-logged on the serial log until the GPU console lands a
    structured channel. Verified live with qemu monitor sendkey
    over a unix socket (kept in the run target): keys flow
    eventq -> INTx -> keymap -> Op_Input -> console FIFO.
    Console server fix burned: badge line-buffer slots are now
    RELEASED on newline flush — with 10+ console clients the
    8-slot pinned table filled permanently and the table-full
    bypass interleaved lines character-wise at SMP8 (PASSprogram
    spawned glue); a badge needs a slot only while a partial
    line pends. 169/169 directed PASS at QEMU_SMP 1/4/8 (three
    SMP8 runs), fuzz failures=0, host fsck.fat clean.

27. ~~virtio-gpu (display console)~~ — done: Drivers/VirtioGpu
    (virtio-gpu-pci addr 0x7, class 16) runs the controlq 2D
    command set (GET_DISPLAY_INFO / CREATE_2D B8G8R8A8 /
    ATTACH_BACKING per-page entries / SET_SCANOUT /
    TRANSFER_TO_HOST_2D + FLUSH with a dirty pixel-row band),
    framebuffer = a list of 64-page memory objects (kernel object
    page cap) mapped contiguously. Text console: font8x8 (public
    domain) stretched 2x vertically -> 8x16 cells, 128x48 at
    1024x768, scroll + CR/LF/TAB/BS. The console server mirrors
    every flushed line to sink endpoints registered through the
    new stream label Op_Attach_Sink (cap slot 0, init/devmgr badge
    0 only, failing sinks dropped + cap deleted); devmgr attaches
    the GPU endpoint right after spawn. Burned: the GPU driver
    must NEVER print via the console stream during init (server
    blocked in the sink RPC -> deadlock); all its logging is
    Debug_Put_Line. Verified end-to-end headless: qemu monitor
    screendump (kept in the run target) of the virtio console
    shows the mirrored boot text (60k non-black pixels, readable
    fuzz PASS lines in a PPM crop).

    Kernel changes forced by the fifth PCI device — shared INTx:
    qemu virt swizzles (dev + pin - 1) mod 4 onto PLIC sources
    32..35, so EVERY source was taken and any new device collides.
    Interrupts.Register now chains duplicate-source line objects
    (same-object registration still fails), Deliver walks the
    chain and pokes every line (drivers claim events via their
    own device ISR; level triggering re-delivers while any
    partner asserts). Two latent bugs this exposed: (1)
    Devices.Release underflowed Count (0 - 1) on the IRQ_Create
    failure path -> Constraint_Error -> kernel last-chance
    handler, fixed with a count-0 free path; (2) the rng driver
    polled completions and NEVER acked its IRQ — fine while it
    owned source 35 alone, fatal once shared: an unacked line
    holds the PLIC claim open and silences the source for all
    partners. Invariant burned into docs/IPC.md: every IRQ cap
    holder must eventually irq_ack after being poked. rng now
    binds a notification and drains + acks in its resident Recv
    loop. Debugging note: alr's build hash can go stale across
    interrupted builds — alr clean when a fixed error "persists".
    171/171 directed PASS at QEMU_SMP 1/4/8, fuzz failures=0,
    host fsck.fat clean. Followup fix (27b): font8x8 bit order —
    bit 0 is the leftmost pixel, not bit 7 as the upstream
    comment claims (first real-display check showed mirrored
    glyphs); verified exactly by decoding screendump PPM cells
    against the font table (err=0). Non-black/threshold checks
    fool: mirrored glyphs still look glyphy.

28. GUI: display-service split + compositor + terminal client.
    Design settled in discussion (Wayland model mapped onto caps:
    fd passing = cap transfer; wl_shm attach/damage/commit =
    surface endpoint + memobj; dmabuf zero-copy = mem_object_pa
    surfaces; seat = BureauSrv input hub; frame callback =
    Present-complete reply):

    - Drivers/VirtioGpu SHRINKS to a dumb display service (no
      text, no chrome — window logic is arch-independent, drivers
      are per-board, duplication point dies here). Protocol:
      Present(dirty band) + hw-cursor ops (cursorq
      UPDATE_CURSOR/MOVE_CURSOR = 0x300/0x301; absent ->
      BureauSrv software-sprites + damages). CORRECTION burned:
      virtio-gpu 2D has NO resource copy/blit commands — the 2D
      cmd enum (standard-headers/linux/virtio_gpu.h) runs
      GET_DISPLAY_INFO .. SET_SCANOUT_BLOB with no
      RESOURCE_COPY_REGION/BLIT anywhere (earlier draft of this
      plan claimed otherwise; wrong, do not resurrect).
      Device-side scroll is impossible here; all compositing is
      guest-CPU + TRANSFER uploads of damage bands (host memcpy
      speed both ways — fine at 1024x768; the Amiga bitplane
      trap was shared-chip bandwidth, not pixel movement per
      se). Zero-copy exists only behind VIRGL/3D (not planned).
    - Servers/Bureau (new, arch-independent; the compositor /
      window server process — the GUI is named "Bureau",
      user-chosen, no akernel prefix, screen bar reads
      "Bureau"): owns the compositing buffer — IT ALLOCATES
      it (Mem_Alloc 64-page chunks; caps move caller -> callee
      only, replies are words-only, so the earlier
      "Create_Surface returns shm memobj" sketch inverts to
      wl_shm direction: client allocates, pushes caps) — one
      scanout resource re-attached onto those pages, TRANSFER
      of damage bands, FLUSH. SLICE 1 DONE (committed): the
      display-service protocol (akernel_user-display.ads,
      labels 10-13, cursor ops reserved at 14/15) is served by
      virtio_gpu alongside the text sink; Op_Set_Buffer /
      Op_Commit_Buffer / Op_Present / Op_Get_Info all live;
      text console pixel-exact after the split (screendump
      decode err=0). SLICE 2 DONE (committed): Servers/Bureau
      (userspace/bureau, spawned by devmgr right after the GPU
      with console + display-EP Send caps, image System/Bureau)
      allocates the compositing buffer, pushes chunks, commits,
      renders desktop + "Bureau" screen bar + matted window
      (WB3 palette, gadtools bevels, blue active title,
      close/depth gadget placeholders), presents the frame, then
      blocks (no clients yet). font8x8 moved to rts/akernel
      (shared client-side rendering). Burned (then un-burned): a screendump decoder that
      swapped R/B reconstructing PPM pixels made the correct
      AARRGGBB blue title "read as" red; "fixing" the palette
      produced a REAL salmon title (user caught it) that the
      buggy decoder re-confirmed as blue. Pixels really are
      B8G8R8A8 = LE u32 AARRGGBB (low byte = BLUE). Decode PPM
      bytes straight (R,G,B); trust the user's eyes over the
      script. Client display
      helpers live in akernel_user-display.adb (raw IPC_Call;
      replies are words-only). SLICE 3 DONE (committed):
      window protocol v1 (akernel_user-window.ads, labels
      20-24, ONE surface slot bound to Bureau's startup window;
      client allocates surface, pushes chunks, Bureau maps
      read-only and copies Op_Surface_Update bands into the
      compositing buffer at the pane origin — wl_shm model);
      userspace/terminal (System/Terminal, devmgr-spawned after
      Bureau) renders the console mirror into its surface
      (scroll = surface memmove + one band update) — boot
      output scrolls in the window pane, screendump decode
      err=0 on all cells. devmgr attaches the TERMINAL's sink
      EP (GPU driver EP is no longer a sink). Burned: the
      Debug_Put_Line-only rule covers the WHOLE display stack
      (Bureau + terminal too, not just GPU init): any console
      print by a display-stack process deadlocks — the console
      server mirrors to the terminal sink, and a terminal
      blocked in its own console RPC can never Receive (Bureau
      <-> terminal cycle proven live). 173/173 at SMP1, fuzz
      failures=0. SLICE 4 DONE (committed): the seat.
      devmgr records class-18 service EPs, pushes the terminal's
      stream EP to Bureau (Op_Set_Focus 26, cap slot 0) and
      Bureau's EP to both virtio-input instances
      (Seat_Config_Label = U64'Last-2, second message on their
      service EP — input functions scan BEFORE the GPU, so the
      seat arrives post-bring-up; their event loop converted
      from Ntfn_Wait to the rng-style IPC_Recv multiplex for
      this). Keys: driver keymap -> Op_Key 30 -> Bureau ->
      stream Op_Input byte into the focus (terminal) ->
      console input FIFO (shell reads Op_Read in milestone 31);
      interim "bureau key" serial log per key (remove at 31).
      Pointer: ABS_X/Y batched on EV_SYN + BTN bits ->
      Op_Pointer 31 (raw 0..32767, Bureau scales) -> SOFTWARE
      cursor sprite in Bureau (chosen over the virtio hw
      cursor: arch-independent fallback by design, works on
      every future dumb display driver; cursorq ops stay
      reserved in the display protocol). Bureau redraws the
      sprite when an Update band clobbers it (re-saves the
      under-rect fresh). Verified live: sendkey -> 2 bureau
      key events, 0 delivery failures; QMP input-send-event
      abs 20000/15000 -> arrow template-matched at EXACTLY
      (625,351) = scaled coords. Burned: HMP mouse_move
      produces NO absolute events for the virtio tablet
      (buttons flowed, movement didn't) — absolute injection
      needs QMP input-send-event; the run target now also
      exposes -qmp unix:/tmp/qqmp.sock. 173/173 SMP1, fuzz
      failures=0. Milestone 28 COMPLETE: 29 = boot from the
      Sys filesystem, 30 = multi-window + focus, 31 =
      interactive shell in the terminal.
    - Terminal = FIRST REAL CLIENT on window protocol v1:
      Create_Surface -> (surface EP + shm memobj),
      Commit(damage). Scroll = memmove inside the terminal's
      own surface + Commit of the pane band (no device copy
      exists — see display-service correction above; cost is
      one cache-speed memmove + one band upload). font8x8 moves
      to a client-side rendering lib future
      clients reuse. Terminal serves stream Op_Write (console
      sink compatible — devmgr's Op_Attach_Sink wiring
      unchanged) and injects keys into the console input FIFO
      via Op_Input, so the later shell reads Op_Read as
      planned. UART path stays for headless.
    - Theme (user-confirmed): pure Amiga, NeXTSTEP scrapped
      entirely. Workbench-3.x-STYLE look (NOT 1.3 — too dated):
      gray
      gadtools palette (light-gray fills, white highlight /
      dark shadow 3D bevels on borders and gadgets), blue
      accent for the ACTIVE window title bar (gray inactive),
      gray screen bar with dark text + right-side gadgets.
      Painted in 32-bit true color (B8G8R8A8 stays; virtio-gpu
      2D has no 16-bit/indexed formats, and packed 32bpp is
      the FAST path — the "fewer bitplanes = faster" intuition
      is planar-era, does not transfer). Boot = Amiga-style: the Bureau screen opens
      immediately and startup output scrolls in its console
      window (Startup-Sequence CLI look) — no boot-mode/display
      transition, one code path from power-on. Exact hex values / gadget shapes
      tunable at implementation time.
    - virtio-gpu 2D has no vsync event; FLUSH is fire-and-forget.
      Fine for text; revisit if tearing shows on pointer motion.
    - Cosmetic flake seen (not fixed, pre-existing): kernel
      direct-UART lines ("iommu context online") can interleave
      character-wise with console-server UART output at SMP4,
      occasionally eating a "PASS " prefix in the SERIAL log
      (content intact, display unaffected). Count PASS lines
      with interleave tolerance; the two blk pattern/readback
      selftests skip on reused (non-pattern) disk images.
    Follow-ups: multi-window + focus + moving windows (30),
    interactive shell in the terminal (31).

29. Boot from the Sys filesystem (initrd back to bootstrap
    scope). The initrd has grown into a root filesystem: the
    display stack (Bureau, terminal) and later the shell do
    not belong in it. Move them to the FAT32 data partition
    and launch them from there during boot.
    - Volume naming: the virtio-blk GPT partition 1 becomes
      device BD0 with volume label Sys (Amiga device:volume
      convention; HD0/AKDISK were placeholder names and this
      is a block device, so BD0 — the same name the raw
      volume already uses). Touch points: init's
      Push_Fat32_Mount (Dev "HD0" -> "BD0", Lab "AKDISK" ->
      "Sys"), the disk.img recipe (sgdisk -c 1:Sys,
      mkfs.vfat -n Sys), and the fuzz suite's "HD0:..." paths
      -> "BD0:..." (mechanical rename; tests stay idempotent
      across reused images).
    - FS-resident images: the Makefile mcopy's the Bureau and
      Terminal ELF images (later System/Shell) into disk.img
      at :System/Bureau, :System/Terminal (the Amiga System/
      drawer); both leave the initrd (mkinitrd manifest +
      Makefile initrd deps/cp). Drivers needed to REACH the
      FS (blk, partmgr, fat32, fileserver) and the console/
      display drivers stay in the initrd — bootstrap scope.
    - Launch from FS: spawn-from-memory-object exists since
      milestone 12 (fuzz stages Tests/Memstage through the
      file server); devmgr gains an exec-from-volume helper —
      read the whole file from BD0: into a memory object via
      the file server, spawn from the object cap. No kernel
      work expected.
    - Startup list: after the FS chain is online (blk ->
      partmgr -> fat32 -> fileserver; await the BD0: volume
      like the fuzz suite's Await_Volume), devmgr reads
      Sys:System/Startup (one program path per line, the
      Startup-Sequence analog) and spawns each entry from the
      volume, replacing the class-16 initrd spawn of Bureau +
      Terminal. FS-spawned handle layouts stay exactly as
      today (Bureau: 1 console Send, 2 display EP, 3 window
      svc Receive; Terminal: 1 console Send, 2 Bureau svc,
      3 sink EP) so the seat wiring is unchanged.
    - Ordering: the display stack now starts strictly after
      FS online — boot output still scrolls in the terminal
      (one code path from power-on), it just opens a beat
      later.
    Slices: ~~29a rename + disk recipe~~ — DONE (committed):
    FAT32 volume is BD0/Sys (Push_Fat32_Mount, disk recipe,
    fuzz paths incl. lowercase case-insensitivity probes and
    the Sys: label-resolution test); the RAW whole-device
    volume had to move OFF BD0 to WD0 (collision hung the
    boot: two volumes claimed device BD0 and the file
    server matched the raw one first) — raw partition
    volumes stay PD0..; host mdir shows "Volume ... is Sys",
    fsck clean, 173/173 SMP1, fuzz failures=0. 29b
    ~~29b FS-resident images out of the initrd~~ — DONE
    (committed): Bureau/Terminal left the initrd (Makefile
    deps + cp lines; cpio 812 KiB -> 717 KiB) and live only
    on Sys:System/ — the boot still spawns them from the FS,
    173/173 SMP1, fuzz failures=0. MILESTONE 29 COMPLETE.
    ~~29c
    exec-from-volume + Startup list~~ — DONE (committed):
    disk.img gains :System/Bureau, :System/Terminal and
    :System/Startup (one path per line; the recipe depends
    on the ELFs so the image rebuilds when they change).
    devmgr records GPU_Svc at class-16 instead of spawning,
    and init calls Device_Manager.Start_Display after the
    mounts: await + read BD0:System/Startup through the file
    server, stage each image into a memory object
    (Stat/Open/Read 32 KiB chunks, the memstage pattern —
    no kernel work), spawn from the object cap with the
    SAME grant layout as the initrd spawn, cap_delete the
    staging object; initrd fallback when the list is
    unavailable. Burned: INIT ran on ONE 4 KiB stack page
    (spawned processes got 4 in milestone 18b; init's is
    set up in akernel.adb) — Start_Display's on-stack
    buffer + Files frames overflowed it (store fault at
    stack_base - 8); init now gets 4 stack pages too and
    the startup buffer is library-level. Verified:
    "gpu online" -> spawn/bureau desktop/terminal/seat
    chain from the FS, desktop pixels exact at SMP4,
    173/173 SMP1, fuzz failures=0, host fsck clean.
    MILESTONE 30 (multi-window + focus) in progress:
    ~~30a window protocol v2 + multi-window Bureau~~ — DONE
    (committed): up to 4 window slots with per-window
    geometry (cascade placement), z-order band compositor
    (desktop -> windows bottom-to-top -> bar, all drawing
    clipped to the damage band; terminal scroll stays a
    narrow band), per-window input endpoint handed over at
    Surface_Create (cap slot 0; the devmgr focus push is
    gone — terminal gets a Send+Transfer copy of its sink
    EP at handle 4 since a Receive-only cap cannot mint
    Send), Op_Set_Title = 25 (40 bytes packed LE into
    w1..w5), real Destroy (unmap + cap_delete + repaint).
    Burned: 29b removed bureau/terminal from the initrd
    deps and NOTHING rebuilt them (disk.img deps were the
    ELF files, which have no rule) — the boot ran a stale
    v1 Bureau; `all` now builds bureau + terminal and
    disk.img depends on the phony crate targets. Also:
    v2 clamps the requested pane to SCREEN bounds only, so
    the terminal now asks for 87x29 cells explicitly
    (1024x768 exceeded the 8-chunk surface cap -> No_Slot).
    Verified: window at cascade (32,40), blue title +
    white text, 2 bureau key forwards, 173/173 SMP1, fuzz
    failures=0. ~~30b click-to-focus/raise + second
    client~~ — DONE (committed): Demo crate (color bars +
    key-strip echo, Sys:System/Demo, generic GUI grant ABI
    1=Bureau svc Send / 2=sink Receive / 3=sink
    Send+Transfer; Start_Display spawns unknown Startup
    entries that way); Bureau tracks button edges, button0
    press hit-tests top-to-bottom, raises + focuses.
    Burned: phony disk.img deps rebuilt the image every
    run on top of the EXISTING GPT (sgdisk "could not
    create partition") — the recipe now rm -f's first.
    Verified on screen: demo occludes terminal pane
    (frame pixel at the overlap), QMP click in the
    terminal pane raises it (blue title, pane over demo),
    key forwards to the focused window, 173/173 SMP1,
    fuzz failures=0. ~~30c title-bar dragging~~ — DONE
    (committed): press in the title band grabs the window
    (offset recorded), motion while held moves it (union
    band of old+new frames repainted), release drops;
    the pointer handler now erases the cursor BEFORE any
    press/drag repaint and redraws after (a repaint makes
    the saved under-rect stale). Ada declaration-order
    burn AGAIN: drag state must sit with the cursor state
    above Drag_Move/Pointer_Press. Verified: QMP drag
    moved the demo window origin exactly with the grab
    offset, the vacated area repainted to the terminal
    pane beneath. MILESTONE 30 COMPLETE. 31 =
    interactive shell in the terminal (launched from
    Sys:).

31. Interactive shell in the terminal (31a DONE, committed):
    Terminal is a console device (the CON: analog), not a shell
    host UI — launching a Terminal starts the shell. Terminal
    serves Op_Read from a local input FIFO, echoes focused keys
    into its own text grid (line discipline lives in the console
    device, never in the shell), stages System/Shell from Sys:
    (memstage pattern; grant ABI gains handle 5 = fs Send) and
    spawns it with 1 = Send on its own sink endpoint (badge 1,
    minted from handle 4 — a Receive-only cap cannot mint Send)
    and 2 = fs. The shell (userspace/shell, System/Shell) is a
    plain CLI program: it opens no window, its console channel
    decides where the session lives (terminal pane today, UART
    console server if spawned that way). Builtins help/version/
    exit; anything else is a program path staged + spawned with
    the shell's own console+fs caps and reap-polled (Reap is
    non-blocking — poll with Yield). "System/Shell" nests,
    Amiga-style. Boot mirror + shell share the pane: both write
    the same sink endpoint, multiplexed by badge. The interim
    "bureau key" serial log is gone.

    Input delivery had to become ASYNC first — window protocol
    v3. Burned HARD: Bureau forwarded focused keys with a
    blocking rendezvous into the client's input endpoint while
    clients rendezvous back with Surface_Update — any overlap
    deadlocks the pair (one key in, then Bureau blocked calling
    the client while the client is blocked calling Bureau;
    moving the flush to after the reply only moved the
    deadlock). Worse, the wedge CASCADES: terminal blocked =>
    console server blocked in the sink RPC => ALL console
    output stops and every printing process blocks behind it
    (fuzz "froze" mid-suite — it was the mirror, not the
    test). v3 (the Amiga message-port model docs/IPC.md always
    prescribed): each Surface_Create pushes a one-page event
    queue memobj (caps 0, Map+Read+Write+Transfer — head/tail
    counters + 255 two-word (kind,value) events, drop-new when
    full) and a thread-bound notification (caps 1,
    Write+Transfer). Bureau enqueues focused keys and signals
    bit 1; it NEVER calls the client. Clients multiplex the
    synthetic notification message on their service Receive
    (rng-style) and drain outside any rendezvous. Two kernel
    fixes this forced: (1) Notification_Full_Rights gained
    Transfer — a notification cap could never cross a message,
    so no client could push one (the milestone-21 Transfer
    burn again). (2) LATENT BUG: Notifications.Cleanup_Thread_
    Cap ran the thread UNBIND on every cap close, so deleting
    a minted copy after the transfer silently unbound the
    client thread from its own object — signals found no bound
    thread, bits pended forever, zero errors anywhere (6 keys
    queued+signaled at Bureau, 0 synthetic messages at the
    terminal). The unbind is thread-lifetime, not cap-lifetime:
    Cleanup_Thread_Cap_Object/Close_Cap gained a Thread_Dying
    flag (only Discard_Slot sets it). Same-class hooks on
    endpoints/IRQ lines (clear waiter on any cap close) only
    bite when deleting a cap while blocked on the object — no
    code does that; left as-is. Verified LIVE: click-to-focus
    the terminal, sendkey types "help"/"version"/"System/Shell"
    — echo in the pane, help text, milestone banner, nested
    shell banner+prompt, all screendump-verified; keys survive
    a concurrently scrolling fuzz mirror. 174 PASS at SMP1 +
    SMP4, fuzz failures=0, host fsck clean.

    31b DONE (same commit series): uniform program ABI. Every
    program spawned from Sys: (Startup list or shell child) gets
    the SAME namespace — 1 = console Send (badged), 2 = fs Send,
    3 = Bureau svc Send; a program is GUI only once it calls
    Surface_Create (the OpenWindow analog). Spawn_Gui_Client and
    every special-case grant ABI died; the terminal runs on the
    uniform ABI too and now RUNTIME-CREATES its stream sink
    endpoint (EP_Create) and SELF-ATTACHES it at the console
    server — Op_Attach_Sink accepts any badge now, the
    badge-0-only restriction was the last thing keeping sink
    wiring in devmgr. The seat push moved from Spawn_Terminal to
    Spawn_Bureau where it belongs. Demo creates its own receive
    endpoint (the thread-bound notification needs any EP to
    IPC_Recv on; nobody sends to it). The shell passes all three
    caps to children, so a GUI program launched from the shell
    just works — verified LIVE: "System/Demo" typed at the
    Sys:> prompt opened its window composited over the terminal.
    174 PASS SMP1+SMP4, fuzz failures=0, host fsck clean.

    Pointer events to focused clients DONE (v3 queue kind 2):
    one packed value (x16 | y16 | buttons8, content-relative),
    delivered only while the pointer is inside the window
    content and no title drag is active, and COALESCED in
    place — Bureau overwrites an undrained newest pointer event
    instead of growing the ring, so a fast pointer cannot flood
    255 slots (the first enqueue signals; coalesced overwrites
    ride the still-pending or already-woken drain). Delivery
    happens after focus/raise/drag handling so a content click
    lands with the new focus already in place. Demo paints a
    5x5 marker tracking the pointer (white while button0 held,
    black otherwise, old position restored to the bar colours);
    terminal ignores non-key kinds. Verified LIVE by pixel
    check, not eyeballs: press-hold at a content point, move
    the cursor off the content, screendump shows the white 5x5
    at exactly the pressed position. 174 PASS
    SMP1+SMP4, fuzz failures=0.

    Cursor artifacting FIXED (the ghost-arrow burn): the old
    Present_Band redraw path re-saved the cursor under-rect
    AFTER Paint_Band, so a client band that only PARTIALLY
    overlapped the sprite rect left old sprite pixels in the
    uncovered part of Buf; Cursor_Draw then saved a polluted
    under-rect and the next erase stamped arrow fragments onto
    the screen — fragments accumulated around any updating
    window (heavy over the pointer-tracking demo). Now every
    paint+present goes through Composite_Band: erase the sprite
    FIRST when the band intersects it (Buf never holds sprite
    pixels across a paint), repaint, redraw on top. Pixel-
    verified live: a 30-point cursor sweep over the demo leaves
    exactly ONE sprite's worth of fill pixels (52 px in an
    8x13 box) and zero fragments. Also: Makefile gained
    QEMU_ARGS (default -nographic; make run QEMU_ARGS="-
    display gtk" for interactive testing — the later -display
    wins and serial stays on stdio).

32. Desktop + shell usability (32a + 32b DONE): the left
    title-bar gadget is CLOSE — Bureau enqueues a close event
    (v3 queue kind 3, the CLOSEWINDOW analog) into the window's
    queue and signals; the CLIENT decides (terminal/demo:
    Surface_Destroy + exit). Bureau never kills the window.
    Terminal close cascades to the shell — EXCEPT the kernel
    gap: endpoint teardown does not fail OTHER threads queued
    on it, so the shell stays blocked in its read call (inert,
    no CPU) instead of being failed awake. Deferred: endpoint
    finalization should fail/wake queued callers.

    32b: directory enumeration + the Amiga C: layout. File
    protocol gains Op_ReadDir = 13 (words 0..3 = path, "" =
    volume root, word 4 = index -> status/size/is_dir/name[24]
    in words 3..5; stateless per-index, Not_Found ends it).
    fat32 walks the chain skipping deleted/LFN/label entries
    (LFN run supplies the name when present); the file server
    forwards FS volumes only. Burn: Resolve_Volume REJECTED
    volume-only names ("BD0:") — Colon = Len meant "empty
    path" — which is exactly what readdir-of-root needs;
    relaxed (downstream ops already reject empty paths
    themselves). New crate userspace/dir -> Sys:C/Dir (user
    ruling: user-space commands live in C/, Amiga-style);
    the shell resolves bare names against the volume root
    then C/ ("Dir" just works). Verified live: Sys:> Dir
    lists README.TXT 37, BIG.BIN 65536, SUBDIR (dir),
    LongFileName.txt 23 (LFN!), System (dir), C (dir) and the
    fuzz-created files. 174 PASS SMP1+SMP4, fuzz failures=0,
    host fsck clean.

33. Environment + command-line conventions (33a DONE): no
    process environment block, no argv in the spawn ABI —
    Amiga-style, everything is a file or a cap. VARIABLES ARE
    FILES (the ENV:/ENVARC: analog): BD0:Prefs/Env/<NAME>
    holds the value, global by construction so nested shells
    and spawned programs all see the same world. Shell
    builtins: set [N=V] (bare set lists NAME=value via
    Op_ReadDir), get N, unset N, path (shows the command
    search path). Command resolution: the Path variable holds
    ';'-separated directory prefixes (e.g. "C/;System/"),
    default = volume root then C/ when unset; qualified names
    (with ':' or '/') go straight through. ARGUMENTS ride a
    one-page memory object at grant handle 4 (NUL-terminated
    string, Map+Read, the Amiga command-line analog; absent =
    no args), read via Syscalls.Read_Args. New crate
    userspace/type -> Sys:C/Type streams a file to the
    console in 32 KiB chunks; Dir takes an optional directory
    argument. TWO burns: (1) Args_VA first picked 0x4600_0000
    — EXACTLY the userspace link base; Read_Args unmapped the
    caller's own .text (now 0x4800_0000; fixed VAs must be
    checked against linker-riscv64.ld). (2) the init-stack
    burn redux: Type's 32 KiB chunk buffer sat in the MAIN
    procedure's declarative part — a 32 KiB stack frame over
    16 KiB of mapped stack (4 pages) — store fault at the
    first call, hart-halting trap. Buffers that size must be
    genuinely library-level (a package spec), not just
    commented that way. Verified live: set/get/set-list
    (GREETING=hello), path, Type README.TXT, Dir System (.
    .. Bureau 55736 Terminal 61160 Demo 32848 Shell 63840
    Startup 42). 174 PASS SMP1+SMP4, fuzz failures=0, host
    fsck clean. Next: the deferred list (assigns C:/ENV: as
    VFS aliases stay deferred until a second volume pulls
    them).

34. Endpoint teardown failing of queued callers (DONE): the
    orphaned-shell burn — a shell whose terminal closed stayed
    blocked in its read call forever because endpoint finalizers
    only fired at refcount zero, and the client's Send caps keep
    the endpoint referenced. Endpoints now carry a Failed flag:
    closing a Receive-right endpoint cap with Thread_Dying calls
    Kernel.IPC.Fail_Endpoint — queued callers and the waiting
    receiver wake with Result_Endpoint_Gone, fresh Call/Receive
    fail immediately with the new Endpoint_Gone status (maps to
    the same user code 3). Send-only caps never fail an endpoint
    (a dying client must not kill a shared service). TWO burns:
    (1) Cleanup_Cap_Refs — the voluntary Process_Exit path —
    closed caps WITHOUT Thread_Dying => True (only Discard_Slot
    passed it, since 31a), so Fail_Endpoint was unreachable for a
    voluntarily exiting server; both teardown paths now pass
    True. (2) Max_Process_Slots 16 was silently full (boot set
    occupies 15) — the four-child teardown test hit No_Slot;
    now 32. Test peer userspace/teardown (role via spawn args:
    R receives once and exits without replying; C calls and
    reports its wake code over a badged result endpoint) driven
    by a deterministic fuzz choreography: two queued callers, a
    receiver that takes the head and exits -> awaiting caller
    wakes Reply_Gone (4), queued caller Endpoint_Gone (3), and
    a late caller spawned after the death fails immediately (3).
    Test-observer burn: the reporters Call the result endpoint
    and the fuzzer must REPLY (a0 = Reply_Cap_Handle 254) or the
    last reporter parks awaiting reply and reaps Not_Exited.
    Also: SMP1 yield loops donate full timeslices to the Spin
    hog — keep settle loops at hundreds, not thousands. 192
    PASS SMP1+SMP4, fuzz failures=0, host fsck clean. Live:
    nested System/Terminal + close gadget destroys the window
    and the parent shell stays healthy.

35. Plain send (DONE): syscall 29, the Call send-phase only — the
    sender queues (or hands off directly to a waiting receiver)
    and blocks only until a Receive takes the message; no reply
    cap is minted and the sender wakes with Ok. Implementation
    reuses the whole call machinery: callers record Reply_Wanted
    on the TCB at Call (True) / Send (False) time; the dequeueing
    Receive reads it — mint the reply cap and leave the caller
    parked (call), or wake the sender with Ok immediately (send).
    Direct handoff returns Ok without blocking. Endpoint teardown
    and the failed-endpoint fast path apply unchanged (same
    caller queue; Send checks Failed like Call). A receiver
    cannot tell call from send except by replying — which fails
    with Invalid (1, the no-reply-cap code; there is no distinct
    user-visible Reply_Missing code — Set_IPC_Result maps it to
    Invalid, and the early fuzz tests already assert that).
    Test: teardown peer role "S" (send a marker, then report the
    result code on the badged result endpoint): queued delivery
    preserves words+badge, reply-after-send rejected, sender
    woke Ok, send on the failed teardown endpoint rejected
    immediately (Endpoint_Gone). 8 new checks, 200 PASS SMP1 /
    199 anchored lines SMP4 (delta = serial garbling; all check
    strings present), fuzz failures=0, host fsck clean.

36. Assigns (DONE): Amiga-style session path aliases, pure
    userspace. The file server (VFS) holds a global in-memory
    assign table; every Resolve_Volume call site now goes
    through Resolve_Full — on a volume miss the NAME: prefix
    is matched case-insensitively against the table, the
    target substituted (implied "/" between target and rest:
    C:Dir expands Sys:C/Dir), and resolution retries
    depth-capped at 4 (assign loops just fail Not_Found).
    Expanded names ride a 96-char buffer; all five path
    handlers (stat/open, read, write, readdir, path-ops)
    forward the EXPANDED path to fs drivers. Wire ops:
    Op_Assign = 14 (words 0..1 name, 2..5 target; empty
    target removes) and Op_Assign_List = 15 (stateless
    by-index, "NAME: target" packed in reply words 1..5 —
    word 0 stays the status). Mounting the sys-labelled
    volume seeds C: -> Sys:C and ENV: -> Sys:Prefs/Env
    (skipped when already set). Shell builtin assign: bare
    lists, "assign NAME: TARGET" sets, "NAME: REMOVE" drops.
    Rejected design: file-backed assigns (Prefs/Assigns/<N>)
    — persistence for free, but every lookup through an
    alias costs an open+read round-trip to the fs driver
    and Amiga assigns are session objects anyway; startup
    files can recreate them. Test burn: the fuzz ENV: check
    first failed because Sys:Prefs/Env only exists after a
    shell runs (the shell Mkdirs it lazily) — the test now
    mirrors that (Mkdir ignoring status) and exercises
    write/stat/delete THROUGH the alias, verifying bytes
    land at the direct path. 11 new checks, 212 PASS
    SMP1+SMP4, fuzz failures=0, host fsck clean. Live: the
    shell's assign lists "C: Sys:C" / "ENV: Sys:Prefs/Env"
    and Dir C: lists Sys:C.

    MILESTONE 37a — kernel process introspection syscall
    (first half of the deferred introspection item; the
    userspace Proc: fs driver is 37b). Sys_Process_Info =
    30: (a0 = resource cap, a1 = slot 0..31 or U64'Last for
    self, a2 = buffer memory-object cap, a3 = byte offset)
    writes a 64-byte binary snapshot through the physmap
    (per-word writes, frame straddle free). Words: process
    id, SPAWNER process id (new PCB field recorded at
    Spawn_Image from the parent's PCB; 0 = kernel-started),
    lifecycle, thread state, cap count, flags
    (awaiting-reply/reply-wanted/boosted/queued), blocked-
    on receive endpoint, call badge. Authority reuses the
    device_resource Kernel_Object+Manage gate
    (Has_Device_Resource, same as io_map/irq_create) —
    init grants it down via the plain device_resource
    manifest token. Statuses: 0 ok, 1 no-such-slot
    (enumeration end; the walk is 32 fixed by-index
    queries over the sparse table, same idiom as
    Op_ReadDir), U64'Last auth/cap/offset. Self queries go
    through the caller's own TCB/PCB so kernel-started
    processes (init, no table slot) answer too. Slot ids
    (pid = slot + 4) alias across slot reuse after reap —
    accepted for live-set display. Burns: (1) initrd's
    System/Manifest is GENERATED by the Makefile recipe —
    editing initrd/root directly loses the change on the
    next build (cost one full suite run of every-valid-
    call-returning-Failed); (2) Integer_Address has no +
    operator in arch-traps — do address arithmetic in U64
    and convert once. Fuzz: device_resource granted at
    handle 7 (manifest order); directed checks cover
    auth/buffer/offset/range rejection, self snapshot,
    32-slot walk (states in range, pids unique, self
    present, exactly one live child linked by spawner =
    echo); random phase widened to mod 31 (28 cap_mint and
    29 ipc_send stay excluded: slot leaks / can block).
    227 PASS SMP1+SMP4, fuzz failures=0, host fsck clean.
    Deferred consciously: cap-table and register dumps
    (admin-only when they land — a dedicated introspection
    cap kind, not the reused device_resource gate), a
    Proc:self alias (needs client identity forwarded
    through the VFS layer), generation counters on pids.

Commit between each milestone.

## Deferred (do not build yet)

- Block device caches, and an explicit sync op/ecall (noted during
  20c: the FAT driver writes through on every op). FAT32 metadata
  cache + Op_Sync passthrough landed in 22; still open: write-back
  policy, device-level cache shared across fs drivers, real flush
  (VIRTIO_BLK_F_FLUSH), block-layer sync op.
- Register fast path, >4 caps/msg.
- Kernel introspection syscalls for init state reconstruction
  (37a landed: process_info process/thread snapshots with
  spawner ids; still open: cap/register dumps — admin-gated —
  endpoint/notification object listing, scheduler stats).
- Finer-grained kernel locking / per-hart runqueues if hart counts
  grow (BKL serializes all kernel execution; fine at hobby scale).
- Tasking runtime; uniform program ABI (milestone 31b: one
  namespace for every program, windows open only via
  Surface_Create); pointer events to focused clients (v3 input
  queue carries keys only; pointer is Bureau-internal for
  focus/raise/drag); zero-copy direct scanout of full-screen
  client surfaces; MSI-X for virtio-pci (INTx today, shared
  chains); per-device IOVA spaces (IOVA = PA identity today).

## Start by reading

- `docs/IPC.md`
- `src/kernel/kernel-ipc.*` (existing scaffold)
- `src/kernel/kernel-capabilities.*` (Duplicate/minting basis)
- `src/kernel/kernel-objects.*` (cleanup dispatcher, object kinds)
- `src/kernel/kernel-tasks.*` (cap table ownership, thread access)
- `src/arch/riscv64/arch-traps.adb` (syscall dispatcher)
