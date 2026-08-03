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
20. Real filesystem on the block device (FAT or custom): fileserver
    block volumes currently expose only the raw "disk" file.
    ~~Prerequisite cap_delete~~ — done: syscall 26 closes one of the
    caller's own cap-table slots via Kernel.Tasks.Close_Cap (same
    per-kind cleanup as the exit/reap path); the blk driver deletes
    each request's transferred buffer cap after the RPC (was one
    leaked slot per transfer). Fuzz random phase ranges over 0..26
    now with cap_delete skipped (a random delete could close the
    fuzzer's own granted caps). 108/108 directed PASS at QEMU_SMP
    1/4/8, fuzz failures=0.

Commit between each milestone.

## Deferred (do not build yet)

- Plain `send`, register fast path, >4 caps/msg.
- Kernel introspection syscalls for init state reconstruction.
- Finer-grained kernel locking / per-hart runqueues if hart counts
  grow (BKL serializes all kernel execution; fine at hobby scale).
- IOMMU, tasking runtime; PCI virtio transport, virtio-gpu.

## Start by reading

- `docs/IPC.md`
- `src/kernel/kernel-ipc.*` (existing scaffold)
- `src/kernel/kernel-capabilities.*` (Duplicate/minting basis)
- `src/kernel/kernel-objects.*` (cleanup dispatcher, object kinds)
- `src/kernel/kernel-tasks.*` (cap table ownership, thread access)
- `src/arch/riscv64/arch-traps.adb` (syscall dispatcher)
