# Resume prompt (next session)

```text
Read docs/STATE.md, docs/NEXT.md, docs/IPC.md. Pick next steps from
NEXT.md's deferred list or the open candidates: virtio-blk (block
protocol, IRQ-driven driver, block-backed volume on the file
server), retiring uart/mmio + uart/irq tokens onto the generic
devmgr path, SMP hardening, IOMMU, kernel introspection syscalls,
plain send, register fast path.

Device plumbing + first virtio driver landed: init's device manager
enumerates the DTB itself (exposed as pseudo boot file "dtb", FDT
walker in userspace Device_Tree) and matches nodes against the
System/Drivers database (`driver <compatible> <path> <probe>
<class>`; virtio probe compares the device id @0x08). Kernel side:
Kernel.Devices dynamic MMIO/IRQ objects on a PMM slab (boot UART
migrated off statics; IRQ finalizer unregisters the source),
syscalls 23/24/25 io_map / irq_create / mem_object_pa gated by the
"device_resource" Kernel_Object cap (Manage, init only), PMM
reserved ranges for the initrd and DTB (latent clobber: the bump
allocator would eventually have handed out both). Map_MMIO maps
borrowed now (device frames were AS-owned — teardown would have
gifted them to the PMM, and mem_unmap refused them). The virtio
lib (userspace/virtio Alire crate, no RTS deps: MMIO register level
generic over Reg_Read/Reg_Write, split-ring virtqueues as flat
volatile array overlays) backs Drivers/VirtioRng, spawned by the
devmgr with console/mmio/irq at handles 1..3; 16-byte entropy
request over a 4-page DMA object with per-page PAs from
mem_object_pa. 94/94 directed PASS at QEMU_SMP 1/4/8, fuzz
failures=0.

Gotchas burned: (1) Pack on volatile record types is advisory —
field offsets shifted and used-ring reads landed one element late;
ring overlays are flat arrays with explicit word offsets now.
(2) Board.Device_Tree.Boot_DTB_Physical_Address returns a physmap
VA despite its name (double Phys_To_Virt gave a garbage boot-file
base and a no-op DTB reservation). (3) qemu's virtio-mmio transport
defaults to the legacy v1 interface; the run target passes
-global virtio-mmio.force-legacy=false. (4) qemu virt emits 8
virtio-mmio slot nodes (irq 1..8, regs 0x10001000..0x10008000),
only populated ones probe to a nonzero device id.

SMP landed (milestone: BKL multicore). seL4-style big kernel lock:
user code runs truly in parallel on all harts, every trap acquires
Kernel.Lock, the trap trampoline itself releases it after the C
handler returns. Topology from DTB /cpus (Kernel.CPUs, metadata cap
64, per-hart kernel stacks PMM-allocated); secondaries start via SBI
HSM into secondary_boot with a per-hart boot-info block PA as opaque
arg; final kernel page table keeps one identity RX gigapage so the
secondary entry survives its satp switch. Shared ready queue +
per-hart Current; wakers IPI (SBI sPI) on empty->nonempty; per-hart
timer arms; PLIC external handling on boot hart only (idle polls
SEIP there). Idle never runs on a blocked thread's kernel stack:
Schedule_Saved_Context jumps (riscv_jump_to_idle) to the per-hart
main/trap stacks when no work exists — another hart can resume the
blocked thread and its next trap would clobber the sleeper's frames.
Hart identity lives at kernel-stack-top - 8 (above the 280-byte
trap frame), read via sscratch. UART prints are message-level
spinlocked with Put_Unsafe variants for panic paths;
Kernel.Lock.Try_Enter_Fatal claims a single fatal dump. Makefile
QEMU_SMP defaults to 4; 89/89 directed PASS at QEMU_SMP 1/2/4/8,
fuzz failures=0. Userspace gotcha: Reap_Process is non-blocking, so
the fuzz memstage test polls with Yield — UP scheduling order had
hidden the race.

DTB device enumeration landed: Kernel.Device_Tree.Find_Device walks
the FDT matching a compatible string against each node's compatible
string list, capturing reg (first entry, parent #address-cells/
#size-cells via a depth stack) and the first interrupts cell.
Decision happens at node close because FDT property order is
arbitrary (qemu emits reg before compatible — a match-then-capture
walk silently misses reg). UART base + IRQ source and PLIC base now
come from the DTB: Kernel.Boot_Resources.Initialize fills the
uart/mmio + uart/irq objects, Board.UART.Set_Base /
Board.PLIC.Set_Base override the board-default MMIO bases,
Board.Interrupts.Initialize takes the source as a parameter. Board
constants (board-memory_map.*, Board.PLIC.UART0_Source) are fallback
defaults when nodes are absent ("dtb devices incomplete; board
defaults" in the boot log). 89/89 directed PASS, fuzz failures=0.

Gotcha burned: #size-cells = 0 is legal FDT (qemu /cpus uses it) —
a modular U32 `for I in 0 .. Cells - 1` wraps to 4 billion reads and
walks off RAM (fault at physmap VA of PA exactly RAM end; the DTB
sits at the top of RAM, so any overrun faults immediately).
Read_Cells returns 0 for Cells = 0 now. Debug method that found it:
Python re-model of the Ada walk against `qemu -machine
dumpdtb=...` output reproduced the match-then-capture bug; the
cells wrap needed the kernel trap dump (scause/sepc/stval) +
objdump of sepc (mmio_read8).

Notification objects landed: Notification_Object caps (static slab
of 16; Wait/Write/Manage rights), syscalls 18-22 (ntfn_create,
ntfn_wait, ntfn_signal, ntfn_bind_thread, irq_bind_ntfn). A thread
binds one notification; IPC_Recv checks it before blocking and a
signal arriving while bound+blocked-in-Receive cancels the endpoint
wait (Kernel.IPC.Cancel_Receive via TCB Recv_Endpoint) and delivers
a synthetic message (Label = U64'Last, word 0 = bits). IRQ lines
carry (Ntfn, badge): Deliver signals. Drivers/Serial RX is
IRQ-driven through it (uart/irq grant, manifest token order moved
console to cap 3). 89/89 directed PASS, fuzz failures=0.

Gotcha burned: syscall handlers that self-advance sepc (block/wake
paths like IPC_Recv, Ntfn_Wait) must have `return` after the call
in Handle_Syscall's dispatch — falling through to the tail
Advance_SEPC double-advances (+8), which resumed fuzz mid-stub and
walked the stub table until a fatal store. Trap dump now prints
the current thread id.

Line-atomic console writes landed: the serial server line-buffers
per client (keyed by console cap badge = manifest program id set by
init, newline/160-byte-full flush, replies immediately) and the
kernel debug_putchar syscall line-buffers per thread (128 bytes in
the TCB, flush on newline/full/exit). 74/74 directed PASS.

Milestone 12 landed: spawn v2 completion. Spawn accepts Memory_Object
caps (Read right; boot files still need Read+Execute): Kernel.ELF
gained a Source discriminated record (Physmap_Bytes | Object_Frames)
abstracting image byte reads, so the loader works over a memory
object's scattered frames via Kernel.Memory.Frame_At. New finite test
program Tests/Memstage (console banner at handle 1, Process_Exit);
fuzz stages it via the file server into a memory object (chunked
32 KiB reads to VA 0x5400_0000), grants console via Set_Grant
(index 0 -> child handle 1, Right_Send), spawns from the object cap,
reaps. 74/74 directed PASS, fuzz failures=0.

Milestone 11 landed: file protocol (9P-ish) over endpoint RPC.
System/Fileserver (new userspace program) holds all boot-file caps
(boot_files manifest token, handles 3..N) + fs endpoint Receive
(handle 1); init pushes the (handle -> name) table as Op_Set_Name
messages after spawn, then a zero-handle terminator. Kernel mem_map
now accepts Boot_File_Object caps: borrowed read-only initrd frames,
extent = ceil((lead-in + length)/4096) pages, lead-in byte offset
returned in a1. Userspace: Akernel_User.Files client
(Bind/Stat/Open/Read), stateless reads, client-owned 8-page buffer
memory object at VA 0x4400_0000 transferred per Read call (replies
cannot carry caps — reply path zeroes cap slots). Server maps boot
files RO into per-file windows at 0x4400_0000 + slot*256KB and the
client buffer at 0x4420_0000. Manifest: program 2 System/Fileserver
fs_server console boot_files; fuzz gains fs (handle 4) and
System/Manifest (handle 5) grants; echo stays handle 3.
Gotcha burned once: asm syscall stubs and Ada imports must agree on
argument registers — Mem_Map_File has 6 Ada args (a0..a5) so the
akernel_sys_mem_map_file stub moves the delta pointer a5->a6 and
injects flags=1 (RO) itself; a stub expecting a6 while Ada passes 6
args reads garbage (crashed with a6=0x74). Debug method: kernel-side
trap-frame word dump (Words : array (0..33) of U64 with Address =>
Frame; a6 = word 15).
64/64 directed PASS, fuzz failures=0.

Amiga-style volumes added on top: manifest `volume RD0 Initrd ci`
directive -> init Op_Mount; fileserver resolves RD0:/Initrd:
prefixes (prefix match always case-insensitive, path match per the
volume's case flag); Akernel_User.Files prepends default volume
"RD0" for unqualified names (client-side PATH seed, settable via
Set_Default_Volume). 67/67 PASS. CRITICAL latent bug fixed: userspace
_start never set gp (kernel zeroes it) — fine until small globals
(<=8 bytes) landed in .sdata/.sbss and the linker relaxed accesses to
gp-relative (fault, gp=0). _start now does lla gp, __global_pointer$
under .option norelax.

Build/run: make all && make run. Commit per milestone; docs
current-state only.
```
