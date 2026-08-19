MILESTONE 64 SHIPPED: Fileman actions + deficons + XPM.
Trinket.Images.Xpm joins Bmp behind Load (XPM3 subset, cpp 1-2,
c None/#RRGGBB/#RGB; None arms the color key in the DECODER).
Widgets gains Input (focus-gated string gadget; Group.On_Key
walks children in REVERSE add order) and MUI-weighted Group
layout; Listview carries per-item icons (rows 8->18 with icons).
Fileman loads System/Icons deficons, picks drawer/file/tool per
entry (ELF magic sniff), and does Open/Parent/Rename/Copy To/
New Drawer/Delete/Quit via Ada.Directories — all live-verified.
Two runtime-level bugs flushed: (1) EMPTY-DIR STAT POISON —
fat32 Stat rejected dirs and Gloss's 53c Read_Dir(P,0) probe
fails for EMPTY ones, so a-direct Start_Search raised Use_Error
and truncated every listing at a fresh drawer (the m63 "Copy
can't open" burn was this); fixed on the wire: Op_Stat answers
dirs with word 4 = is_dir (IPC.md updated; w4 hygiene in
fileserver/procfs), Stat_Ex grew Is_Dir. (2) NEWLIB _rename_r
is link()+unlink() with _link stubbed, so a-direct Rename could
never work; vendored adaint.c __gnat_rename now calls the Gloss
_rename hook directly. Trap: the RTS make rule tracked only its
gpr — adalib went stale and the adaint patch silently never
linked; RTS_LIB now depends on the vendored sources. Harness
note: the terminal garbles output under fast QMP typing
(artifact, not fs state) — ground truth is dd+mtools on the
host image. Suites green SMP1+SMP4 997 PASS, failures=0, fsck
clean, qemu self-exits 0. Full burn list in docs/NEXT.md under
MILESTONE 64. Before that:
MILESTONE 63 SHIPPED: Trinket images, datatypes-style.
Trinket.Images.Load sniffs magic and dispatches to decoder
children (Bmp: BI_RGB 24/32-bit, bottom-up + top-down, fully
bounds-checked); color-key transparency set client-side; Blit =
clipped span copies into any Canvas (fuzz render-tests against a
plain memobj canvas, no Bureau surface needed). Widgets gains
Image_Widget; tdemo showcases bars + keyed disc from
Tests/Img/ (tools/gen_images.py assets). Suites green SMP1+SMP4
984 PASS, failures=0, fsck clean, qemu self-exits 0. Burns:
Files.Bind is MANUAL (unbound = client-side Bad_Args posing as
a mount race); client error labels lie (Copy named the source,
the DEST create failed — probe with Type); the Makefile has no
600 s timeout anymore — gate runs want timeout 1000, and
timestamped control+m63 runs both took 571 s. Full burn list in
docs/NEXT.md under MILESTONE 63. Before that:
MILESTONE 62 SHIPPED: true scheduler priorities. Amiga range
-128..127 per thread (default 0); the global ready queue pops
best-first (priority, boosted, FIFO — all-0 is byte-identical to
the old ring). Priority crossings preempt immediately (IPI to
outranked harts + Should_Preempt at syscall exit, guarded on
Current = entering thread). Sys_Set_Priority=35 (self via
U64'Last, or a Manage-bearing process cap; clamped; returns old).
Process_Info word 8 + Proc: priority line; shell `pri <job> <n>`.
Suites green SMP1+SMP4 972 PASS, failures=0, fsck clean, qemu
self-exits 0. Burn of the milestone: the wakeup boost is
POSITIONAL — consume it at pop or a boosted yield-poll starves
every child (22 deterministic reap timeouts). Full burn list in
docs/NEXT.md under MILESTONE 62. Before that:
MILESTONE 61 FOLLOWUP SHIPPED: menus on every GUI app.
The Op_Set_Menus wire packing moved into
Trinket.Menus.Serialize so raw-protocol clients share it;
Fileman File>Open/Parent/Quit, Tdemo
File>Save/Revert/Cancel/Quit, and the raw clients
Terminal>Quit / Demo>Quit (own transient page at
Queue_VA+4096, Surface_Set_Menus direct; demo.gpr withs
trinket.gpr). Verified live via QMP RMB sticky-bar: all
five apps exited THROUGH their menus. Suites green
SMP1+SMP4 948 PASS, failures=0, fsck clean. Before that:
MILESTONE 61 SHIPPED: Amiga screen-bar menus. Menus are
CHROME: client declares a tree once (Op_Set_Menus=27,
serialized one-page memobj, Bureau copies it out), Bureau
renders bar + dropdowns and owns the whole interaction. RMB
is Bureau's alone: down opens the focused window's bar, held
= classic drag-select, release elsewhere = STICKY (touchpad
ruling) — hover switches dropdowns, left-click picks,
off-click/RMB/Esc/focus-loss dismisses. Picks = input-queue
kind 4 (value = item Id); Trinket.Menus builder +
Trinket.Window.Set_Menus/Set_Menu_Handler; Edit is the proof
(File>Save/Quit, verified live via QMP). The bar also carries
the RTC clock (HH:MM beside the depth gadget, event-driven
refresh). Burns: renames Wins(0) raises BEFORE the body's
guard (guard first, rename in a declare); Max_Win=4 was
silently full at boot (now 6); the 600 s suite timeout trips
under ambient host load — control-run the unchanged tree
before bisecting. Suites green SMP1+SMP4 949 PASS,
failures=0, fsck clean, kernel self-resets. Full burn list in
docs/NEXT.md under MILESTONE 61. Before that: MILESTONE 60:
Amiga-style command history in the
TERMINAL (CON: analog — history is line discipline, never the
shell): 32-entry ring, cursor Up/Down recall by injecting BS x
length + entry bytes into the Op_Read FIFO so the shell's line
buffer stays in sync untouched; Down past newest restores the
stashed in-progress line; scrollback scrolling moved to
PgUp/PgDn/Home/End. Fixed a latent m57 bug: virtio_input's nav
table used PC set-1 scancodes but qemu virtio-keyboard speaks
LINUX keycodes (KEY_UP=103) — nav keys never worked from a real
keyboard. Suites green SMP1 949 / SMP4 948 PASS, failures=0,
fsck clean, kernel self-resets. Full burn list in docs/NEXT.md
under MILESTONE 60. Before that: MILESTONE 59 (00e996e) —
RTC/clock group: Sys_Read_Clock=34 (goldfish RTC, a0=secs
a1=nanos since epoch, ungated read-only), real wall time in
gettimeofday/Ada.Calendar/FAT dirent stamps (Op_Stat words
2/3, List stamp column), Sys:C/Date + Sys:C/Wait, vendored
s-reldel (delay statements work), shell job-wait falls
through to C:Wait when the argument names no job.

Key facts carried forward:
- History recall INJECTS bytes into the terminal's Op_Read
  FIFO (BS per current char + entry text); Edit cap = 120 =
  shell Max_Line, FIFO sized 512 for 2x120 + type-ahead.
  Injecting more than the shell accepts desyncs it.
- virtio-input keycodes are LINUX input-event-codes.h
  (typewriter block coincidentally = PC set-1; nav cluster
  does NOT). Nav keys forward as 16#80#..16#88#.
- Menus: Bureau owns RMB + renders declared trees (kind-4
  pick events carry the client-chosen item Id); the bar
  clock ticks only on Bureau wakes (no timer service).
  Wire packing = Trinket.Menus.Serialize — raw-protocol
  clients (terminal/demo) map their own page and call
  Surface_Set_Menus direct; Trinket apps use
  Window.Set_Menus/Set_Menu_Handler.
- m62: priorities -128..127, default 0; best-first pop
  (priority, boosted, FIFO); boost consumed AT POP (positional,
  one first-run only). Preemption on strict priority crossings
  only; equal priorities wait for tick/block. Sys_Set_Priority:
  self = U64'Last, child = Manage process cap; clamped; a0
  status, a1 old. Self-lowering below a never-blocking hog
  parks you (UP: forever) — strict by design.
- m63: Trinket.Images = Load (sniff+dispatch, Bmp decoder
  child) + color-key Blit into any Canvas; Image_Widget borrows
  the image, the app owns Load/Free. Files.Bind (2) FIRST in
  any app new to the fs. BMP gen formulas live in
  tools/gen_images.py AND the fuzz checks — change both.
- m59: RTC behind Sys_Read_Clock=34; Wait N | M:S | UNTIL
  HH:MM[:SS]; runtime_build.gpr needs the toolchain bin on
  PATH and fails WITHOUT a ': error' line ("no compiler for
  language C"); build order: runtime THEN rm obj/bin of
  dependent crates; Op_Stat words 2/3 = FAT write date/time,
  0/0 on stamp-less volumes (fileserver zeroes the request's
  packed path bytes).
- Tier-1 library wire convention: rendezvous cap at uniform ABI
  handle 5 (Set_Grant slot 4) with Send+Receive+Transfer rights;
  the library Sends its service cap back over it, client deletes
  the rendezvous cap; Close_Library = delete the service cap.
  Sys:Libs/<Name> is the install path; Open_Library stages+
  spawns on demand and falls back to console for an absent
  bureau cap so the spawn grant list stays valid.
- Terminal is Trinket-rendered scrollback, NOT a direct text
  grid: Terminal_Buffer.Put_Char must keep Buffer(Current).Len
  in sync with Current_Len or typing echo never shows.
- Path env is ADDITIVE: cwd first, Path entries, then the
  built-in root+C: tail ALWAYS. The m44 replace semantics hid
  C: itself ("unknown command: Path"). Sys:Prefs/Env ships
  absent from the image — CLI.Set_Env creates the chain on
  first write (Stat of a dir answers Bad_Args, missing is
  exactly Not_Found).
- Bureau v4: content press captures pointer until release;
  moves clamped to content rect; release always delivered;
  coalesce only merges equal-button pointer events.
- Nav keys arrive as codes 16#80#..16#88# (Trinket.Key_*);
  text consumers (terminal line discipline) drop >= 128.
- Shell Stage resolution: CLI.Resolve_Path (cwd) first,
  raw-name (RD0 default) fallback. NEVER hardcode
  Set_Default_Volume in the shell — the Tests/ RD0
  convention is load-bearing for fuzz.
  Elevated's Stage resolves the same way (3fa4074); a stage
  failure replies 255 and Elevate prints "cannot find
  executable" itself — the daemon's console is serial-only.
- Bureau Queue_VA/Surf_VA clamp slot >= 1 internally —
  overlay addresses elaborate before guards run.
- Edit app: `System/Edit <path>` from the shell; Save via
  Text_IO, changes durable only after sync (Elevate
  Sys:System/Shutdown) — write-back cache.
- QMP harness: /tmp/qmp.py shot|click, /tmp/type.py; poll
  the log for 'shell online' before sending input; click
  the window to focus before typing.

CURRENT SESSION STATE (58 SHIPPED):
- Shell job control (Amiga RUN lineage): `run` backgrounds
  one command (no pipes/redirect yet), `jobs` lists,
  `wait [n]` yields the exit code as RC (failat composes).
  Job states Free/Active/Done — completed jobs keep their
  code until wait claims it (jobs must never reap-and-free
  a wait-able status; wait must not pre-harvest). `exit`
  with live jobs warns once, then abandons (Amiga orphan
  semantics). Shell group DONE except clock.
- Pid generations: pid = generation * 256 + slot base
  (slot + 4); generation 0 keeps boot pids historical, each
  slot reuse bumps it, generation array lives outside the
  PCB, wraps at 2**23. A pid from Proc:/spawner/process-cap
  badge can never name a later occupant of the same slot.
- Clean shutdown: Sys_System_Reset=33 (admin-gated) drives
  SBI SRST; Sys:System/Shutdown + Sys:System/Reboot run only
  under Elevate (admin mint at handle 5), sync every volume
  via the fileserver fan-out, then reset. Invocation is plain
  `Elevate Sys:System/Shutdown` (no shell builtins — the
  programs self-sync). NO SIGNALS — the filesystem is the only
  cross-process durable state; sync + reset IS the clean
  shutdown. The suite's last act is the real chain: every
  make run ends with qemu exiting 0 BY ITSELF (timeout 600 =
  backstop); post-suite fsck now validates durability across
  a true power transition. Elevation's first shipped
  consumer. BUILD TARGETS (post-57): `make run` =
  INTERACTIVE manifest (no Fuzz/Spin slots) for hands-on
  use; `make test` = the suite manifest (recurses into run
  with INITRD_MODE=test). The initrd regenerates on every
  build (FORCE dep) so a mode switch can never boot a stale
  manifest. Suite flow: `make test` (QEMU_SMP=4 default,
  =1 for the SMP1 gate).
- 49 shipped blocking pipes (deferred replies, drain passes);
  48 the virtio-blk write-back cache + flush chain; 47
  reply-cap duplication.
- 47 shipped reply-cap duplication; 46 Amiga pipes; 45
  elevation.
- BURNS logged in NEXT.md: kernel REJECTS write-only Mem_Map
  ((Flags and 3) = 2) — RW windows ask Flags 3; silent-reply-1
  failure paths need a Debug_Put_Line; a failing multi-edit
  call rolls back ALL edits; make all -j races the shared RTS
  lib; woken threads HEAD-INSERT the ready queue (never assert
  arrival order); grep syscall NAMES when migrating; audit
  every poll/Not_Ready expectation when a primitive goes
  blocking (old checks HANG); String(1..16) := 10-char literal
  is the m37b CE again; fuzz helper names live in SIBLING
  declare blocks — new blocks declare their own; drain AFTER
  the current op's window unmap; daemon consoles are serial-
  only — user-facing errors must be printed by the CLIENT
  (Elevate's 255 convention); harness
  timeout 600 s (now backstop only — qemu self-exits 0).
- 848/847 PASS SMP1/SMP4 (one old fat-lfn line lost
  to serial noise, failures=0), fsck clean pre/post,
  qemu exits 0 (self-poweroff) on both.

Open candidates — milestones 41-63 COMPLETE. Next: 64 TBD; the
deferred list (docs/NEXT.md): Proc:self (needs client
identity through the VFS), register fast path (probe IPC
cost first), custom GNAT runtime (tasking), virtio-net,
MSI-X, script interpreter,
background pipelines, Fileman actions (deficons —
could ride Trinket.Images), Xpm/ILBM decoders,
library versioning. Consciously deferred:
cooperative shutdown broadcast (m50: no server holds
in-memory state worth saving today); automated reboot-cycle
test (would loop); thread-id generations (m51: no identity
consumer today); background pipelines/redirection (m52:
run takes one command).

Recently landed: MILESTONE 63 — Trinket
images (datatypes-style Load dispatch,
Bmp decoder, color-key Blit, Image_Widget,
tdemo showcase, gen_images.py assets;
Files.Bind burn). Suites green SMP1+SMP4
984 PASS, failures=0, fsck clean.
Before that: MILESTONE 62 — true
scheduler priorities (best-first pop,
immediate crossing preemption,
Sys_Set_Priority=35 self/Manage-cap,
Proc: priority render, shell `pri`;
boost-consumed-at-pop burn). Suites
green SMP1+SMP4 972 PASS, failures=0,
fsck clean. Before that: MILESTONE 61
followup —
menus on every GUI app (Fileman/Tdemo via
Trinket.Window; raw Terminal/Demo via
Trinket.Menus.Serialize + Surface_Set_Menus
direct). Suites green SMP1+SMP4 948 PASS,
failures=0, fsck clean. Before that:
MILESTONE 61 — Amiga
screen-bar menus (RMB/sticky, chrome in
Bureau, Edit File>Save/Quit) + bar RTC
clock. Before that: MILESTONE 60 — terminal
command history (injection-synced, CON:
lineage) + the Linux-keycode nav fix;
MILESTONE 59 (00e996e) — RTC/clock group
(Sys_Read_Clock, real dirent stamps, Date/
Wait, s-reldel). Suites green SMP1+SMP4,
failures=0. Before that: MILESTONE 58 (df2aec3,
f082fa5) — Trinket.Listview + Fileman +
terminal scrollback, and Tier-1 shared
libraries (Libs/Libserv/Testlib). Between 57
and 58: bb12c86 (make run = interactive,
make test = suite), 3fa4074 + f667fb0
(elevated/shell cwd-aware staging +
"cannot find executable", ENV: first-use
dir creation, additive Path). Before that:
MILESTONE 57 (e9cfe2f) — window protocol
v4 pointer capture, Scrollbar, Text_Edit,
Edit app. 881/880 PASS. 53-56 in NEXT.md.
Before that: MILESTONE 52 — shell
job control (run/jobs/wait; Done jobs
keep exit codes until wait claims;
Amiga orphan semantics). 848/847 PASS,
failures=0, fsck clean. Before that:
MILESTONE 51 — pid generation
counters. 795 PASS. Before that:
MILESTONE 50 — clean shutdown
(SBI SRST + System/Shutdown +
System/Reboot via Elevate; no
signals — fs is the only durable
state). 783 PASS, qemu self-exits 0.
Before that: MILESTONE 49 — true
blocking pipes. 774 PASS. Before that:
MILESTONE 48 — virtio-blk
write-back cache + flush chain
(VIRTIO_BLK_F_FLUSH, Op_Flush, loop-top
write-behind). 758 PASS SMP1+SMP4,
failures=0. Before that: MILESTONE 47 —
kernel reply-cap duplication (free-slot
reply caps, handle in a1, out-of-order
replies). 754 PASS. Before that:
MILESTONE 46 — Amiga pipes
end to end (PIPE:/NIL: + shell redirection,
Sort stdin filter). 742/743 PASS SMP1+SMP4,
failures=0, fsck clean. Before that:
MILESTONE 45 — System/Elevated +
Sys:C/Elevate (userspace-only sudo,
uniform ABI handle 5). Before that:
MILESTONE 44 — cwd-centric
resolution end to end: Set_Default_Volume
stripped from all CLI programs, CLI owns the
boot volume, Dir lists the cwd by default.
666/665 PASS SMP1/SMP4, failures=0, fsck
clean. Before that: MILESTONE 43 — Sys:C/Path
(Amiga syntax, global ENV:Path, canonicalizing
ADD, cwd-first Resolve_Command) and mkdisk.py
DELETED (host tools required, single image
source). Suite timeout 420 s. 666 PASS
SMP1+SMP4, failures=0, fsck clean. Before
that: MILESTONE 42 — cwd (ENV:CWD,
Amiga "/" parent idiom, Sys:C/CD, Resolve_Path
wired through every path command) + scripts
(shell execute builtin, failat, batch mode).
580 PASS SMP1+SMP4 both image sources,
failures=0, fsck clean. Before that:
MILESTONE 41 COMPLETE — 41c
data commands (Join/Search/Sort/List) with
idempotent fuzz end-to-end tests. 500 PASS
SMP1+SMP4 on both image sources, failures=0,
fsck clean pre/post suite. Burns in NEXT.md
(41c entry). Before that: MILESTONE 41b — Sys:C/ session
commands (Set/Get/Unset/Assign/Echo/Which/Version/
Fault), shell thins to help/exit +
CLI.Resolve_Command, fuzz Run_Command end-to-end
tests, Files.Write lazy shared buffer, and a
host-less tools/mkdisk.py that passes fsck.fat AND
sgdisk -v (four layout burns logged in NEXT.md:
BPB field-width shift, dot-entry overwrite, LFN
terminator, backup GPT). 423 PASS SMP1+SMP4 on
both image sources, failures=0, fsck clean
pre/post suite. Before that: MILESTONE 41a (a328369) —
Op_Rename (two-path wire: FROM words + TO in the
buffer cap; VFS resolves both volumes; fat32
cluster/size/attr-preserving dirent rewrite with
".." fixup) and Op_Volume_Info (BPB geometry +
FSInfo free count), then Sys:C/Copy, Delete,
Rename, Makedir, Info on make new-crate +
Akernel_User.CLI. Burns: console-printing child
outruns a bare yield-per-try reap poll under
SMP4 AGAIN (batch yields per try; never pass an
RC check on the initialized 0); IPC.md's op list
goes stale silently — new ops land there in the
same commit. 332 PASS SMP1+SMP4, failures=0,
fsck clean. Before that: MILESTONE 40 COMPLETE (4570ceb,
86b80a5, 64b4996) — the userspace RTS. RTS sources are
a static library (akernel_rts.gpr -> libakernel_user.a,
built once) + abstract base project
(akernel_program.gpr); program crates are ~10 lines.
Akernel_User.CLI is the command layer: args tokens,
ENV: variables, Amiga RC convention 0/5/10/20 made
REAL by the exit-code channel (exit a0 -> PCB -> reap
a1; Reap_Process_Code). make new-crate NAME=x DEST=c|
system scaffolds a crate into Sys:C/ or Sys:System/.
Burns: gpr extension does NOT propagate Exec_Dir (per-
crate line required — stale-bin trap: invisible until
the first real source change, verify with strings(1));
alr/gprbuild "up to date" can lie after interrupted
builds (alr clean). 307 PASS SMP1, fuzz failures=0,
fsck clean. Before that: MILESTONE 39 COMPLETE (0b37978,
a6800a0, 29392a8) — admin-gated introspection dumps.
No user model in the kernel ever: authority = holding
the Admin_Object cap (kind added LAST in the enum —
positions ride bootinfo), minted at boot into init's
bootinfo as "admin" (Manage+Transfer, handle
File_Count+2); the manifest token flows through
init's generic bootinfo token path. Sys_Cap_Info = 31
(sparse cap-slot walk) and Sys_Thread_Regs = 32
(blocked threads only — saved trap frame; running =
Busy, no cross-hart stop-the-world) write physmap
snapshots like process_info. Proc:<pid>/caps and
<pid>/regs render them (procfs holds admin at handle
4). Burns: a second receiver on the shared echo
endpoint steals rounds and its death fails the
endpoint (M34) — test peers get their own endpoints;
bare-yield reap polls outrun a console-printing
child under SMP4. 303/304 PASS SMP4/SMP1, fuzz
failures=0, fsck clean. Before that: MILESTONE 38 COMPLETE (f9d3a6a,
48da866, a29864d) — file headroom end to end:
boot_files 256; DYNAMIC PAGED CAP TABLES (16384
handles/process, 128-entry PCB root, PMM pages via
physmap, freed at last close/teardown; Cap_Entry 32
bytes by rep+size clause = compile-time fit guard);
fileserver per-file VA windows replaced by ONE shared
256 KiB window mapped per Op_Read (chunked passes),
name table 512; multi-page bootinfo (8 pages, 511
entries — was silently full at 63); boot-file caps
transfer WITH their Op_Set_Name messages (spawn
grant lists cap at 32 — didn't scale); user stacks 8
pages (16 KiB overflowed by cumulative declare-block
locals); LOUD last_chance (LCH:<file>:<line> via
debug putchar — a silent spin wedged the suite
invisibly twice); fat32 ReadDir skips . and ..
(subdir counts were off by 2); tests: 64 generated
initrd files, 300-cap mint/close crossing cap pages,
FAT32 64-file create/walk/count/delete with leftover
sweep. 272 PASS SMP1+SMP4, fuzz failures=0, fsck
clean. Before that: 37b-followup
(4076c55) — Dir qualified
paths (arg with ':' = fully qualified; bare = BD0:;
ReadDir failure prints an error instead of silent
empty), fileserver Max_Files 128, process slots 128
with O(1) free list (spawn peeks Free_Head, pops at
commit; Discard_Slot pushes only committed slots),
Max_Tasks 144. BIG burn fixed: fileserver client-buffer
window was DERIVED from Max_Files — the bump slid it
onto user text base 0x4600_0000 and the server copied
file data over its own code; 9 data-compare checks
failed while stat/open passed. Fixed windows are now
literals (0x4040_0000 files / 0x4240_0000 buffers) with
a compile-time Windows_Fit guard; bisect lesson:
stash-control against last green before touching the
kernel. 261 PASS SMP1+SMP4, fuzz failures=0, fsck
clean. Before that: MILESTONE 37 (a+b) — kernel process
introspection syscall + the Proc: volume. 37a:
Sys_Process_Info = 30 (resource cap, slot 0..31 or
U64'Last self, buffer memobj, offset) writes a 64-byte
binary snapshot (pid, SPAWNER pid — new PCB field
recorded at spawn, 0 = kernel-started; lifecycle, thread
state, cap count, IPC flags, blocked-on endpoint, call
badge) through the physmap per-word; authority reuses
the device_resource Kernel_Object+Manage gate, granted
down by the plain device_resource manifest token.
Statuses 0 / 1 no-slot / U64'Last; enumeration = 32
by-index queries (Op_ReadDir idiom). 37b: System/Procfs
(manifest program 7: console, procfs_server Receive,
device_resource) serves the file protocol subset on the
plain FS-driver path — init pushes Op_Add_FS
(device+label Proc) after spawn, zero VFS changes.
Every op renders fresh from 32-slot snapshot walks:
"" = dir (tree + pid dirs), "tree" = forest indented
by spawner, "<pid>/status" = key-value lines; dir
stat/open Bad_Args fat32-style, mutating ops Bad_Args.
Burns: fileserver Max_Files 16 was silently full (17th
boot file = Tests/Teardown lost its name slot; now 32,
same shape as the M34 slot burn); fuzz slice length
mismatch raised Constraint_Error and wedged the suite
silently; QMP pointer press needs separate move/down/up
events (batched coalesces to buttons=0, no focus); ':'
is uninjectable under VNC (shift+semicolon loses shift
across QMP/HMP/RFB paths — interactive colon needs
GTK). 262 PASS SMP1+SMP4, fuzz failures=0, fsck clean;
live: shell round-trip verified, proc checks drive the
exact Dir/Type ops. Before that: MILESTONE 36 — assigns (Amiga-style
session path aliases, pure userspace). The file server
holds a global in-memory table; every path resolution goes
through Resolve_Full — volume-miss prefixes match the table
case-insensitively, target substitutes (implied "/":
C:Dir -> Sys:C/Dir), resolution retries depth-capped.
Op_Assign = 14 set/remove, Op_Assign_List = 15 stateless
by-index. Mounting the sys-labelled volume seeds C: and
ENV:. Shell builtin: assign lists / assign N: T sets /
N: REMOVE drops. Rejected file-backed assigns (per-lookup
fs round-trip; session objects suffice). Burn: Sys:Prefs/Env
exists only after a shell runs (lazy Mkdir) — tests must
Mkdir ignoring status. 212 PASS SMP1+SMP4, fuzz
failures=0, fsck clean; live: assign lists C:/ENV:, Dir C:
works. Before that: MILESTONE 35 — plain send (syscall 29):
the Call send-phase only. Sender queues (or hands off to a
waiting receiver) and blocks only until a Receive takes the
message; no reply cap minted, sender wakes with Ok. TCB
records Reply_Wanted at Call/Send time; the dequeueing
Receive mints+park (call) or wakes immediately (send).
Failed-endpoint fast path + teardown drain apply unchanged.
A receiver learns call-vs-send only by replying — fails
Invalid (1), the established no-reply-cap code. Test peer
role "S" in userspace/teardown + fuzz choreography: delivery
preserves words+badge, reply-after-send rejected, sender
woke Ok, send on failed endpoint rejected Endpoint_Gone.
200/199 PASS SMP1/SMP4, fuzz failures=0, fsck clean.
Before that: MILESTONE 34 — endpoint teardown failing of
queued callers (the orphaned-shell burn). Endpoints carry a
Failed flag: closing a Receive-right endpoint cap with
Thread_Dying fails the endpoint — queued callers and the
waiting receiver wake with Result_Endpoint_Gone, fresh
Call/Receive fail immediately (new Endpoint_Gone status).
Send-only caps never fail an endpoint. Burns: (1)
Cleanup_Cap_Refs (the voluntary Process_Exit path) closed caps
WITHOUT Thread_Dying => True — only Discard_Slot passed it —
so Fail_Endpoint was unreachable for an exiting server; both
teardown paths now pass True. (2) Max_Process_Slots 16 was
silently full at boot (15 used) — now 32. Test peer
userspace/teardown (R = receive once, exit without reply; C =
call and report the wake code on a badged result endpoint)
with deterministic fuzz choreography: awaiting caller wakes 4,
queued caller 3, late fresh call 3. Fuzzer must REPLY to
result calls (a0 = 254) or the last reporter parks. 192 PASS
SMP1+SMP4, fuzz failures=0, host fsck clean. Before that:
MILESTONE 33a — environment + command-line
conventions, Amiga-style (no env block, no argv ABI).
Variables ARE files: BD0:Prefs/Env/<NAME>, global by
construction. Shell builtins set [N=V] (bare set lists via
Op_ReadDir), get, unset, path; command resolution reads the
Path variable (';'-separated prefixes, default root then
C/). Arguments ride a one-page memobj at grant handle 4
(NUL-terminated, Map+Read; Syscalls.Read_Args). Sys:C/Type
streams a file to the console; Dir takes an optional
directory arg. Burns: Args_VA 0x4600_0000 == the userspace
link base (unmapped the caller's own .text — now
0x4800_0000); Type's 32 KiB buffer in the MAIN declarative
part blew the 16 KiB mapped stack (the init-stack burn
redux — big buffers must be genuinely library-level
packages). Verified live: set/get/list, path, Type
README.TXT, Dir System. Before that: MILESTONE 32 COMPLETE — window close +
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
- initrd's System/Manifest is generated by Makefile printf
  lines — edit the recipe; direct edits to initrd/root get
  overwritten by the next build.
- Fixed-size table at a round number? Assume it's silently
  full already (Max_Process_Slots M34, fileserver Max_Files
  37b) — adding one user bumps the cap in the same commit.
- Interactive QMP: pointer press = separate move/down/up
  events with settle sleeps (batching coalesces to no
  press); ':' untypable under VNC — use
  QEMU_ARGS="-display gtk" for interactive volume paths.
- Userspace VA windows are FIXED literals + a static
  overlap guard, never derived from table sizes — the
  Max_Files bump slid the fileserver buffer window onto
  the text base 0x4600_0000 and every data-copy check
  failed (37b followup). Data-compare failures across
  several servers at once = suspect a shared server's
  mapping layout, then stash-control against the last
  green commit before touching the kernel.
- Guards on record layout/table fit must be rep clauses
  or size clauses (compile errors), NEVER pragma Assert
  — assertions are disabled in the kernel build. A
  40-byte Cap_Entry spilled slot 127 past the 4 KiB cap
  frame into the next frame, wiped by Zero_Page; the
  assert guard never fired (38a burn). Same class:
  never derive ABI constants from table sizes —
  Address_Space_Cap_Handle was Handle'Last and silently
  moved 255 -> 16383 when Max_Caps grew while userspace
  hardcodes 255; now pinned to literal 255.
- Kernel debug instrumentation pattern that works:
  Board.UART.Put_Line_Unsafe/Put_Hex_Unsafe tag prints
  at every candidate failure exit, one build+run per
  narrowing. Remove before commit.
- Userspace exceptions hit last_chance and used to
  yield-loop SILENTLY = invisible system wedge (the
  "two adjacent source lines never executed" paradox
  means somebody crashed). Now prints
  LCH:<file>:<line> via the debug putchar ecall.
  Check the log for LCH FIRST on any hang; QMP
  "info registers" mid-hang names the spinning
  process/pc.
- Mind string literal lengths in table-driven tests:
  "Tests/Gen/f00" is 13 chars — a String(1..12)
  declaration raises Constraint_Error at block
  elaboration, before any debug print in the body.
- A mutating FAT op costs ~0.4 s (write-through sync
  scaling with FAT size): keep FAT stress loops at
  ~64 ops per phase inside the suite budget; fuzz file-op
  test data stays ONE cluster (an ELF copy = ~129 ops
  ate the whole budget, masquerading as a wedge). The
  suite harness timeout is 600 s (host variance alone
  swings ±100 PASS) — a mid-staging stop with no LCH
  and no FAIL is a budget, check wall-clock
  before bisecting.
- initrd/root/System/Manifest (and all of initrd/root) is
  REGENERATED by the Makefile on every initrd build — edit
  the printf lines in the Makefile, never the generated
  file. A missing manifest token presents as an IPC Call
  that blocks forever (wrong endpoint object, no receiver);
  diagnose by comparing admin Cap_Info object addresses
  from both the client and server side.
- Programs that are BOTH Startup children and commands must
  see the SAME handle layout on both paths (uniform ABI:
  1 console, 2 fs, 3 bureau, 4 args page — always granted,
  empty when unused — 5 elevation svc). Granting a right
  outside the source cap's rights fails the WHOLE spawn.
- Unproven staging VAs can land inside the RTS heap
  (0x05C0_0000 burned): Mem_Map then fails — reuse the
  shell/devmgr-proven regions.
- The RTS heap is 2 MiB TOTAL (8 x 256 KiB chunks): size
  per-program heap buffers (Sort's stdin slurp) with
  headroom for the line table + RTS slack, or Storage_Error.
- Redirection-aware programs must (a) touch CLI.Arg_Count
  (or any CLI arg API) so Parse_Args runs — it also parses
  the args-page redirection trailer — and (b) exit via
  CLI.Exit_With, which Close_Redirects (flush + pipe EOF).
  Raw Read_Args/Process_Exit bypass both (the Type burn).
- Servers must thread the reply-cap HANDLE from Receive to
  Reply (milestone 47: free-slot caps, a1 of recv) — a
  per-request local, not a global, or deferred replies
  will cross-answer callers. When migrating, grep the
  syscall NAMES (IPC_Recv/IPC_Reply), not one spelling —
  demo.adb's bare calls slipped a sweep of ".Receive (".
- The kernel rejects write-ONLY Mem_Map ((Flags and 3) = 2);
  a window you only CPU-copy INTO still asks RW (Flags 3).
  Device-server op failures that reply status 1 without a
  log line are undebuggable — every failure exit gets a
  Debug_Put_Line (the Flags-2 read-window burn).
- Block-layer performance: measure time-to-fuzz-complete
  before/after (poll the log, not the 600 s kill). The
  write-back cache + explicit-only device flush took it
  465 s -> 369 s SMP1. Probe counters (Debug_Put_Line, NOT
  console RPC — a server's blocking sink RPC mid-request is
  the m31 cascade wedge) decide batching questions by data:
  reads dominated 9:1 so batched write-back was rejected.
- Durability layering (hardware-honest): write-behind =
  latency, never durability; VIRTIO_BLK_T_FLUSH only at
  explicit sync (Op_Sync chain); the suite ends with an
  explicit Files.Sync so host fsck validates the real path.
  Real hardware still needs a clean-shutdown milestone.
- Woken threads head-insert the ready queue (rendezvous
  boost): last-woken runs first, so report ARRIVAL order
  across processes is scheduler-defined — assert
  completion + payload, never arrival order.
- A failing multi-edit tool call rolls back EVERY edit in
  the call — when instrumentation or a fix seems to have
  "landed" but does nothing, grep the file before
  suspecting the logic (bit twice in m45/46).
- Kill stray qemu-system-riscv64 before rerunning — it holds the
  disk.img lock. Use pkill -f "[q]emu-system-riscv64" (bracket
  form) in a command that does NOT also invoke qemu: the
  invoking shell's own cmdline carries the literal
  "qemu-system-riscv64" from the qemu arguments and pkill -f
  kills the shell mid-script (silent truncation right after the
  last successful step — a stale test log then "confirms"
  results that never ran; check log timestamps).
- QMP input-send-event for absolute pointer (HMP mouse_move
  sends nothing to the virtio tablet); run target exposes
  -qmp unix:/tmp/qqmp.sock + -monitor unix:/tmp/qmon.sock.
  HMP sendkey needs shift- prefixes for capitals/symbols
  (shift-s, shift-;). Pixels are B8G8R8A8 = LE u32 AARRGGBB;
  decode screendump PPM bytes straight (R,G,B); trust the
  user's eyes over a decoder script.

Build/run: make all && make run (interactive) / make test
(suite; QEMU_SMP=1|4|8); disk.img is a
'run' dep (not in 'all'). qemu runs with -machine
virt,iommu-sys=on and virtio-pci devices.
```
