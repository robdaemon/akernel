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

    MILESTONE 37b — Proc: introspection volume. New crate
    userspace/procfs (System/Procfs in the initrd, manifest
    program 7: console, procfs_server = endpoint Receive,
    device_resource = introspection authority) speaks the
    file protocol subset (stat/open/read/readdir, read-only
    like boot-file volumes); init mints PROCFS_EP at boot
    and pushes Op_Add_FS (device+label Proc, ci) right
    after spawn — the plain FS-driver volume path, zero VFS
    changes. Every op renders fresh from process_info
    snapshots (32-slot walk per render, binary in the
    kernel, text in userspace): "" -> dir ("tree" + one
    pid-named dir per live process), "tree" -> the forest
    indented by spawner (roots = spawner dead or kernel),
    "<pid>/status" -> key-value lines (process, spawner,
    lifecycle, thread, caps, flags decoded, endpoint,
    badge). Dir stat/open rejected Bad_Args, fat32-style;
    mutating ops Bad_Args. Read slices the render at
    offset/length; a death mid-read truncates, never
    wedges. Burns: (1) fileserver Max_Files 16 was
    SILENTLY FULL — System/Procfs made 17 boot files and
    Tests/Teardown (last in cpio sort order) lost its
    name-table slot; surfaced as teardown Stat Not_Found
    long after the Proc checks passed (now 32, same shape
    as the milestone-34 slot burn); (2) fuzz-side slice
    length mismatch (7-slot target, 6-char source) raised
    Constraint_Error and wedged the suite SILENTLY —
    unhandled exceptions in a test peer just stop it;
    (3) QMP pointer press must be sent as separate
    move/down/up events with settle time — a batched
    batch coalesces in place to buttons=0 and no
    focus/click ever registers (RESUME already knew the
    HMP mouse_move variant); (4) ':' is UNINJECTABLE via
    synthetic input under VNC: shift+semicolon loses the
    shift across QMP input-send-event, HMP sendkey AND
    raw RFB keysyms (0x3a and 0xffe1+0x3b) while other
    shifted chars work — interactive Dir Proc:/Type
    Proc:tree verification needs GTK (milestone-31 path);
    the shell round-trip itself (echo, spawn, fs error
    path) verified live, and the 23 new protocol checks
    drive the exact ops Dir/Type issue. 262 PASS
    SMP1+SMP4, fuzz failures=0, host fsck clean.

    FOLLOWUP (Dir fix + headroom): Dir prepended BD0: to
    any argument not literally starting "BD0:" —
    "Dir Proc:" listed BD0:Proc: (nothing), same for
    C:/ENV:. Now any arg containing ':' is fully
    qualified, and a first-entry ReadDir failure prints
    "Dir: can't open <path>" instead of silent empty.
    Headroom bumps: fileserver Max_Files 32 -> 128,
    kernel Max_Process_Slots 32 -> 128 with an O(1) free
    list (spawn PEEKS Free_Head, pops at the commit point
    so Load_Failed early returns need no undo;
    Discard_Slot pushes only for a committed slot — the
    Scheduler_Failed path discards uncommitted slots),
    scheduler Max_Tasks 32 -> 144. BIG burn: the
    fileserver's client-buffer window address was DERIVED
    from Max_Files (File_Win_Base + Max_Files *
    Slot_Stride) — the bump slid Buf_Win_VA/Blk_Buf_VA
    onto the user TEXT base 0x4600_0000, and the server
    copied file data over its own code. Every data-copy
    check failed (fs reads, blk/part volume IO, memstage
    staging) while stat/open passed; kernel reverts did
    nothing, stash-control proved the baseline green, and
    the fix is fixed window addresses in the heap/text
    gap (0x4040_0000 files, 0x4240_0000 buffers) plus a
    compile-time Windows_Fit division-by-zero guard so a
    future bump fails the BUILD instead of the tests.
    Lesson: VA windows must be fixed literals with a
    static overlap guard, never derived from table
    sizes; when data-compare checks fail across several
    servers at once, suspect a shared server's mapping
    layout before the kernel. 261 PASS SMP1+SMP4 (same
    as the pre-change baseline), fuzz failures=0, fsck
    clean.

    MILESTONE 38 COMPLETE (a: f9d3a6a, b-core: 48da866,
    b-tests: a29864d) — file headroom end to end.
    (a) kernel boot_files 24 -> 256 (the board refused
    to boot past 24, Bad_Image — the worst failure mode
    in the system; static-table bumps must fail the
    build or scale by RAM). (b) DYNAMIC PAGED CAP
    TABLES: 16384 handles/process, 128-entry PCB root
    (~1.5 KB replaces 10 KB static, ~1 MB BSS saved),
    128-cap pages PMM-allocated via physmap, freed at
    last close / teardown; Cap_Entry forced to exactly
    32 bytes by rep+size clause — a compile-time guard,
    because assertions are OFF in kernel builds and the
    pragma-Assert guard never fired when a 40-byte
    entry spilled slot 127 past the 4 KiB frame into
    the next frame, wiped by its Zero_Page. Also
    pinned Address_Space_Cap_Handle to literal 255
    (Handle'Last silently moved it under userspace's
    hardcoded AS_Cap). (c) Fileserver per-file VA
    windows DELETED: one shared 256 KiB window mapped
    on demand per Op_Read, chunked passes for larger
    files, lazy lead-in; name table 512 RAM-only.
    (d) Tests: 64 generated initrd files
    (Tests/Gen/fNN, Makefile recipe) push every table
    at once; fuzz stats all + reads f42 content; cap
    stress mints/closes 300 memobjs (crosses cap pages
    1 and 2, table reusable after); FAT32 64-file
    create/walk/count/delete proof on BD0:STRESS with
    a walk-by-actual-name leftover sweep. 272 PASS
    SMP1+SMP4, fuzz failures=0, fsck clean.
    38b burns, in order of pain:
    - Bootinfo was silently FULL at 63 entries (one
      page): 81 files pushed device_resource and late
      program images off the end -> "missing
      device_resource", unbootable. Now up to 8 pages
      mapped contiguously on demand (511 entries).
    - Spawn grant lists cap at 32 (one IPC page):
      boot_files grants don't scale. Boot-file caps
      now ride WITH their Op_Set_Name messages (init
      Cap_Mint + transfer + delete; fileserver keeps
      the received cap as the file). Scales to 256.
    - A SILENT last_chance handler turned every
      userspace exception into an invisible system
      wedge (the "adjacent source lines never
      executed" paradox = somebody crashed). It now
      prints LCH:<file>:<line> via the debug putchar
      ecall (no console server) before yielding.
      First catch: "Tests/Gen/f00" is 13 chars, not
      12 — Constraint_Error at block elaboration.
    - 16 KiB user stacks were tight: cumulative
      sibling declare-block locals + deep RPC chains
      overflowed by 64 bytes once test blocks grew.
      Spawn now maps 8 stack pages (32 KiB).
    - fat32 ReadDir never skipped "."/".." — the
      milestone-32 root walk can't see them, any
      subdir count is off by 2. Fixed.
    - A mutating FAT op costs ~0.4 s under
      write-through sync and the cost scales with FAT
      size: the designed 300-file proof (900 ops)
      blows the suite budget; shipped 64 (crosses
      every 32/63 boundary; FAT32 has no count
      table). Re-raise when write-back caching lands.
    - QMP "info registers" mid-hang names the
      spinning process/pc when the UART goes quiet.

    MILESTONE 39 COMPLETE (a: 0b37978, b: a6800a0,
    c: 29392a8) — admin-gated introspection dumps.
    The design below shipped unchanged:
    - No user model in the kernel, ever: authority =
      holding a dedicated ADMIN_OBJECT cap kind (empty
      object, existence only). Kernel mints one at boot
      into init's bootinfo ("admin"); init is root by
      construction. A future user/login model = which
      process init delegates to; zero kernel changes.
    - Gate: Kind = Admin_Object + Rights.Manage.
      Sys_Process_Info (37a) keeps its device_resource
      gate — harmless metadata, already shipped. The
      dumps (cap tables, registers) are the sensitive
      ones; kernel addresses in dumps are fine (admin
      is omnipotent by definition).
    - Sys_Cap_Info = 31: (admin cap, slot or U64'Last
      self, cap index, buffer memobj, offset) ->
      64-byte record (handle, kind, rights, object PA,
      badge, valid); sparse by-index walk over the
      16384-handle space, Not_Found on empty slots.
    - Sys_Thread_Regs = 32: (admin cap, slot, thread
      index, buffer memobj, offset) -> 256-byte
      trap-frame snapshot (31 GPRs + sepc +
      sstatus/scause). BLOCKED threads only — a running
      thread has no stable frame; Busy status, no
      cross-hart stop-the-world.
    - Manifest token `admin`; holders: procfs
      (renders Proc:<pid>/caps and <pid>/regs), fuzz
      (tests).
    - Tests: fuzz walks own caps, count matches
      cap_count from process_info (two syscalls
      cross-checked); reg dump of a blocked teardown
      peer (sepc in text range, sp in stack window);
      denials: no cap / minted-without-Manage /
      wrong-kind -> status 1.
    - FOLLOW-UP (userspace-only, after 39): elevation
      = System/Elevated daemon holds the admin cap;
      Sys:C/Elevate is a dumb client that calls it
      ("Elevate ShowCaps 7"). Elevated applies policy
      (today: allow + log; later: Prefs/Sudoers,
      console confirmation, session-badge checks —
      kernel badges authenticate the caller for free),
      stages+spawns the target with admin in ITS grant
      list (memstage pattern), replies with exit
      status. The admin cap NEVER lands in the
      client's namespace; spawner pid shows the
      elevation in Proc: tree. Hygiene: Elevated mints
      child copies WITHOUT Transfer so children can't
      re-delegate; Transfer stays on init's bootinfo
      copy (and Elevated's, for minting). Revocation =
      kill Elevated / stop delegating.
    39 shipped notes: Admin_Object added LAST in the
    Object_Kind enum (positions ride the bootinfo
    wire); admin cap = init bootinfo handle
    File_Count+2 with Manage+Transfer; manifest token
    `admin` flows through init's generic bootinfo
    token path (zero init.adb changes); holders:
    procfs (handle 4), fuzz (handle 8).
    Proc:<pid>/caps renders a sparse cap walk,
    <pid>/regs the saved frame or a "thread live"
    line. Fuzz: 11 admin checks (denials, entry
    fields, cap walk count == process_info count,
    blocked-echo frame dump, running = Busy) + 8
    proc caps/regs checks. Burns: (1) the admin echo
    needed its OWN endpoint — a second receiver on
    the shared EP steals Echo_Process's rounds and
    a dying receiver fails the endpoint (M34),
    cascading into every later echo check; (2)
    bare-yield reap polls outrun a console-printing
    child under SMP4 — pace with per-round checks;
    (3) drive IPC calls with cleared message
    registers — echo round 3 echoes stale caps
    words. 303/304 PASS SMP4/SMP1 (one-check delta
    = UART line interleave), fuzz failures=0, fsck
    clean.

    MILESTONE 40 COMPLETE (a: 4570ceb, b: 86b80a5,
    c: 64b4996) — the userspace RTS, replacing the
    hacked-together per-crate compilation of
    userspace/rts/akernel sources.
    (a) RTS as a static library:
    userspace/rts/akernel_rts.gpr builds
    libakernel_user.a ONCE (glue asm, s-memory heap
    override, vendored -gnatg runtime units, all
    Akernel_User.*); the abstract base project
    akernel_program.gpr carries Languages/Target/
    Runtime/linker-script/Create_Missing_Dirs so a
    program crate is ~10 lines. Stays on the stock
    light-rv64imafdc GNAT runtime (user-confirmed);
    a custom GNAT runtime (runtime.xml + rebuilt
    adalib) is recorded as the deferred purist
    upgrade.
    (b) Akernel_User.CLI — the amiga.lib analog for
    C: commands: Argument/Arg_Count over the args
    page, Get_Env/Set_Env over ENV: files,
    Fail_With/Exit_With, Amiga return codes
    RC_Ok/Warn/Error/Fail = 0/5/10/20 (adopted).
    Exit codes are REAL: the exit syscall's a0
    rides into a new PCB Exit_Code field and reap
    returns it in a1 (new asm stub saves the out
    pointer before the ecall clobbers a1);
    teardown peer role "X <n>" exits with <n>, fuzz
    reaps and checks 42.
    (c) Makefile crate inventory lists
    (INITRD_CRATES/DISK_CRATES_SYSTEM/DISK_CRATES_C
    + generic build/install/clean rules; 21 stanzas
    deleted) and `make new-crate NAME=foo DEST=c|
    system` scaffolding (crate dir + alire.toml +
    gpr + CLI skeleton main + Makefile registration,
    auto-installed into Sys:C/ or Sys:System/).
    Burns: (1) gpr project extension does NOT
    propagate Exec_Dir — the 40a base project's
    Exec_Dir was silently ignored and gprbuild
    linked into obj/, leaving pre-migration ELFs in
    bin/userspace; invisible while 40a changed no
    sources, caught the moment 40b touched fuzz.adb
    (new check strings absent from the ELF). Every
    crate carries its own Exec_Dir line now; the
    40b suite run is the first one on genuinely
    post-migration binaries. (2) alr/gprbuild
    up-to-date hashing is timestamp+hash based — a
    fresh-looking "up to date" can still mean
    stale; verify the ELF contains new strings
    (strings(1)) before blaming the runtime. 307
    PASS SMP1, 305 anchored SMP4 (deltas = UART
    interleave, strings present), fuzz failures=0,
    fsck clean.

    MILESTONE 41 (scoped, user-confirmed) — the
    base command set (Amiga C: reference, OS 3.x),
    built on the milestone-40 RTS: `make new-crate
    NAME=x DEST=c` + Akernel_User.CLI per command.
    SLICES:
    - 41a protocol ops + first commands: Op_Rename
      (VFS forward + fat32 dirent name/LFN-run
      rewrite — NOT copy+delete, that breaks dirs)
      and Op_VolumeInfo (fat32 already tracks the
      FSInfo free count; passthrough) added to the
      file protocol with fuzz checks; then Copy,
      Delete, Rename, MakeDir, Info.
    - 41b session/vars become COMMANDS: set/get/
      unset/assign leave the shell (they are
      file/protocol-backed globals — Amiga splits
      exactly this way: locals are builtins,
      globals are commands); shell thins. Plus
      Echo, Which (reuse the shell's Path search),
      Version (command form), Fault (RC -> text,
      RCs are real since 40b).
    - 41c data commands: Join (concat), Search
      (grep-lite), Sort (lines), List (ReadDir +
      Stat details: sizes/dates).
    CONSCIOUSLY DEFERRED (named prerequisites, not
    41):
    - CD / relative paths: NO cwd exists anywhere;
      per-process cwd is Amiga-fundamental but
      ENV: is global (naive ENV:CWD breaks nested
      shells) — design + shell milestone.
    - Script interpreter: Execute, If/Else/EndIf,
      Skip/EndSkip, Lab, Quit, FailAt, Alias,
      Prompt, Resident, Why (System/Startup is
      already a degenerate script).
    - Pipes/redirection: cheap architecturally
      (spawn with console Send at a shell-served
      capture endpoint, no kernel work) but shell
      plumbing, with the script/shell milestone.
    - Job control: Run (background), Break (needs
      process signaling — no kill-from-outside
      syscall), Status as a real job list (a thin
      Proc: walker version may ride 41c).
    - Clock group: Wait (uptime/timer-tick
      syscall), Date/Time/SetDate/SetClock (no
      RTC; dirents stamp fixed 2025-01-01).
    - Avail: PMM stats introspection syscall
      (rides the deferred scheduler-stats item).
    - Ed/Edit/MEmacs: editor milestone (terminal
      exists).
    SKIPPED FOREVER (no such hardware concept):
    printer (PrintFiles/PRT:), sound/speech (Say),
    requesters (RequestChoice/RequestFile),
    palette/overscan/pointer/screenmode/font prefs,
    Workbench (LoadWB/WBRun/IconX), CPU/SetPatch/
    NoFastMem, Mount (boot protocol does mounts),
    DiskChange/Lock/Format/Install/AddBuffers/
    RemRAD, MakeLink (FAT has no links). LATER:
    MultiView + AddDataTypes (datatypes).

    41a SHIPPED (a328369) — Op_Rename=16 +
    Op_Volume_Info=17, then the first commands.
    Op_Rename: FROM in words 0..5, TO NUL-
    terminated in the client buffer cap (Op_Write
    shape); the VFS resolves BOTH volumes (cross-
    volume Bad_Args), rewrites the buffer volume-
    stripped, forwards. fat32: Create_Link_Entry
    (Create_Entry's short/LFN-run machinery minus
    allocation) preserves cluster+size+attr;
    Fix_Dotdot points a moved directory's ".." at
    the new parent; old run deleted WITHOUT
    Free_Chain; case-folded ancestor guard.
    Op_Volume_Info: (status, total, free, cluster
    bytes) from BPB geometry + FSInfo sector read
    fresh (free = U64'Last unknown); Total_Sectors
    now saved at probe. RTS: Files.Rename/
    Volume_Info; Ensure_Buffer factored out of
    Open. Commands (make new-crate, Sys:C/): Copy
    (32 KiB heap chunk loop, truncates an existing
    destination), Delete/MakeDir (multi-arg, worst
    RC wins), Rename, Info (default Sys:). Fuzz:
    16 rename/info checks + a C:-command end-to-
    end (Sys:C/Info staged off disk, spawned under
    the uniform ABI, reaped, RC_Ok checked).
    Burns: (1) the command child prints ~6 console
    lines — the bare yield-per-try reap poll
    outran it under SMP4 AGAIN (the 39b echo2
    burn); batched 32 yields per try, and the RC
    check must not pass on the initialized 0 when
    the reap itself failed (check CI_Done AND the
    code). (2) IPC.md's op list had silently gone
    stale (13..15 missing) — op additions update
    docs/IPC.md in the same commit. 332 PASS
    SMP1+SMP4, failures=0, fsck clean.

    41b SHIPPED (17c6b7c + mkdisk followup) —
    set/get/unset/assign extracted to Sys:C/
    commands + Echo/Which/Version/Fault; the
    shell thins to help/exit + spawn with
    CLI.Resolve_Command (new: Path-variable
    search shared with Which). Fuzzer gained a
    Run_Command helper (stage from Sys:, spawn
    under the uniform ABI, reap, RC check) +
    directed end-to-end tests per command.
    Blocker fixed in 17c6b7c: Files.Write
    lazily allocates its shared client buffer
    (Set_Env calls Truncate not Open, so
    Buf_Cap stayed 0 and Write returned
    Bad_Args before sending — ENV: writes
    silently no-opped). tools/mkdisk.py
    generates the whole GPT+FAT32 disk without
    host sgdisk/mkfs.vfat/mtools (Makefile
    recipe prefers the host tools, falls back);
    getting it fsck/gpt-clean burned four
    layout bugs: (1) BPB SectorsPerTrack/Heads
    are TWO-byte fields — 1-byte writes shifted
    HiddenSectors/TotalSectors32 two bytes
    early and fsck read TotalSectors=1
    ("Failed to read sector 4294967295" at the
    last-sector access check; diff the BPB
    against a known-good mkfs image, do not
    guess); (2) subdir '.'/'..' were written
    into the cluster sector and then the entry
    flush OVERWROTE the same sector — one
    write per chain, dots lead the record
    list; (3) the LFN pad loop never appended
    the 0x0000 terminator (32 %% 26 = 6 path
    spins on 0xFFFF fill) — terminator first,
    then 0xFFFF to the entry boundary; (4)
    backup GPT header was assembled with
    4-byte pokes into 8-byte LBA fields plus a
    zero partition-entry-array CRC — both
    headers now come from one constructor.
    Plus: FAT32 root children carry '..' = 0
    (fsck rejects the root cluster NUMBER
    there), the backup boot sector + FSInfo
    mirror must exist at sectors 6/7, and the
    C: drawer outgrew one cluster (15 commands
    x 32 B + dots > 512) — directories are
    sized from their entry counts and span
    multi-cluster chains now. Suite verified
    on BOTH image sources: 423 PASS
    SMP1+SMP4, failures=0, host fsck.fat +
    sgdisk -v clean pre- and post-suite.
    MILESTONE 41c next: Join/Search/Sort/List.

    41c SHIPPED — the data commands. Join (f1 f2
    [...] TO out, case-insensitive keyword,
    truncate-overwrite, self-join rejected),
    Search (file string; case-sensitive substring,
    matching lines print; whole-file heap slurp,
    2 MiB heap cap = the size limit), Sort (from
    to; LF-line split, byte-wise insertion sort,
    every written line LF-terminated), List
    ([dir]; name + right-aligned size, "(dir)"
    tag — no date column, the protocol carries
    no timestamps). Fuzz: idempotent inputs
    rewritten per boot, Join/Sort verified by
    output readback, Search/List by exit code
    (console output is not capturable yet —
    pipes are the deferred shell milestone).
    Burns: (1) Sort's 4096-entry line table sat
    in the MAIN declarative part — 64 KiB on the
    32 KiB process stack, store fault below the
    IPC buffer page mid-suite; big tables are
    heap, ALWAYS (the Type burn class, third
    strike). (2) Op_ReadDir answers Not_Found
    for BOTH a missing path and an exhausted
    enumeration — List must Stat-probe the path
    first or a missing directory exits RC_Ok.
    (3) The Run_Command reap poll (512 tries x
    32 yields, sized for ~6-line 41a children)
    was outrun by List's ~21 console lines
    through the terminal-render pipeline under
    SMP4 — 2048 x 32 now. (4) make new-crate
    double-registered CRATES (its sed appended
    while DISK_CRATES_* already feeds CRATES) —
    the CRATES sed is gone; and tools/mkdisk.py
    had its own crate list drifting from the
    Makefile's — it parses DISK_CRATES_* out of
    the Makefile now (single source). 500 PASS
    SMP1+SMP4 on both image sources, failures=0,
    fsck clean pre/post suite. MILESTONE 41
    COMPLETE.

    42 SHIPPED — cwd + scripts. The cwd is the
    ENV:CWD variable (global like every variable,
    "BD0:" default): a child CD moves the
    parent's session, Amiga-style. CLI gains
    Get_Cwd/Set_Cwd/Join_Path/Normalize_Path/
    Resolve_Path; every path-taking command
    (Type/Copy/Delete/Rename/Makedir/Info/Join/
    Search/Sort/List/CD) resolves its args
    through Resolve_Path, and Resolve_Command
    tries the cwd before root and C/. Amiga path
    semantics: NO dot components — an EMPTY
    component ascends ("/" = parent, "//" =
    grandparent), ".." honoured as an alias,
    "." is just a name. Sys:C/CD: bare prints
    the cwd; the fat32 Stat tri-state is the
    validation (Not_Found = missing, Ok = FILE,
    Bad_Args = directory — Bad_Args is exactly
    the is-dir signal). Shell: prompt shows the
    cwd; new "execute <script>" builtin —
    LF-separated lines, ';' comments, stop at
    the first RC >= 10 (default failat), nesting
    capped at 4, scripts slurp through the heap
    (16 KiB cap); "Shell execute <script>" args
    = batch mode (run + exit with last RC) —
    the fuzz end-to-end path. Execute/Exec now
    RETURN the child RC (Reap_Process_Code in
    the shell too). Fuzz: CD/ENV:CWD checks,
    cd-slash, 1-cluster cwd-relative Copy +
    Delete with readback, failing dirs/files,
    script side effects verified (set inside a
    script lands in ENV:), failat stop verified
    (the line after the failure never runs).
    Burns: (1) Resolve_Path reads ENV:CWD
    THROUGH THE FILE SERVER — resolve AFTER
    Files.Bind, never in declaration-time
    constants (elaboration runs pre-bind and
    silently defaults to BD0:). (2) Test data
    must be ONE cluster: copying an ELF under
    test = ~129 write-through cluster ops x
    ~0.4 s and the phase ate the whole 300 s
    budget, presenting as a wedge at a random
    later test (the "mutating FAT op" burn,
    second strike — the log tail looks like a
    hang, it is a budget). 580 PASS SMP1+SMP4
    on both image sources, failures=0, fsck
    clean pre/post suite. MILESTONE 42 COMPLETE.
    Deferred shell groups left: pipes, job
    control, clock.

    43 SHIPPED — the Path search list +
    mkdisk.py removal. Sys:C/Path with the Amiga
    syntax: bare lists, "Path <dir> ADD",
    "Path <dir> REMOVE", "Path RESET". The list
    is ENV:Path (';'-separated prefixes) —
    GLOBAL like every variable; the Amiga keeps
    it per-process, which needs session identity
    we do not have (same ruling as ENV:CWD).
    Entries canonicalize at ADD: cwd-resolved,
    fully qualified, trailing separator,
    case-insensitive dedup (repeat ADD/REMOVE
    exit RC_Warn). Resolve_Command order is now:
    cwd FIRST ALWAYS (the Amiga current-dir
    rule), then Path entries when set — the list
    REPLACES only the built-in root+C: tail —
    else root+C:. Which shares Resolve_Command,
    so it reads the Path automatically. Burns /
    ops: (1) the Path list read must follow
    Files.Bind — the 42 elaboration burn nearly
    repeated in the first Path draft (List read
    in the declarative part). (2) The suite
    outgrew the 300 s harness timeout (666 PASS
    worth of spawns + write-through mutations):
    run the suite with timeout 420 now — a
    mid-staging stop with no LCH and no FAIL is
    a BUDGET, check wall-clock before bisecting.
    (3) USER RULING: tools/mkdisk.py is DELETED
    — host sgdisk/mkfs.vfat/mtools are required,
    the disk recipe fails cleanly without them;
    two image sources doubled verification cost
    and the generator kept accumulating layout
    edge cases. 666 PASS SMP1+SMP4, failures=0,
    fsck clean pre/post suite. MILESTONE 43
    COMPLETE.

    44 SHIPPED — cwd-centric path resolution,
    no default volume. Every CLI program (22)
    drops Files.Set_Default_Volume: user paths
    are cwd-resolved and fully qualified by
    CLI.Resolve_Path before they reach the file
    server, so the default-volume bind was a
    pre-cwd leftover. Akernel_User.CLI is now
    the ONLY owner of the boot-volume name
    (Boot_Volume = "BD0:"; Get_Cwd's default,
    and Resolve_Command's built-in tail tries
    "BD0:" & name then the C: assign — both
    fully qualified). Files.Set_Default_Volume
    stays as a low-level escape hatch (early
    boot, the fuzzer's intentional RD0 default
    tests) with a comment saying programs never
    call it. Dir was still pre-CLI (raw
    Read_Args, BD0:-prefixing): rewritten on
    the CLI package — no-arg Dir now lists the
    CURRENT DIRECTORY (the Amiga semantic), a
    missing dir exits RC_Error like List.
    666/665 PASS SMP1/SMP4, failures=0, fsck
    clean pre/post suite. MILESTONE 44
    COMPLETE.

    45 SHIPPED — elevation: System/Elevated +
    Sys:C/Elevate (the NEXT.md-39 design,
    userspace-only sudo). Elevated holds the
    admin bootinfo cap (Manage+Transfer) and
    serves the init-owned elevation endpoint
    (Send side via the "elevated_svc" manifest
    token / spawner chain: devmgr handle 4 →
    terminal → shell → commands at the UNIFORM
    ABI HANDLE 5). Elevate packs the command
    line into a one-page memobj, Calls
    (label 1, cap slot 0), exits with the
    replied child RC. Elevated resolves via
    the CLI resolver (global cwd/Path apply),
    stages+spawns with a Manage-only MINT (no
    Transfer — children can't re-delegate;
    elevated child ABI 1 console, 2 fs,
    3 args-dup filler, 4 args, 5 admin — grant
    indices are dense and Bureau is not
    Elevated's to give), reaps, replies the
    RC, deletes the transferred page. Policy:
    allow + log. Requests serialize. Protocol
    documented in IPC.md ("Elevation").
    BURNS: (1) initrd/root/System/Manifest is
    REGENERATED by the Makefile (rm -rf +
    printf lines) — edit the Makefile, never
    the file; a hand edit vanishes on the next
    build and the missing token presents as a
    Call that blocks forever (wrong endpoint
    object, no receiver). Diagnosis: admin
    Cap_Info object-address comparison from
    BOTH sides (client cap walk vs server's
    own handle) — different objects = wrong
    cap, same object = look elsewhere. (2) The
    uniform ABI must be UNIFORM for programs
    that are both Startup children and
    commands: the shell gets an (empty) args
    page at handle 4 from the terminal too, so
    the svc is handle 5 on every path —
    granting a right outside the source cap's
    rights fails the WHOLE spawn ("spawn
    failed: set" when the shell tried to grant
    its args page as the svc). (3) VA
    0x05C0_0000 sits inside the RTS heap —
    Mem_Map fails there ("Elevate: out of
    memory"); use the shell/devmgr-proven
    staging regions. (4) The List fuzz target
    BD0:C grew with every shipped command
    until the ~24-line listing outran the
    SMP4 reap poll — bound test output
    (BD0:SUBDIR, two files). (5) Harness
    timeout 420 → 600 s: run-to-run host
    variance alone swung 695 → 588 PASS at
    420 on identical bits; a mid-staging stop
    with no LCH/FAIL stays a budget. 694 PASS
    SMP1+SMP4, failures=0, fsck clean
    pre/post suite. MILESTONE 45 COMPLETE.

    46 SHIPPED — Amiga pipes end to end:
    PIPE: + NIL: virtual volumes (46a) and
    shell `|`/`>`/`<` redirection (46b).
    PIPE:name = 16 KiB FIFO ring in the fs
    (Fileserver_Pipes; Open ATTACHES+creates,
    Write appends all-or-nothing, Read pops,
    new Op_Close=18 signals writer EOF,
    Delete destroys, Truncate resets for
    reuse; POLL-AND-RETRY semantics — the
    kernel allows one outstanding reply per
    server thread, true blocking waits on
    kernel reply-cap duplication, deferred).
    NIL: discards writes, reads answer
    immediate EOF. Redirection rides the
    args-page trailer (magic + out/in path
    offsets at 4032): the RTS wires out_path
    into Console (4 KiB buffer, flush on LF,
    bounded Not_Ready retry, Close_Redirect
    at CLI.Exit_With = flush + pipe EOF) and
    in_path into CLI.Get_Line. The shell
    splits pipelines (up to 4 stages,
    concurrent spawns, last-stage RC,
    PIPE:SH<n> pool create+reset+delete,
    `>` truncates/creates) and Sort with no
    args is the stdin filter. BURNS: (1) RTS
    Open was Stat-based — pipes need a real
    Op_Open to attach/create. (2) Files.Read
    required Buf_Cap without Ensure_Buffer
    (Write had it) — a reader that never
    Opens (Get_Line on a pipe) ate Bad_Args.
    (3) Type predated the CLI (raw Read_Args
    + Process_Exit) — no trailer, no EOF;
    tap CLI.Arg_Count once + exit via
    CLI.Exit_With. (4) The shell args-copy
    loop indexed a null String on bare
    pipeline stages -> Constraint_Error (LCH).
    (5) String(0..4095) — String's index is
    Positive, CE at elaboration; the
    compiler warned, heed it. (6) Sort's 2
    MiB stdin buffer + 64 KiB line table
    exceeded the 2 MiB RTS heap cap ->
    Storage_Error; stdin cap is 1 MiB. (7) A
    multi-edit tool call that fails ANY edit
    rolls back ALL of them — a debug print
    "applied" earlier in the same call never
    landed; grep when instrumentation goes
    missing. 742/743 PASS SMP1+SMP4,
    failures=0, fsck clean pre/post suite.
    MILESTONE 46 COMPLETE.

    47 SHIPPED — kernel reply-cap
    duplication: recv now mints the reply
    cap in an ordinary FREE SLOT (one per
    received call, handle returned in a1)
    instead of clobbering fixed handle 254,
    so a server thread holds MANY
    outstanding reply caps and replies in
    any order; reply(a0 = the handle). The
    m34 lifecycle rides the existing
    cap-close hook unchanged (server death
    fails every pending target Reply_Gone;
    cap_delete = "drop this request").
    recv/Call/Send handoffs zero-or-set the
    woken receiver's saved a1; plain send
    and the synthetic notification message
    deliver a1 = 0. Every server migrated
    (reply handle is a per-request local);
    RTS IPC_Recv/IPC_Reply + the typed
    generic gained the handle. The latent
    handle-254 collision (ordinary Insert
    never skipped 254/255 — the m38 300-cap
    test's 254th cap would have been
    closed by the next recv mint) died by
    construction. Fuzz E2E: teardown peer
    role "D" receives two calls, holds
    both reply caps, replies second-first;
    both callers complete Ok with their
    order tokens (old kernel: caller one
    woke Reply_Gone at the re-receive).
    BURNS: (1) report ARRIVAL order is not
    reply order — woken threads
    head-insert into the ready queue (the
    rendezvous boost), so last-woken runs
    first; assert completion + payload,
    never inter-process arrival order.
    (2) demo.adb was missed in the server
    sweep (it Replys on Op_Read-like
    messages) — grep the syscall NAMES,
    not one spelling. 754 PASS SMP1+SMP4,
    failures=0, fsck clean pre/post suite.
    MILESTONE 47 COMPLETE.

    48 SHIPPED — virtio-blk write-back
    cache + the flush chain: 64 slots x
    512 B in a DMA object; WRITES copy
    client data into slots (client buffer
    mapped per-op through a one-page
    window — the transfer's full-rights
    copy carries Map) and reply with NO
    device op, so same-sector FAT
    metadata bursts coalesce; READS DMA
    miss runs straight to the client and
    CPU-copy only hit sectors (dirty
    wins), streaming stays uncached.
    Dirty reaches the device on LRU
    eviction, on loop-top WRITE-BEHIND
    whenever any is pending (a quiet
    system is a flushed system — a
    harness kill of qemu loses nothing),
    or on the new Blk_Flush = 4, which
    fat32's Op_Sync now drives through
    partmgr (m22's hook wired at last);
    VIRTIO_BLK_F_FLUSH (bit 9)
    negotiated, VIRTIO_BLK_T_FLUSH
    issued on explicit flush. BURNS: (1)
    the kernel REJECTS write-only
    Mem_Map ((Flags and 3) = 2) — the
    read-hit window must ask RW (Flags
    3); first attempt used 2 and every
    dirty-sector read-back failed io
    with no log line (silent-reply-1
    paths need a Debug_Put_Line). (2)
    measure before/after: time-to-
    fuzz-complete 465 s -> 425 s SMP1
    (~9%); the remaining per-sector
    write-back round-trips want a
    bigger virtqueue + batched
    submission (deferred). Fuzz: flush
    feature self-test line + write/
    dirty-read-back/Sync chain checks.
    758 PASS SMP1+SMP4, failures=0,
    fsck clean pre/post suite.
    MILESTONE 48 COMPLETE. Followup
    (same cycle): the m48b sizing probe
    (request counters, Debug_Put_Line —
    a console RPC from inside the block
    server re-created the m31 cascade
    wedge; servers never make blocking
    sink RPCs mid-request) measured:
    reads 9156 vs writes 1084 (9:1),
    absorbed=written 1:1 (NO same-sector
    coalescing in the suite), evictions
    0 — batched write-back submission
    REJECTED by data, not esthetics.
    Real waste found: Flush_Dirty issued
    a VIRTIO_BLK_T_FLUSH on EVERY idle
    write-behind (one per absorbed
    sector, 2x write cost) — device
    flush now explicit-sync only, which
    is hardware-honest layering
    (writeback = latency, durability =
    sync points, same as Linux); fuzz
    now ends with an explicit Files.Sync
    so the post-suite fsck validates
    the real durability chain instead of
    QEMU write-back coincidence. 425 s
    -> 373 s SMP1. Hardware gap logged:
    no shutdown path exists — power-off
    loses everything since the last
    Op_Sync; deferred milestone: clean
    shutdown (Op_Sync fan-out + SBI SRST
    + shell shutdown builtin). Next: the
    deferred list — blocking pipes (m47
    primitive ready), Proc:self (needs
    client identity through the VFS),
    clean shutdown, pid generations.

    49 SHIPPED — true blocking pipes:
    the m47 reply-cap primitive wired
    into PIPE:. A read on an empty
    non-EOF ring or a write that does
    not fit DEFERS: the fileserver
    stashes the request's reply cap AND
    client buffer cap in an 8-slot
    pending table (Fileserver_Pipes,
    BSS) and answers when the opposite
    side arrives. Ring mutations drain
    the table in passes until no
    progress (a completing read frees
    space for a pending write, a
    completing write feeds a pending
    read). Op_Close drains readers
    (data or Ok+0 EOF — the pipeline
    exit path), Op_Truncate drains
    writers, Op_Delete wakes everything
    Not_Found (the dead-reader escape
    hatch: the shell deletes pool pipes
    after every pipeline). Table full
    -> old Not_Ready poll answer, so
    client retry loops degrade, never
    hang. Protocol unchanged (m46
    promised exactly this swap).
    BURNS: (1) the two old single-
    process Not_Ready checks would HANG
    under blocking — audit every poll
    expectation when a primitive goes
    blocking; (2) Blk : String(1..16)
    := "blocked ok" (10 chars) — the
    m37b string-length CE again, LCH
    at the declare line, suite silently
    short; (3) fuzz's helper names
    (Discard/Done/Code) live in a
    SIBLING declare block, not outer
    scope — new blocks declare their
    own; (4) drain must run AFTER the
    current op's window unmap (it
    remaps the same Buf_Win_VA with
    stashed buffers). Directed tests:
    teardown roles P (blocked reader
    completes on write, bytes verified)
    and W (blocked writer completes on
    drain) spawned by fuzz, badge-
    distinguished reports, race-free
    by construction. 774 PASS SMP1+
    SMP4 (one SMP4 run 773 with two
    non-pipe lines lost to serial
    output noise, rerun full — the
    established m39/m46 pattern),
    failures=0, fsck clean.
    MILESTONE 49 COMPLETE. Next: the
    deferred list — clean shutdown
    (Op_Sync fan-out + SBI SRST +
    shell builtin), Proc:self (needs
    client identity through the VFS),
    pid generations, register fast
    path.

    50 SHIPPED — clean shutdown:
    Sys_System_Reset=33 (admin cap,
    reset type) drives SBI SRST
    system_reset (sbi_asm stub,
    Arch.SBI.System_Reset); admin-
    gated with the Cap_Info authority.
    New crates Sys:System/Shutdown +
    Sys:System/Reboot run ONLY under
    Elevate (admin mint at handle 5):
    sync fan-out (fileserver -> fat32
    -> partmgr -> virtio-blk ->
    VIRTIO_BLK_T_FLUSH), then reset.
    Invocation is plain Elevate
    Sys:System/Shutdown — NO shell
    builtins (review caught my
    convenience wrappers: the
    programs self-sync, so special
    shell handling duplicated logic
    for zero capability). DESIGN
    ANSWER
    (user asked): no signals needed —
    the filesystem is the ONLY cross-
    process durable state; every other
    process holds transient state and
    dies with the machine losing
    nothing. AmigaOS agrees (no
    signals, no shutdown handshake).
    Cooperative shutdown broadcast
    consciously deferred until a
    server holds in-memory state
    worth saving. E2E: the suite's
    last act IS the real chain —
    Run_Command Sys:C/Elevate
    Sys:System/Shutdown — so every
    make run now ends with qemu
    exiting 0 BY ITSELF after
    "kernel: system reset requested"
    (timeout 600 stays as backstop);
    the post-suite fsck validates
    durability across a TRUE power
    transition, not a SIGKILL race.
    Reboot shares the path (type 1);
    a full cycle is a manual test
    (automated would loop the suite).
    BURNS: (1) Elevated resolves the
    target through ITS OWN cwd —
    relative "System/Shutdown" failed
    silently (RC_Error, no log line
    before the resolution succeeds);
    pass full Sys:System/... paths
    like the existing Sys:C/Version
    elevate test does; (2) the old
    fuzz-exit test gave way to the
    shutdown (Process_Exit coverage
    lives in teardown roles); (3)
    interactive make run is GONE by
    default — the machine powers off
    right after fuzz complete; drop
    the Tests/Fuzz manifest program
    for an interactive boot. Gate
    tests: bogus admin cap and a
    non-admin cap both rejected.
    783 PASS SMP1+SMP4, failures=0,
    fsck clean (66 files), qemu
    exits 0 on both.
    MILESTONE 50 COMPLETE. Elevation
    has its first shipped consumer.
    Next: the deferred list —
    Proc:self (needs client identity
    through the VFS), pid generations,
    register fast path, custom GNAT
    runtime, virtio-net, MSI-X, true
    scheduler priorities; shell
    groups: job control, clock.

    51 SHIPPED — pid generation
    counters. pid = generation * 256 +
    slot base (slot + 4; pids 1..3 are
    the kernel-started processes
    outside the spawn table). First
    use of a slot = generation 0, so
    boot pids keep their historical
    values; every REUSE bumps the
    slot's generation, so a pid
    printed by Proc:, recorded as a
    spawner, or badged onto a process
    cap can never name a later
    occupant of the same slot. The
    generation array lives OUTSIDE the
    PCB (Initialize_Process overwrites
    the whole record) and wraps at
    2**23 (pid stays in 31-bit
    Natural; ABA needs 8M reuses of
    one slot — same class as Unix pid
    wrap). Thread ids left slot-
    derived (no identity consumer
    today). The m37a "pid aliases
    across reuse" acceptance is
    CLOSED. Fuzz: spawn -> reap ->
    spawn lands both teardown "X 0"
    peers in the same slot (the free
    list is LIFO and nothing else
    spawns in the window), checks the
    low byte encodes the slot base
    and pid2 = pid1 + 256 exactly.
    Latent nit logged, not fixed: the
    m37a "out-of-range slot" probe
    uses slot 32, which is a VALID
    index since the 128-slot bump —
    it passes only because slot 32 is
    empty at that point (status 1 =
    empty AND end-of-enumeration);
    a real out-of-range probe wants
    slot >= 128. 795 PASS SMP1+SMP4,
    failures=0, fsck clean, qemu
    exits 0 on both.
    MILESTONE 51 COMPLETE. Next: the
    deferred list — Proc:self (needs
    client identity through the VFS),
    register fast path (probe first),
    custom GNAT runtime, virtio-net,
    MSI-X, true scheduler priorities;
    shell groups: job control, clock.

    52 SHIPPED — shell job control,
    Amiga RUN lineage. Builtins: `run
    <cmd> [args]` backgrounds ONE
    command (pipelines/redirection
    rejected — Spawn_Cmd's single-
    command path only), `jobs` lists
    running/done, `wait [n]` blocks
    on one job (bare: all, slot
    order) and yields its exit code
    as the command RC — scripts
    compose with failat (a job RC 20
    stops the script). Job numbers
    are shell-local slot indices (the
    pid is unreadable from a proc cap
    without admin introspection —
    Proc:self would fix display). Job
    states: Free/Active/Done — a
    COMPLETED job keeps its exit code
    in Done until wait claims it;
    `run` allocates Free, then steals
    the oldest Done (code discarded,
    documented). `exit` with live
    jobs warns once (RC 5), second
    exit abandons (orphans are
    independent processes — Amiga
    RUN'd tasks survive the shell;
    the kernel collects them). BURN
    (caught by the suite, not
    shipped): my first Harvest had
    `jobs` REAP+FREE completed jobs —
    Script4's `jobs` then `wait 1`
    lost the exit code to "no such
    job". POSIX-honest rule: listing
    must never destroy a wait-able
    status. Also: wait must NOT
    pre-harvest — a completed job
    still holds its slot+code until
    somebody waits (Reap returns
    immediately on a dead child
    anyway). E2E: five batch-mode
    scripts through Sys:System/Shell
    — wait RC 20 stops at failat
    (ENV marker absent), RC 7
    continues (marker set), bare wait
    RC = last job (4 either harvest
    ordering), unknown job = RC 10,
    shell exits with a live job.
    848/847 PASS SMP1/SMP4 (one old
    fat-lfn line lost to serial noise
    twice, failures=0 — established
    noise class), fsck clean (72
    files), qemu exits 0 on both.
    MILESTONE 52 COMPLETE. The shell
    group is DONE (only clock left).
    Next: the deferred list —
    Proc:self (needs client identity
    through the VFS), register fast
    path (probe first), custom GNAT
    runtime, virtio-net, MSI-X, true
    scheduler priorities, clock.

    53a SHIPPED — full GNAT RTS for
    userspace (ZCX exceptions +
    finalization + secondary stack +
    binder init/final; Text_IO waits
    for 53b/newlib). User rulings:
    no more userspace programs until
    the RTS is done (existing ones
    migrate later); newlib YES (53b);
    vendoring runtime sources FINE;
    kernel STAYS on light-rv64imafdc;
    dynamic linking deferred-not-
    rejected (medany/medpic question
    lives there). userspace/gnat-rts/
    = embedded-polarfiresoc libgnat
    of Alire gnat_riscv64_elf 15.3.1
    (~959 files, board/calendar
    pruned) + gnat_user/ shadow dir:
    system.ads (Jorvik->No_Tasking,
    ZCX_By_Default), s-memory (our
    memobj free-list heap + Realloc),
    s-soflin (non-tasking soft
    links), s-init (no-op binder
    hooks), s-parame (sec stack
    64 KiB — pool's 512 KiB is a
    static .bss array PER PROCESS),
    s-sssita (only exists in the
    light pool), a-reatim (rdtime CSR
    x100ns), s-textio (debug
    putchar), a-elchha (prints LCH
    banner), akernel_glue.c
    (__gnat_exit, malloc/free shim),
    akernel_rtclock.c. ZCX via
    __register_frame: bare-metal ld
    2.46.1 has NO --eh-frame-hdr and
    gcc rejects -fsjlj-exceptions on
    this target, so crt0 registers
    .eh_frame (linker script exports
    __EH_FRAME_BEGIN__ + QUAD(0)
    terminator + KEEPs
    .gcc_except_table); pool's
    unwind-dw2-fde-bb.c deleted.
    Kernel: scounteren CY|TM|IR per
    hart (userspace rdtime);
    Max_Pages 64->256 (runtime ELFs
    stage at 300+ KiB); Stack_Pages
    8->12 (unwinder needs ~8 KiB on
    first raise; 16 would collide
    with the IPC buffer VA); USER
    STACKS NOW EXECUTABLE (User_RWX)
    — GNAT lowers Finalize_Address of
    nested FD procedures to GCC
    nested-function trampolines on
    the stack (static chain in t2);
    a non-X stack faulted on the
    first Controlled scope exit
    (sepc = a stack address).
    Makefile: strip on image install
    via `alr exec -- riscv64-elf-
    strip` (make run has no toolchain
    PATH); bin/userspace/*.elf keep
    symbols. FAT image now -s 8
    (4 KiB clusters): full-runtime
    ELFs are ~6x bigger and 1-sector
    staging reads blew the suite past
    900 s; batched 8-sector reads
    (the blk max and the fat32 bounce
    page exactly fit) brought SMP1
    back to 430 s. THREE bug sagas:
    (1) "first ZCX raise corrupts the
    heap" was NEVER the raise path —
    an m1-LATENT s-memory down-merge
    bug: the absorbed block stayed on
    the free list (two overlapping
    free nodes) until libgcc's FDE
    array fill spanned the phantom
    node; fixed by unlinking our
    block in the down-merge; found
    via alloc/free tracing + an O(n^2)
    overlap detector naming the
    creating op. (2) Controlled-type
    trap = the trampoline X-stack
    fix above. (3) "hangs" were pure
    slowness — blk was serving at
    timeout kill; marker chars F/3/B
    are hex digits and lie in
    positional analysis. Suite: +9
    checks (cross-frame raise +
    message/name, controlled
    init/fin scope-exit 11 and
    unwind 22, secondary-stack
    unconstrained return, Real_Time
    advance, LCH child via teardown
    role E). Echo m35 check relaxed
    to handle >= 3: crt0's frame
    registration malloc takes a
    memobj cap first. 857/856 PASS
    SMP1/SMP4, failures=0, fsck
    clean (72 files), qemu exits 0,
    430 s SMP1 / 75 s SMP4.
    53b SHIPPED — newlib for userspace
    + full Ada file I/O. The Alire
    toolchain already ships prebuilt
    newlib (libc.a/libm.a + headers,
    no libgloss), so: (1) the syscall
    layer is Akernel_User.Gloss, in
    ADA inside libakernel_user.a —
    _open/_read/_write/_close/_lseek/
    _fstat/_isatty/_sbrk/_exit/_stat/
    _unlink/_mkdir/_rename/getpid/
    gettimeofday/times real over
    Files/Console/Process_Exit, fork/
    exec/wait/kill/link/dup/symlink/
    chdir ENOSYS stubs, rmdir/access/
    getcwd/getppid/chmod/ttyname/
    sysconf/utimensat partial. fds
    0-2 = console (stdin EOF), 3-18
    = path+offset table over the
    stateless fs protocol; O_CREAT =
    1-byte write + truncate (fs
    creates on Op_Write, zero-length
    writes rejected client-side);
    stdout rides Console.Put so
    shell redirection composes.
    Lazy binding: first op binds
    uniform-ABI handles 1/2 ONLY if
    the program bound nothing itself
    — gloss.o is ld-u-pulled, never
    elaborated (not in the compile
    closure), and must not clobber
    custom grant layouts (fuzz keeps
    fs on 4). _sbrk arena at
    0x5200_0000 (16 x 256 KiB memobj
    chunks) — libgcc frame-reg
    malloc now lands there via
    newlib malloc; the GNAT heap
    stays untouched. (2) gnat_full/
    vendors the full I/O stack from
    the gcc-15.3.0 tarball (the
    toolchain is FSF 15.3.0 — Alire
    labels it 15.3.1): Text_IO +
    Integer/Float/Modular/
    Enumeration/Decimal_IO children
    (+aux/get_line subunit),
    Stream_IO, Sequential_IO,
    Direct_IO, s-fileio/s-crtl/
    s-ficobl/i-cstrea/s-os_lib/
    s-casutil/s-commun/s-direio/
    s-sequio/s-image[bdiurw]/
    s-img[biu/llb/llw/lls/uns], plus
    the C support layer adaint.c/
    cstreams.c/sysdep.c/targext.c/
    errno.c/env.c (STANDALONE build,
    minimal runtime.h, dir ops
    stubbed under AKERNEL_NO_DIRENT
    — newlib has no <dirent.h>;
    Ada.Directories gets fs
    Op_ReadDir in 53c; utime/
    clearenv no-oped; adaint-xi.c
    duplicate guarded). (3) Link
    wiring: GROUP(-lc -lm) in the
    linker script (gprbuild DROPS
    Linker'Linker_Options silently;
    Switches land before the
    runtime libs and single-pass ld
    then misses libgnat/libgcc's
    malloc/strcmp refs) +
    -Wl,-u,_sbrk to force gloss.o
    in (pulling it through the
    script GROUP stranded its
    libgnat refs). glue.c/runtime_
    stubs shed every libc shim
    (malloc/free/strlen/mem*/
    strcmp) — libc.a provides them;
    __gnat_getenv moved to env.c.
    crt0 now calls
    __libc_init_array and EXITS
    with main's status instead of
    yield-parking; init_array
    sections KEEPed. pool stub
    a-textio deleted; ada_source_
    path gained gnat_full (the
    "not a predefined library unit"
    burn). fuzz: +2 checks (Text_IO
    create/Put_Line/open/Get_Line
    round trip on BD0:FZTIO.TXT +
    delete; stdout Put_Line rides
    the console). 859/859 PASS
    SMP1/SMP4, failures=0, fsck
    clean, 350 s / 100 s. Latent
    nit: an unhandled-exception
    LCH traceback print wedged
    after "Call stack traceback
    locations:" once — unprobed,
    no test crashes remain to
    chase it with.     53c SHIPPED — standard-library
    environment, command line, and
    directories over the akernel
    conventions. Ada.Environment_
    Variables: env.c rewired
    (AKERNEL_ENV_FILES) to gloss
    helpers that read/write
    ENV:<NAME> files (m33a ruling —
    variables ARE files, shared with
    the shell's set/get/unset);
    Clear-without-Name deliberately
    no-ops (would delete CWD/Path).
    Ada.Command_Line: vendored
    argv.c (gnat_argc/gnat_argv);
    crt0 calls akernel_init_args,
    which tokenizes the m33a args
    page space-separated exactly
    like CLI.Parse_Args into a
    static 64x128 table; argv[0] =
    "" (the uniform ABI carries no
    program name), so Argument(N)
    numbers match CLI tokens.
    Ada.Directories: vendored
    a-direct + a-dhfina + a-dirval +
    s-filatt + the Calendar chain
    (a-calend/a-calfor/a-catizo +
    s-osprim posix + s-optide +
    cal.c; a-caldel DROPPED — needs
    tasking soft links); hand-grown
    gnat_user/s-oscons.ads (the
    embedded pool ships no
    OS_Constants: ENOENT=2,
    dirent/file_attributes buffer
    sizes); adaint's AKERNEL_NO_
    DIRENT stubs now call gloss
    akernel_opendir/readdir/closedir
    over stateless Op_ReadDir (DIR*
    = slot+1); __gnat_mkdir from
    vendored mkdir.c + a plain
    "mkdir" alias in gloss; gloss
    _stat probes Read_Dir when Stat
    says Bad_Args so directories
    stat as S_IFDIR (fs rejects dir
    stat fat32-style). cwd: gloss
    getcwd/chdir read/write ENV:CWD
    and EVERY relative gloss path
    qualifies against it (Amiga:
    "cwd/name", or "cwdname" at the
    volume colon). TWO POSIX-shape
    patches in vendored sources
    (documented, keep minimal):
    adaint __gnat_is_absolute_path
    — ':' before any '/' = absolute;
    a-direct Dir_Seps += ':' so
    Compose("BD0:","X") = "BD0:X"
    and Containing_Directory splits
    at the volume label. Without
    them Normalize_Pathname pre-
    pended cwd to "BD0:" (the
    "Sys:/Sys:" burn) and Compose
    built "BD0:/X" which fs rejects
    — Start_Search silently returned
    zero entries while the gloss
    walk itself worked (gdir prints
    proved it; Match "*" was never
    the problem). Also: s-soflin
    SPEC shadowed (pool dropped
    Dummy_Communication_Block; the
    expander needs it for
    controlled+interface dispatch
    tables from Ada.Containers.
    Vectors inside a-direct);
    s-parame gained time_t_bits=64;
    akernel_nanosleep.c (rdtime +
    yield) backs s-osprim
    Timed_Delay (newlib rv64 lacks
    nanosleep). Migration proof:
    Sys:C/Echo now lives on
    Ada.Command_Line + Ada.Text_IO
    (CLI.Init — new public op —
    parses the redirect trailer for
    programs that never touch CLI
    args; CLI.Exit_With still
    closes redirects). fuzz +7
    checks: env set/value/clear via
    ENV:, Echo argv through shell
    redirection read back from the
    output file, Directories
    Exists/Kind on file and dir,
    Start_Search walk (N=13),
    Set/Current_Directory round
    trip (cwd restore uses raw
    ENV:CWD bytes — a-direct's
    Set_Directory validates and can
    raise on legacy content).
    878/878 PASS SMP1/SMP4,
    failures=0, fsck clean, 375 s /
    95 s.     54 SHIPPED — the Sys:C command
    set migrates onto the standard
    library. Delete/MakeDir/Rename/CD
    ride Ada.Directories (Delete_File
    / Create_Directory / Rename /
    Set_Directory + Current_Directory;
    exceptions map to the Amiga RC
    codes); Dir/List ride Start_Search
    + Simple_Name/Kind/Size; Type/
    Search stream Ada.Text_IO Get_Line
    (Search shed its heap slurp and
    2 MiB file cap; Type KEEPS the raw
    Read_Args line — paths may contain
    spaces, unlike argv tokens);
    Copy/Join ride Ada.Streams.
    Stream_IO Create/Open/Read/Write
    (Create truncates — the old
    Stat+Truncate dance is gone;
    32 KiB chunk buffers on the HEAP,
    never the 12-page stack); Sort's
    filter-mode stdout is Text_IO
    (stdin STAYS CLI.Get_Line — the
    redirect-in trailer lives in CLI
    state, gloss can't see it). All
    keep CLI.Init + CLI.Exit_With;
    CLI.Init now ALSO lazy-binds the
    default handles (console 1, fs 2)
    with the gloss Ensure_Bound
    no-clobber rule, so programs
    dropped their Set_Endpoint/Bind
    boilerplate; Fail_With flushes a
    redirected tail before exiting.
    THE burn of the milestone: a
    past-EOF Files.Read answers
    Status_Out_Of_Range (4), gloss
    turned that into -1/ENOENT,
    newlib set the sticky ferror
    flag, and GNAT's Getc raised
    DEVICE_ERROR (a-textio:870)
    instead of a clean End_Of_File
    — every Text_IO read-loop over a
    file died after its last full
    buffer. One-line POSIX bridge in
    gloss _read: Out_Of_Range =>
    return 0. Found with a 20-line
    temp crate (rdtest: write 18
    bytes, Text_IO loop, crash on
    line 3) — 2-minute boot cycles
    vs 6-minute suite bisection;
    crate + Makefile wiring deleted
    after the fix. 878/878 PASS
    SMP1/SMP4, failures=0, fsck
    clean, qemu exits 0, ~385 s /
    100 s. MILESTONE 54 COMPLETE.
    Next: 55.

    55 SHIPPED — the wall clock.
    qemu 10.2's RISC-V build has NO
    RTC device (virtio-rtc-pci and
    goldfish-rtc both absent, virt
    DTB has none, OpenSBI has no
    wallclock call), so the clock
    is seed-once + synthesize: gloss
    _gettimeofday lazily seeds from
    (A) semihosting SYS_TIME — the
    ebreak guard sequence with an a7
    handshake magic (16#5E41_C10C#);
    qemu -semihosting answers with
    host epoch, WITHOUT it the
    ebreak traps to the kernel whose
    new Dispatch_Trap breakpoint
    branch sees the magic, answers
    a0 = -1 and Advance_SEPCs past
    (any other a7 stays fatal) — or
    (B) the baked RD0:System/Epoch
    file (Makefile stamps date +%s
    into the initrd each build), or
    (C) epoch 0 as before. Then
    now = seed + rdtime/10MHz with
    tv_usec from the remainder.
    The probe + rdtime read are
    INLINE ASM in gloss (first cut
    used a gnat_user C helper, but
    syscall-RTS programs link gloss
    without libgnat — init's link
    died on the undefined symbol).
    Fuzz: Calendar.Split year >=
    2024 (got 2026 via the host),
    Clock advances across yields.
    BOTH seed paths verified: full
    suite with -semihosting (A) and
    with a QEMU= wrapper stripping
    the flag (B — no unexpected-
    trap halt, baked epoch read).
    880/880 SMP1 (386 s), 879 seen
    SMP4 (100 s) with failures=0
    (serial-loss noise), fsck clean.
    Ada.Calendar + Formatting now
    tell the truth; timezone stays
    UTC (a-catizo, TZ unset).
    MILESTONE 55 COMPLETE. Next:
    56 — Trinket core (GUI design
    locked: retained widget tree,
    client-side rendering, BDF
    fonts, Tier-1 shared libs
    land with Trinket).

    MILESTONE 56 (Trinket core):
    userspace/trinket = OPT-IN
    static library (libtrinket.a,
    NOT part of the RTS — GUI
    programs link it on top of
    akernel_program.gpr). Root
    (palette = Bureau's exact
    constants + Canvas = mapped
    surface + clip rect),
    Trinket.Paint (clipped fills +
    the WB3.1 double-ridge Bevel2:
    black outer, white/dark inner
    pair, sunken for insets),
    Trinket.Fonts (BDF loader —
    STARTCHAR/ENCODING/DWIDTH/BBX/
    BITMAP, 8-bit-wide <= 32-row
    subset — from Sys:Fonts/
    font8x8.bdf with the compiled
    Font8x8 as fallback;
    tools/font2bdf.py GENERATES
    the BDF from font8x8.ads at
    image build, bit-reversed to
    BDF's MSB-first), Trinket.
    Widgets (abstract tagged
    Widget = the MUI class;
    Group H/V layout with frame +
    centered title breaking the
    top edge + Inset pane mode;
    Label (optional inset field);
    Button (press/release, sunken
    while held, On_Click callback);
    dispatching Dirty_Union +
    Clear_Dirty for damage),
    Trinket.Window (the whole v3
    dance: queue memobj 0x5F00_0000,
    chunks from 0x5F80_0000,
    thread-bound ntfn, mint/delete,
    chunked Set_Buffer + commit;
    Run = recv-multiplex loop:
    notification -> drain queue ->
    Press/Release edge derivation
    from packed buttons -> tree
    dispatch -> dirty union -> one
    clip + repaint + Surface_Update
    band; close event returns).
    tdemo (Sys:System/Tdemo, in
    Startup) proves it: screendump
    shows groups/titles/insets/
    buttons, QMP click on Save
    logs the callback, close
    gadget destroys the window.
    881/880 PASS SMP1/SMP4,
    failures=0, fsck clean.
    Burns: (1) anonymous access
    allocators (constant access T
    := new T inside a constructor
    function) inherit FUNCTION
    accessibility — the conversion
    to a library-level Any_Widget
    fails the dynamic check
    (PROGRAM_ERROR at startup);
    named access types at library
    level. (2) Root group at Y=0 +
    title band at W.Y-2 wraps U64
    -> CONSTRAINT_ERROR in
    Fonts.Draw_Text's Integer
    conversion; clamp. (3) A child
    package named Trinket.Draw is
    HIDDEN by the Widgets.Draw
    primitive inside the body —
    renamed to Trinket.Paint.
    (4) U64 operators need use
    type in EVERY child unit;
    Interfaces has Unsigned_8,
    not U8. (5) Adding tdemo's
    third boot window lengthens
    per-console-line compositing
    under SMP4 enough that the
    info-reap poll's 512x32-yield
    budget went deterministically
    short — 4096 restores it (test
    budget, not product). (6)
    library gpr projects don't
    build standalone — no alire
    toolchain context; build
    through a dependent crate.
    MILESTONE 56 COMPLETE.

    MILESTONE 57 COMPLETE.
    Window protocol v4 (Bureau
    pointer capture: a content
    press captures the pointer
    until release — moves leak
    clamped to the content rect,
    release always delivered,
    coalescing only merges
    equal-button events;
    Surface_Destroy clears
    Capture+Drag_Slot);
    virtio_input forwards nav keys
    as codes 16#80#..16#88#
    (Trinket.Key_*); terminal
    drops codes >= 128;
    Trinket.Scrollbar (arrows,
    track paging, striped knob
    drag via capture, user-only
    On_Change); Trinket.Text_Edit
    (512x128 heap model, cursor,
    click-place, drag-select,
    full key editing, Top-line
    scroll, 3-segment selection
    Draw); Trinket.Window.
    Request_Quit; Sys:System/Edit
    (Text_IO load/save, verified
    live: typed mid-line, saved,
    edit survived sync+reset).
    Burns: (1) Bureau overlay
    addresses Queue_VA(Slot)/
    Surf_VA(Slot) elaborate at
    CALL ENTRY before the slot
    guard runs — an early virtio
    tablet event with Focus=0
    wrapped to 16#F..F# and
    killed Bureau; clamp the
    index INSIDE the address
    functions, guards are not
    enough. (2) The Files
    package default volume is
    RD0 (initrd) and the whole
    Tests/ ecosystem relies on
    it, but an interactive shell
    typing System/Edit needs
    BD0: — shell Stage now tries
    CLI.Resolve_Path (cwd-aware)
    FIRST, falls back to the raw
    RD0-default name; a
    Set_Default_Volume("BD0")
    hardcode fixed the terminal
    and deterministically broke
    5 suite jobs tests (fuzz
    shells stage Tests/Teardown
    relative). (3) QMP test
    harness: fixed sleeps lose
    to variable boot time — poll
    the log for 'shell online'
    before typing, and click the
    target window FIRST (keys go
    to the focused window only).
    Next: 58 — Trinket.Listview
    + file manager; terminal
    Scrollbar adoption; Tier-1
    shared-lib machinery.
    Deferred: tasking,
    virtio-net, Proc:self.

    MILESTONE 62 COMPLETE — true
    scheduler priorities. Every thread
    carries an Amiga-range priority
    (-128..127, default 0); the global
    ready queue is now a packed array
    popped BEST-FIRST (priority, then
    boosted, then FIFO) instead of a
    strict-FIFO ring — at all-0 the
    order is byte-identical to the
    ring. Priority crossings preempt
    immediately: Wake/set_priority IPIs
    any hart running a strictly lower
    priority (the software-interrupt
    path reschedules via the tick's
    Handle_Preemption), and Handle_
    Syscall's tail checks Should_
    Preempt so the WAKER's hart hands
    over at syscall exit — guarded on
    Current = the entering thread
    (Handle_Exit falls through with
    Current switched; saving that frame
    into the new thread's TCB would
    corrupt it). Sys_Set_Priority=35:
    a0 = U64'Last (self) or a
    Process_Object cap WITH Manage
    (the spawn/reap cap — Amiga
    SetTaskPri under capability
    discipline), a1 = signed request
    clamped to the range; returns
    status + OLD priority. Process_Info
    grows to 9 words (word 8 = priority
    sign-extended); Proc:<pid>/status
    renders a signed "priority N" line.
    Shell gains `pri <job> <n>`
    (ChangeTaskPri lineage) over its
    job process caps. Fuzz: 24 directed
    checks (self old-value/clamp to
    127, rejections incl. no-Manage
    mint, cross-process set on a
    BLOCKED echo child, word-8 mirror,
    Proc: render). Burns: (1) THE
    BOOST IS POSITIONAL — moving it
    from push-time position to a
    pop-time flag without consuming
    it at pop let a woken-then-
    yield-polling thread (fuzz's reap
    storm) win EVERY scan; children
    never ran, 22 reap timeouts,
    deterministic — pop must clear the
    flag (the ring spent it with one
    head-insert). (2) Directed self
    tests must only RAISE: a self-lower
    across a reschedule with the Spin
    hog ready at 0 parks the caller
    forever on UP (strict priorities,
    by design) — negative values are
    tested on a BLOCKED child. (3) The
    fuzz random generator is mod 31
    with an exclusion list — a new
    syscall is NOT automatically in the
    random pool (set_priority with a
    garbage self-target would suicide
    the suite; stays excluded).
    Suites green SMP1+SMP4 972 PASS,
    failures=0, fsck clean, qemu
    self-exits 0; live: `run Wait 30` +
    `pri 1 -64` + jobs/errors via QMP.
    Next: 63 — TBD.

    MILESTONE 61 FOLLOWUP — menus on
    every GUI app. The Op_Set_Menus
    wire packing moved out of
    Trinket.Window.Set_Menus into
    Trinket.Menus.Serialize (Menus +
    page address) so RAW-protocol
    clients share it; Set_Menus is
    now alloc/map/Serialize/mint/
    call/unmap/delete. Fileman:
    File>Open/Parent/Quit (the
    button-row callbacks; Open spawns
    Edit on the selection). Tdemo:
    File>Save/Revert/Cancel/Quit
    (Quit = Request_Quit). Terminal
    and Demo (raw clients, pre-
    Trinket.Window): Terminal>Quit
    and Demo>Quit, each serializing
    into its own transient page at
    Queue_VA+4096, mint Map+Read+
    Transfer, Surface_Set_Menus
    direct, kind-4 pick = the
    close-gadget path; demo.gpr now
    withs trinket.gpr (Menus only —
    the static lib links just that
    unit). Edit untouched = the
    serializer regression check.
    Verified live via the QMP RMB
    sticky-bar flow: every dropdown
    opened, picks fired (tdemo Save
    logged, fileman Open spawned
    Edit), all five apps exited
    THROUGH their menus to a clean
    desktop. Suites green SMP1+SMP4
    948 PASS, failures=0, fsck
    clean, qemu self-exits 0. Burn:
    none in code; QMP dropdown picks
    need item-row y precision (16 px
    rows — a click just below the
    last item silently dismisses the
    menu, so screenshot the OPEN
    dropdown and measure rows before
    clicking).

    MILESTONE 61 COMPLETE — Amiga
    screen-bar menus. Menus are CHROME:
    the client declares a tree once
    (Op_Set_Menus=27, serialized one-page
    memobj, Bureau COPIES it out — never
    re-reads client memory), Bureau
    renders bar + dropdowns above all
    windows and owns the interaction.
    RMB is Bureau's alone (content never
    sees it): down opens the focused
    window's bar, held = classic
    drag-select, release over an item
    picks; release elsewhere leaves the
    bar OPEN (sticky, the touchpad
    ruling); a menu-less window's RMB
    inverts the "Bureau" screen title
    while held (our bar is persistent,
    so the gesture needs a cue) and
    serial-logs the edge — GTK/SDL eat
    the grab click and host touchpads
    may not deliver button 3 at all, so
    the log splits guest-never-saw-it
    from no-menus — hover switches dropdowns,
    left-click picks, left-click off /
    RMB again / Esc / focus loss
    dismisses. Picks arrive as input-queue
    kind 4 (value = item Id); Trinket.Menus
    is the declarative builder,
    Trinket.Window.Set_Menus +
    Set_Menu_Handler wire it up. Edit is
    the proof: File>Save/Quit. The bar
    also gained the RTC clock (HH:MM,
    right-justified beside the depth
    gadget, refreshed on service-loop
    wakes — Bureau blocks in Receive, so
    an idle desktop's clock freezes until
    the next event). Burns: (1) a library-
    level `W : Rec renames Wins (Slot)`
    with Slot=0 raises at elaboration
    BEFORE the guard inside the body can
    run — guard first, rename inside a
    declare (the Draw_Menus boot crash);
    (2) Max_Win=4 was SILENTLY FULL at
    boot (4 boot windows; Edit got
    No_Slot) — now 6; (3) the 600 s suite
    timeout tripped under ambient host
    load (load ~1.5) with 0 FAIL on the
    UNCHANGED tree too — control-run with
    stash before bisecting; 900 s passes.
    Next: 62 — TBD.

    MILESTONE 60 COMPLETE — Amiga-style
    command history. It lives in the
    TERMINAL (the CON: analog — line
    discipline's home), not the shell:
    Edit_Buf mirrors the input half of
    the current scrollback line, Return
    pushes it onto a 32-entry ring, and
    cursor Up/Down recall by INJECTING
    bytes into the Op_Read FIFO (BS x
    current length, then the entry) so
    the shell's own line buffer stays
    in sync — the shell needed zero
    changes. Down past the newest
    restores the stashed in-progress
    line. Scrollback scrolling moved
    off Up/Down to PgUp/PgDn/Home/End
    (+ scrollbar pointer). Latent m57
    bug fixed: virtio_input's nav table
    used PC set-1 scancodes (Up=72) but
    qemu virtio-keyboard speaks LINUX
    keycodes (KEY_UP=103; the
    typewriter block coincidentally
    matches both) — nav keys never
    arrived from a real keyboard.
    Bonus line-discipline fixes:
    backspace at empty input no longer
    eats the prompt's last character;
    control bytes the shell ignores
    (tab etc.) are dropped instead of
    desyncing the display. Burns:
    recall injection needs the Op_Read
    FIFO sized for 2x120 + type-ahead
    (now 512); shell Max_Line=120 is
    the Edit cap — injecting more than
    the shell accepts desyncs. Next:
    61 — TBD.

    MILESTONE 59 COMPLETE — RTC/clock
    group. Goldfish RTC (DTB
    "google,goldfish-rtc", board
    default 0x101000, physmap-read —
    no new mapping: the physmap covers
    MMIO below RAM) behind
    Sys_Read_Clock = 34 (a0=seconds,
    a1=nanos since the Unix epoch,
    both 0 = no ticking RTC; UNGATED,
    read-only). Gloss gettimeofday
    prefers it (m55 semihost/baked-
    Epoch seeding stays the fallback);
    fat32 dirent stamps are real
    (civil_from_days; 2 s resolution;
    pre-2000 reading = no RTC → the
    old fixed 2025-01-01); Op_Stat
    replies carry FAT write date/time
    in words 2/3 (fileserver zeroes
    them for local volumes — the
    request's packed path would leak
    through as a garbage stamp; procfs
    zeroes too); Files.Stat_Ex; List
    prints the stamp column.
    Sys:C/Date (read-only: the
    goldfish RTC cannot be set) and
    Sys:C/Wait (N | M:S | UNTIL
    HH:MM[:SS], case-insensitive
    keyword, passed-today = tomorrow).
    Vendored OUR OWN s-reldel (the
    embedded one routes through
    Ada.Real_Time.Delays = tasking):
    Delay_For forwards to s-osprim
    Timed_Delay; `delay Duration` now
    works everywhere. Burns: runtime_
    build.gpr needs the toolchain bin
    on PATH and its failure ("no
    compiler for language C") does NOT
    match a ': error' grep; shell
    `wait` (m52 jobs) collides with
    C:Wait — an argument naming no
    job falls through to C:Wait
    (Amiga precedence: the C: command
    wins), so "wait 7" with no jobs
    SLEEPS 7 s — the m52 unknown-job
    RC-10 test became a fallthrough
    test; runtime ritual order:
    gprbuild runtime_build THEN rm
    obj/bin of the dependent crates.
    Next: 60 — TBD.
    Deferred: tasking, virtio-net,
    Proc:self, dynamic linking.

    MILESTONE 58 COMPLETE (df2aec3 +
    f082fa5). Post-58 burns:
    Normalize_Path must IGNORE a
    trailing empty component ("dir c/"
    is c, POSIX-style) — only MIDDLE
    empties are the Amiga parent
    idiom; bare "/" still ascends
    because Join_Path contributes the
    cwd's own separator. Also: EVERY
    ENV: write must funnel through
    CLI.Set_Env (it alone runs
    Ensure_Env_Dir) — gloss Set_CWD
    wrote ENV:CWD directly, so on a
    fresh disk (no Prefs/Env yet)
    chdir failed and CD reported a
    GOOD directory as "no such
    directory". The suite masked it:
    fuzz env-var tests create the
    chain before any CD runs.
    GUI half: Trinket.Listview,
    Sys:System/Fileman (Listview +
    Scrollbar), and the terminal rebuilt
    on Trinket — Terminal_Buffer circular
    scrollback replaces the direct text
    grid, right-edge scrollbar, nav keys
    (Up/Down/PageUp/PageDown/Home/End) and
    pointer scrolling, solid block cursor.
    Burn: Terminal_Buffer.Put_Char must
    keep Buffer(Current).Len in sync with
    Current_Len or partial lines/typing
    echo never render. Tier-1
    shared-library machinery
    shipped: `Akernel_User.Libs`
    client API, `Libserv` server
    helper, `Testlib`/`Testlib_Client`
    demo, fuzz lifecycle tests.
    Wire convention: rendezvous at
    handle 5, service cap sent back
    with `Send+Receive+Transfer`
    rights on the rendezvous cap;
    `Open_Library` accepts optional
    console/fs/bureau handles and
    falls back to console for an
    absent bureau cap so the spawn
    grant list stays valid. All
    directed fuzz tests pass,
    failures=0, kernel self-resets.
    Next: 59 — TBD.
    Deferred: tasking, virtio-net,
    Proc:self, dynamic linking.

    MILESTONE 53c
    COMPLETE.
    Next: 54 — migrate remaining
    Sys:C commands onto Text_IO/
    CLI.Init/Ada.Command_Line where
    it pays; Calendar needs a real
    RTC (gettimeofday still epoch).
    Deferred: tasking, virtio-net,
    dynamic linking.

    MILESTONE 53b
    COMPLETE. Next: 53c —
    Ada.Environment_Variables->
    ENV:, Ada.Command_Line->args
    page, Ada.Directories->fs
    Op_ReadDir, getcwd/chdir->
    ENV:CWD; migrate programs off
    raw syscalls. Later: tasking,
    RTC/Calendar, virtio-net,
    dynamic linking.

    MILESTONE 53a COMPLETE. Burns
    for the ages: gprbuild does NOT
    track libgnat.a — rm -rf
    obj/userspace/<crate> after
    every runtime rebuild or the
    crate links the STALE runtime;
    a failed runtime build + a
    successful crate build = testing
    the stale adalib (grep the build
    output BEFORE running); "digits"
    is an Ada reserved word; pragma
    Import(Intrinsic) in a private
    part satisfies the spec but
    breaks client operator
    visibility; Boot_Cap's bootinfo
    page is INIT-ONLY (0x6FFE_0000)
    — calling it elsewhere faults.
    Next: 53b newlib (~18 syscall
    stubs over Files/Console, own
    _sbrk arena, FULL Text_IO et al
    from the gcc tarball), 53c env/
    args/directories + program
    migration; later tasking, RTC,
    virtio-net, dynamic linking.

Commit between each milestone.

## Deferred (do not build yet)

Live list — scrubbed post-58. Landed since this section was
written: FAT32 metadata cache + Op_Sync (22), assigns C:/ENV:
(36), uniform program ABI (31b), pointer events to clients
(32/57), write-back cache + VIRTIO_BLK_F_FLUSH + block-layer
sync (48), blocking pipes (49), clean shutdown (50).

Still open:
- Clock/RTC: Wait/Date/Time/SetDate — no RTC today; dirents
  stamp fixed 2025-01-01, gettimeofday is epoch (m41 clock
  group, 53c).
- Tasking runtime (Ada tasks in userspace).
- virtio-net (no network at all today).
- Proc:self (needs client identity through the VFS).
- Shell: background pipelines/redirection (m52: run takes one
  command); script interpreter proper — If/Else/EndIf, Skip,
  Lab, Alias, Resident (m41; we have execute + failat).
- Trinket: images/icons (deferred from the 56 GUI plan);
  Fileman actions (copy/delete/rename, navigation).
- Tier-1 library follow-ups: versioning (Amiga OpenLibrary
  version floor), reference counting across opens. Tier-2
  runtime code loading / dynamic linking deferred-not-rejected.
- Block layer: device-level cache shared across fs drivers
  (write-back per-driver landed in 48).
- Register fast path, >4 caps/msg (probe IPC cost first).
- Custom GNAT runtime for userspace (runtime.xml + rebuilt
  adalib with s-memory/a-stream vendored in, replacing the
  stock light-rv64imafdc) — the milestone-40 RTS library is
  the pragmatic 90%; this is the purist end state, zero
  user-visible gain, toolchain-coupled build cost.
- Kernel introspection leftovers: endpoint/notification object
  listing, scheduler stats (Avail rides this).
- Cooperative shutdown broadcast (m50: revisit when a server
  holds in-memory state worth saving); automated reboot-cycle
  test (would loop); thread-id generations (m51: no consumer).
- Zero-copy direct scanout of full-screen client surfaces;
  MSI-X for virtio-pci (INTx today, shared chains); per-device
  IOVA spaces (IOVA = PA identity today); true scheduler
  priorities; finer-grained kernel locking / per-hart
  runqueues (BKL serializes all kernel execution; fine at
  hobby scale).

## Start by reading

- `docs/IPC.md`
- `src/kernel/kernel-ipc.*` (existing scaffold)
- `src/kernel/kernel-capabilities.*` (Duplicate/minting basis)
- `src/kernel/kernel-objects.*` (cleanup dispatcher, object kinds)
- `src/kernel/kernel-tasks.*` (cap table ownership, thread access)
- `src/arch/riscv64/arch-traps.adb` (syscall dispatcher)
