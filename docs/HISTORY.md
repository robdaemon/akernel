MILESTONE 65 SHIPPED: Tier-1 library versioning + shared
library manager. Added `userspace/libman` (`System/Libman`),
a system-wide registry that loads each library once, enforces
an Amiga-style `Min_Version` floor, mints per-client service
caps, and expunges the server when the open count reaches zero.
`Akernel_User.Libs` gained `Bind(Libman_Cap)` so programs opt
into the manager; `Open_Library` falls back to a private spawn
when no manager is bound. `Libserv` now advertises `Version`/
`Revision` in the rendezvous reply (words 0/1). The fuzz
harness binds the manager and exercises version-floor rejection,
multi-open distinct caps, partial-close refcounting, and
re-open after expunge. The manifest grew a `libman` token
(handle 6 in the fuzz line) and the remaining Fuzz handle
constants were realigned; suite green again SMP1+SMP4 with
failures=0, fsck clean, qemu self-exits 0. Burns: inserting
a new manifest token shifted every hardcoded Fuzz handle —
Constants Must Be Centralized. Also, `Boot_Cap` is not mapped
in non-init processes, so do not call it from spawned clients.
Full burn list is in the milestone commit and archived docs/NEXT.md under MILESTONE 65. Before that:

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
clean, qemu self-exits 0. Full burn list is in the milestone commit and archived docs/NEXT.md under
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
timestamped control+m63 runs both took 571 s. Full burn list is in the milestone commit and archived docs/NEXT.md under MILESTONE 63. Before that:
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
every child (22 deterministic reap timeouts). Full burn list is in the milestone commit and archived docs/NEXT.md under MILESTONE 62. Before that:
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
failures=0, fsck clean, kernel self-resets. Full burn list is in the milestone commit and archived docs/NEXT.md under MILESTONE 61. Before that: MILESTONE 60:
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
fsck clean, kernel self-resets. Full burn list is in the milestone commit and archived docs/NEXT.md under MILESTONE 60. Before that: MILESTONE 59 (00e996e) —
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
- BURNS logged in the git history: kernel REJECTS write-only Mem_Map
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
deferred list (archived docs/NEXT.md): Proc:self (needs client
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
Edit app. 881/880 PASS. 53-56 in the git history.
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
fsck clean pre/post suite. Burns in the git history
(41c entry). Before that: MILESTONE 41b — Sys:C/ session
commands (Set/Get/Unset/Assign/Echo/Which/Version/
Fault), shell thins to help/exit +
CLI.Resolve_Command, fuzz Run_Command end-to-end
tests, Files.Write lazy shared buffer, and a
host-less tools/mkdisk.py that passes fsck.fat AND
sgdisk -v (four layout burns logged in the git history:
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

Working rules burned in (details in the milestone commits and archived docs/NEXT.md):
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

---

## Archived from docs/RESUME.md — 2026-08-31

## Landed milestone detail

**Milestone 66 — kernel thread primitives (done)** (see
`docs/runtime/tasking.md`).

- [x] Add `Thread_Create`, `Thread_Exit`, `Thread_Self` syscalls.
- [x] `Sleep_Until` syscall + kernel sleep queue + timer programming.
- [x] Move to per-thread IPC buffers (initial thread keeps the legacy
  `0x6FFF_0000` VA; secondary threads supply a memory cap + VA).
- [x] Set `tp` from a syscall argument so each task can have TLS.
- [x] Add a minimal userspace thread test before touching Ada tasking.
- [x] Stabilise the test suite under SMP4 (the console-endpoint race
  that broke the shell is fixed; `make test` now passes).
- [x] Add `Tests/Thread_Test` to the auto-spawn manifest and make the
  full suite pass with it present.

### M66c/WIP state (thread test)

Done this session:

- Added `.tdata`/`.tbss`/`.tls_copy` sections to
  `userspace/rts/akernel/linker-riscv64.ld`.
- `start-riscv64.s` now copies the TLS template and zeros `.tbss`;
  secondary threads arrive with `tp` already set by the kernel.
- Added `userspace/thread_test/` crate and wired it into
  `INITRD_CRATES`/test manifest.
- Added `akernel_thread_entry` runtime trampoline so secondary
  threads get `gp` before calling the Ada worker.
- Fixed `Thread_Create` to map the new thread's kernel stack into the
  process address space (missing mapping was causing a kernel page
  fault on first trap).
- Fixed `Thread_Exit` not to deallocate the currently-running kernel
  stack before the context switch.
- Guarded `Kernel.IPC.Wake_With_Result` so it only modifies the saved
  context of blocked threads; this stopped a ready worker's saved `a0`
  (the real function address) from being overwritten with `0`.
- `thread_test` itself now passes: worker runs, sets `Worker_Done`,
  exits, and the main thread wakes and prints `PASS thread_test`.
- Added `Akernel_User.IPC.Send` (one-way Send) to the runtime IPC
  wrapper.
- Fixed a stale `Waiting_Receiver` bug in `Kernel.IPC.Call`/`Send`:
  when the registered receiver is not actually blocked in `Receive`
  (e.g., it is doing a nested `Send`), the stale reference is now
  cleared before the caller is enqueued.
- Fixed `Kernel.IPC.Receive` so the same thread can retake the
  receiver slot if `Waiting_Receiver` points back to itself.
- Changed the kernel's `IPC_Send` trap handler so `Send` is
  fire-and-forget: it queues the message and returns `Ok` instead of
  blocking the caller when no receiver is waiting. This prevents the
  console server from deadlocking against a sink that has not
  attached yet.
- Changed the console server's `Sink_Write` to use the new `Send`
  instead of a nested `RPC.Call`.
- Updated `userspace/fuzz/fuzz.adb` to skip the new thread syscalls
  (36-38) during the random syscall phase so a stray
  `Thread_Create`/`Thread_Exit` cannot corrupt the fuzz process.
- Added a memory fence in `Thread_Test_Sync.Worker` after setting the
  shared done flag.

Current state:

- `thread_test` passes reliably in isolation (SMP1 and SMP4).
- `userspace/thread_test/` is built and installed in the initrd,
  and `Tests/Thread_Test` is now part of the default test manifest.
- `make test` with the default `QEMU_SMP=4` passes end-to-end with
  `Tests/Thread_Test` present (verified multiple consecutive runs).
- The full-manifest hang was caused by a thread free-list bug:
  `Kernel.Processes.Initialize` linked the *initial* thread slots
  (0..127, one per process slot) into the secondary thread free
  list, so the first `Thread_Create` reused an in-use initial-slot
  TCB and corrupted an existing process.  The fix initializes the
  free list to only contain the secondary slots (128..255).

Root cause fixed this session:

- The terminal (and serial server) were replying to every received
  message, including plain one-way `Send`s.  After `Sink_Write` was
  switched to the new fire-and-forget `Send`, the terminal's reply
  with `Reply_Handle = 0` returned `IPC_Invalid`, caused it to exit,
  and took down the console/shell path.  The terminal now only
  replies when `Reply_H /= 0`.

Other fixes applied:

- `Handle_IPC_Call` and `Handle_IPC_Recv` now preset the saved a0
  result to `Result_Ok` before blocking, so a missed or misplaced
  wake no longer leaves `Result_Invalid` in the caller's hands.
- `Kernel.IPC.Call`/`Send` clear a stale `Waiting_Receiver` before
  enqueuing a caller.
- `Kernel.IPC.Receive` lets the same thread retake its own receiver
  slot.
- The `IPC_Send` trap handler is fire-and-forget; `Sink_Write` uses
  it instead of a nested blocking `RPC.Call`.
- The console server no longer self-destructs when a reply cap is
  stale or a caller has died.
- `userspace/fuzz/fuzz.adb` skips syscalls 36-38 in the random phase.
- Secondary-thread kernel stacks are no longer leaked: a thread
  exiting on its own stack records the frame on a per-CPU deferred
  list, and the trap handler / idle loop drain the list once the
  hart is running on a different stack.

**Milestone 67a — `Thread_Wait` (join) (done)**.

- [x] Kernel wait list per thread (head + next + back-pointer) so a
  caller can block until the target exits.
- [x] `Blocked_Thread_Wait` thread state; wake path sets a0 = Ok.
- [x] `Thread_Wait` syscall (40): validates `Thread_Object` cap with
  `Wait` right, returns immediately if target is already dead,
  otherwise blocks and is woken by the target's exit path.
- [x] Waiter cleanup on process exit (`Mark_Exited` removes each
  dying thread from any target's list and wakes any waiters of
  the dying threads).
- [x] `Akernel_User.Syscalls.Thread_Wait` wrapper and raw asm.
- [x] `userspace/thread_test/thread_test.adb` now also exercises
  `Thread_Wait` on the worker cap.
- [x] Fuzz skip list updated for syscall 40.
- [x] `make test` passes end-to-end under SMP4 and SMP1.

**Milestone 67b — Ravenscar runtime skeleton (done)**.

- [x] Vendored the `light-tasking-polarfiresoc` GNARL sources into
  `userspace/gnat-rts/gnarl_user/` as the starting point.
- [x] Wrote a minimal `System.OS_Interface` (`gnarl_user/s-osinte.adb`)
  that sits directly on Akernel syscalls instead of `System.BB`.
- [x] Wrote a minimal `System.Task_Primitives.Operations`
  (`gnarl_user/s-taprop.adb`) that creates threads, delays, and
  exits via the Akernel syscall layer.
- [x] Provided an Akernel-specific `System.Multiprocessors` that does
  not depend on `System.BB`.
- [x] Added the missing fields to `System.Tasking` records
  (`Global_Task_Lock_Nesting` in `Common_ATCB`, `Current_Excep` in
  `TSD`) so the tasking `System.Soft_Links` body can compile.
- [x] Added a tasking `System.Soft_Links` body and a tasking
  `System.Init` so `No_Tasking` can be removed for the tasking
  runtime build.
- [x] Added `pragma Profile (Jorvik)` to the tasking `system.ads`
  so the compiler emits Ravenscar tasking calls.
- [x] Merged the tasking runtime into the single Akernel GNAT
  runtime: `userspace/gnat-rts/runtime_build.gpr` now uses
  `gnarl_user/` before `gnat_user/` and excludes the
  non-tasking units, and the separate tasking-only project and
  `No_Tasking` runtime have been removed.
- [x] Created `userspace/task_test/` crate with a library-level
  task that delays and prints.
- [x] The runtime compiles and links; `task_test` builds and the
  kernel successfully spawns it.
- [x] Fixed the runtime `Create_Task` success check, reduced the
  tasking `Default_Stack_Size` to 1 MiB (the kernel object limit is
  256 pages), and skipped TLS allocation when `TLS_Size` is 0.
- [x] Added a `User_Thread_Cap` field to the kernel TCB and made
  `Thread_Self` return the thread cap handle, fixing the worker's
  `Self`/`Get_ATCB` lookup.
- [x] `task_test` now passes: the worker schedules, prints, delays,
  sets the done flag, and exits; the main thread wakes and prints
  `task_test: main done`.
- [x] `make test` passes end-to-end with `Tests/Thread_Test`
  present.
- [x] The non-tasking runtime (`gnat_user/system.ads` with
  `No_Tasking`, plus `s-init`/`s-soflin` non-tasking bodies and the
  separate `gnat-rts-tasking` project) has been deleted. All
  userspace Ada programs now build against the unified Ravenscar
  tasking runtime.
- [x] Fixed `gnarl_user/s-init.adb` so `Runtime_Initialize` calls
  `System.Tasking.Initialize`; this makes the tasking soft links
  (global locks via `Self`/`Get_ATCB`) work for programs that do
  not declare any Ada tasks.
- [x] Updated the Makefile to regenerate the runtime
  `ada_source_path`/`ada_object_path` files and to provide a
  `libgnarl.a` placeholder so gprbuild recognizes the tasking runtime.

**Cleanup pass (done).**

- [x] Replaced the empty `libgnarl.a` placeholder with a real
  GNAT/GNARL split: after `gprbuild` produces `libgnat.a`, the
  Makefile moves the GNARL objects (`s-taprop`, `s-taskin`,
  `s-osinte`, `a-reatim`, etc.) into `libgnarl.a` and deletes them
  from `libgnat.a`.
- [x] Dropped `Asm` from `userspace/rts/akernel_program.gpr`'s
  base language list and added a per-crate `Asm` override in
  `userspace/fuzz/fuzz.gpr` so only crates with assembly sources
  compile `Asm` (eliminates the "no sources of language Asm" warnings).
- [x] Added `.note.GNU-stack` to all `.s` files and
  `-Wl,-z,noexecstack` to the program linker switches; this removes
  the `requires executable stack` linker warning.
- [x] Added `-Wno-deprecated-declarations` and
  `-Wno-unused-variable` to the runtime C flags so the vendored
  `adaint.c` / `sysdep.c` files build silently.
- [x] Fixed every kernel Ada warning/style diagnostic:
  redundant `with`/`use type` clauses, unreferenced constants and
  local functions, unused variables, line-too-long style errors,
  multiple blank lines, and the always-false `Diff < 0` check in
  `Kernel.Notifications.Slot_Of`.
- [x] Fixed every userspace Ada warning diagnostic:
  lower-bound assumptions on string slices, the uninitialized
  aggregate in `Akernel_User.Gloss.Fill_Stat`, and the incorrect
  `pragma Unreferenced (PX)` in `Trinket.Widgets`.
- [x] Full `make clean && rm -rf userspace/gnat-rts/adalib
  userspace/gnat-rts/obj && make all` now builds the whole system
  with **zero compiler/linker warnings**, and `make test` passes
  end-to-end.
- [x] Fixed the SMP1 test-suite slowdown caused by the unified
  tasking runtime: `System.Soft_Links.Task_Lock_Soft`/
  `Task_Unlock_Soft` now short-circuit (no `Self`/priority
  syscalls) for programs that never create secondary threads.
  This restores the previous single-thread performance while
  keeping full locking once `Create_Task` has run. `make test
  QEMU_SMP=1` now completes in normal time again; `make test`
  (SMP4) and interactive boot remain passing.

**Milestone 41b — `Proc:self` / VFS client identity (done).**

- [x] Added an endpoint-level identity-stamp flag in `Kernel.IPC`.
  When set on an endpoint, a zero-badged capability call through it
  gets the caller's process id as `Message.Badge` instead of badge
  zero.
- [x] Added syscall `EP_Set_Stamp_Identity` (41); init marks the
  fileserver endpoint with it after creation.
- [x] `userspace/fileserver/fileserver.adb` forwards `Proc:` driver
  requests through a per-caller cached, minted cap carrying the
  original caller pid; other fs-driver volumes keep using the
  unminted endpoint cap to avoid per-request overhead.
- [x] `userspace/procfs/procfs.adb` resolves `Proc:self` and
  `Proc:self/status|caps|regs` from the forwarded badge.
- [x] `Process_Info(Self_Slot)` no longer requires the
  `device_resource` authority; a process can read its own pid.
- [x] `userspace/fuzz/fuzz.adb` checks its own pid against
  `Proc:self/status`.
- [x] Stabilised the suite under SMP4 after the identity plumbing:
  switched `Run_Command`'s reap poll and the teardown test's
  caller/receiver sequencing from fixed-yield counts to short
  wall-clock waits, so SMP4 scheduling does not outrun the peers.
- [x] `make all` builds with zero warnings; `make test QEMU_SMP=1`
  and `make test QEMU_SMP=4` pass end-to-end.

**Milestone 67 — MSI-X for virtio PCI (done).**

- [x] Implemented a software MSI controller on top of the RISC-V IOMMU:
  MSI/MSI-X writes are detected by address pattern, forced to fault on an
  invalid flat MSI page table, and converted into virtual kernel IRQ
  source deliveries by the fault-queue handler.
- [x] Added virtual IRQ sources (1024..2047) alongside real PLIC sources
  (0..1023); `IRQ_Ack` skips PLIC completion for virtual sources.
- [x] Added syscall `IRQ_MSI_Create` (42): returns an IRQ cap and the
  MSI address/data to program into the PCI MSI/MSI-X table entry.
- [x] Device manager parses the PCI MSI-X capability, maps the table,
  allocates one shared vector per PCI function, programs all table
  entries, and hands the MSI IRQ cap to drivers in the config message.
- [x] `Virtio.PCI` learned `Enable_MSIX`; all PCI virtio drivers
  (`virtio_blk`, `virtio_rng`, `virtio_input`, `virtio_gpu`) use the MSI
  vector when offered and fall back to INTx otherwise.
- [x] `make all` builds with zero warnings; `make test QEMU_SMP=1` and
  `make test QEMU_SMP=4` pass end-to-end.

**Milestone 68 — Trinket app port: Swing-style worker messaging (done).**

- [x] `Trinket.App_Port`: one-page process-shared ring (127 four-word
  messages `Code, A0, A1, A2`), multi-producer `Post` (PO-locked,
  drop-new) and single-consumer `Drain`; code 0 reserved for quit;
  signals bit 2 on the loop thread's bound notification.
- [x] `Trinket.Window` integrates the port: `Post`/`Set_App_Handler`,
  `Request_Quit` re-implemented as a posted quit message (safe from
  any thread), `Run` drains the port on every notification wake.
  Public API source-compatible.
- [x] Ravenscar runtime SMP-safety fixes (`userspace/gnat-rts/
  gnarl_user`): runtime task lock is a spin-lock with `Yield` backoff
  plus a per-task priority-ceiling boost recorded in a new per-ATCB
  field (the single global saved-priority slot raced across harts);
  task creation initializes the kernel-visible priority table; task
  activation restores the saved ACTIVE priority (was permanently
  raising the activator's kernel priority); runtime initialize syncs
  its priority bookkeeping with the kernel instead of trusting
  `Main_Priority`.
- [x] Kernel: unbound `Ntfn_Wait` blocking was a one-way trip —
  `Signal` only woke the bound thread. Notifications now record a
  single waiting thread (`Record_Waiter`/`Clear_Waiter`); `Signal`,
  `Release`, `Discard`, and cap cleanup wake/clear the waiter.
- [x] Kernel: fire-and-forget `Send` no longer queues the live caller
  thread (its next IPC op clobbered the buffer, badge, and queue
  links — a send followed by a report call cross-delivered the call
  to the send's receiver; deterministic SMP1 failure). The message is
  now copied into a fixed pool of queued-send slots (64, system-wide)
  chained off the endpoint; cap-carrying sends and a full pool fall
  back to the blocking rendezvous. See `docs/IPC.md`.
- [x] Headless port test `userspace/fuzz/fuzz_port` (worker tasks
  gated on per-worker notifications, watchdog task, 24 checks:
  single/two-producer FIFO, overflow, quit interception) and the
  tdemo Work button (a worker task loads/decodes an image off the
  event thread and Posts the result; the dispatch thread swaps it
  into the widget tree via the new `Widgets.Set_Image` — see
  `docs/trinket/window.md`).
- [x] `make all` builds with zero warnings; `make test QEMU_SMP=1`
  (2/2) and `make test QEMU_SMP=4` pass end-to-end.

**Milestone 69 — shell background pipelines (done).**

- [x] `run` accepts the full pipeline/redirection syntax
  (`run A | B > file`): the m46b `Run_Pipeline` split into
  `Spawn_Pipeline` (parse/wire/spawn, out-params for stage caps +
  pipe names) and `Reap_Pipeline` (blocking reap-all, RC = last
  stage, caps + pipes deleted); the foreground path is unchanged.
- [x] Jobs are process groups: `Job_Rec` carries up to 4 stage
  proc caps + owned pipe names; `Harvest` polls every stage (a
  job is done when all stages exit; the code is captured from the
  last stage whenever it happens to finish); `wait`
  blocking-reaps a whole group; `pri` applies to every live
  stage.
- [x] Background pipes are slot-scoped `PIPE:BG<j><s>` names so
  the rotating foreground `PIPE:SH<n>` pool can never truncate a
  live job's pipe; deleted when the job is reaped. A spawn
  commits to a job slot only after every stage is live (mid-spawn
  failure cleans up locally — no half-registered jobs).
- [x] `Fileserver_Pipes.Max_Pipes` 8 -> 32: background jobs hold
  their pipes until reaped (8 jobs x 3 pipes = 24, plus
  foreground shells).
- [x] Fuzz e2e via batch scripts: background
  `Type | Sort > file` verified byte-for-byte, last-stage RC
  composes with failat, two concurrent background pipelines +
  bare `wait`, BG pipes deleted on reap (Stat never creates a
  pipe, so absence is observable), bad background pipeline
  rejected with RC 10. (Write_File's staging Buf grew to 128
  bytes for the longer script texts, with a bound guard.)
- [x] `make all` builds with zero warnings; `make test
  QEMU_SMP=1` and `make test QEMU_SMP=4` pass end-to-end;
  desktop boot smoke clean.

**Milestone 70 — AmigaDOS-style script interpreter (done).**

- [x] New library crate `userspace/scripting/`: the root package
  holds the uniform-ABI handle constants + Split_Cmd (no U64
  subtype, so `use Scripting` is safe next to Syscalls);
  `Scripting.Exec` is the shell's stage/spawn/reap + pipeline
  engine extracted unchanged (chunk 1); `Scripting.Interp` is the
  interpreter core as a generic child — the host instantiates it
  with its own dispatcher and ask reader (formal subprograms, no
  accessibility trap), so script lines run builtins and nested
  `execute` re-enters with Depth + 1.
- [x] Language: .key/.k positional args + .def defaults, .set
  locals (defined-empty vs undefined — undefined <name> is a hard
  RC 10 "bad substitution"), <name> resolves locals then ENV:
  (<$name> forces ENV:; '<' only opens a reference when closed by
  '>' on the same line, so `< file` redirection and `a<b` stay
  literal); if [not] with exists / eq|ne|gt|ge|lt|le [val] /
  command forms (condition RC consumed), bare if tests the
  condition flag; else/endif 8 deep, skipped blocks never
  expanded; lab/skip [back] (skip abandons open if frames — the
  loop idiom relies on it); quit [rc]; failat <n>; echo [noline]
  (metachar lines fall through to C:Echo so > file composes);
  ask (condition flag from y/Y, RC_Warn 5 on "no").
- [x] New `Sys:C/Execute` binary (chunk 4): scripts without a
  shell, `run Sys:C/Execute s` backgrounds a script as a reapable
  job; its ask reads stdin via CLI.Get_Line so
  `echo y | Execute s` composes. The shell's ask reads the raw
  console stream (`Scripting.Console_IO.Read_Line`).
- [x] Stack fix: per-level line buffers + the locals table moved
  to the heap — five nested scripts over ~4 KiB frames each
  page-faulted the 48 KiB process stack before the depth cap
  fired. Run_Script owns the nesting counter (top-level batch
  script = Depth 1).
- [x] Fuzz e2e: byte-exact .key/.def/.set/substitution checks,
  ENV: shadowing + <$>, literal '<', bad-subst abort, nested
  execute args, every if arm, skip forward + skip-back loop
  (FZL1..3 one per pass), quit 7, inner quit 20 tripping the
  outer failat, failat 21 passing RC 20, echo > file, skipped-
  block substitution safety, the four malformed-script errors,
  C:Execute direct/piped/backgrounded, depth cap.
- [x] `make all` builds with zero warnings; `make test
  QEMU_SMP=1` and `make test QEMU_SMP=4` pass end-to-end;
  desktop boot smoke clean. Language reference:
  `docs/shell/scripting.md`.

**Milestone 71 — network stack** (plan locked 2026-08-25).

**M71a — VirtioNet driver (done).**

- [x] New crate `userspace/virtio_net/`: class-1 PCI driver on the
  virtio_blk skeleton; two split queues (RX=0/TX=1, Num=16), 16
  pre-posted 2048-byte RX slots (descriptor id == slot, repost on
  Pop), no feature negotiation beyond F_MAC (transitional device →
  legacy 10-byte `virtio_net_hdr`, confirmed working), MAC from
  device cfg, MSI-X via the shared per-function vector.
- [x] Frame service protocol on handle 7: `Op_Info=0` (MAC, MTU),
  `Op_Tx=1` (client frame memobj DMA'd directly as the second
  descriptor of a 2-chain; our zeroed header staging is the first),
  `Op_Set_Rx=2` (single consumer: ring memobj mapped for the
  driver's lifetime + netserv ntfn; frames published into
  {head, tail, dropped, slot count} + 2048-byte slots, drop-new
  with counter, ntfn bit 0 per batch).
- [x] Boot self-test: TX a crafted ARP request for 10.0.2.2
  (static slirp guest 10.0.2.15), wait for the reply —
  `PASS virtio-net arp reply ok`.
- [x] Wiring: devmgr records `Net_EP` for class 1 (first-wins,
  both spawn paths) and exports `Net_Service`; `driver pci,1af4
  Drivers/VirtioNet pci 1`; QEMU `-netdev user,id=n0 -device
  virtio-net-pci,netdev=n0,addr=0x8` (INTx swizzle 32, MSI-X
  takes over anyway).
- [x] Fuzz housekeeping: `Highest_Known` 35 → 42 (stale since
  M67), skip 42 (`irq_msi_create` fills kernel IRQ slots).
- [x] Full `make clean` + `make all` with zero warnings;
  `make test QEMU_SMP=1` and `QEMU_SMP=4` pass end-to-end.

### M71 remaining plan (locked 2026-08-25)

**M71b — Netserv skeleton (done).**

- [x] New crate `userspace/netserv/` (`System/Netserv`, manifest
  `program 10 System/Netserv console fs netdev net_server`):
  Ethernet demux, ARP (16-entry cache, learns requesters and
  repliers, answers requests, no aging, round-robin eviction),
  IPv4 (software checksums both ways, TTL 64, IHL=5 only, MF /
  fragment-offset dropped, dst must be us), ICMP echo requests
  answered and echo replies matched to the outstanding ping.
- [x] Op_Ping=40 on the service endpoint: word0 = target IPv4
  packed big-endian; reply (status, rtt in Read_Time ticks);
  status 0 ok / 1 no reply / 3 bad args. Ping self short-circuits
  (real hairpin lands with m71c sockets). ARP resolve and the
  echo wait are inline bounded poll-drains of the RX ring
  (2 s / 5 s deadlines) — the plan's "queue pending TX" is
  subsumed until m71c's decoupled socket TX needs a real queue.
- [x] Driver bring-up: Op_Info (MAC/MTU), 5-page RX ring memobj
  (8 slots) + thread-bound ntfn registered via Op_Set_Rx
  (Map+RW+Transfer mint for the ring, Write+Transfer mint for the
  ntfn; both mints deleted after the call, driver keeps its
  transferred copies for its lifetime). TX: one staging memobj,
  a Read+Manage+Transfer mint reused per Op_Tx.
- [x] Service loop: single IPC_Recv multiplexing Op_Ping, the
  file protocol (Net: registered via Op_Add_FS, empty root in
  m71b; read/write buffer caps deleted per op — procfs leaks
  them on rejected writes), and Notification_Label RX kicks.
- [x] Config: static 10.0.2.15/24 gw 10.0.2.2 dns 10.0.2.3,
  ENV:Net.Address/Gateway/DNS dotted-decimal overrides read
  through the fs token.
- [x] `Tests/Net_Test` (test-mode manifest `program 11
  Tests/Net_Test console net`): gateway ping (reply + RTT <
  1 s), self ping, unreachable 10.0.2.99 (ARP timeout →
  status 1), bad-args rejection.
- [x] Kernel fix: `Max_Notifications` 16 → 32 — the pool was
  exactly full in m71a (14 steady + fuzz's 2 test objects);
  netserv's one ntfn tipped it and starved fuzz's ntfn phase
  ("ntfn create distinct handles" FAIL, then the app-port test
  wedged). Cap accounting audited first: insert retains,
  delete/exit releases, no leak — netserv holds exactly one
  object steady-state.
- [x] Full `make clean` + `make all` zero warnings; `make test`
  SMP1 and SMP4 pass end-to-end (twice on SMP4).

**M71c — sockets + ping + Net: (done), with one amendment.**

- [x] Socket ops in netserv: `Op_Socket=20` (words
  domain/type/proto; cap0 two-page ring-pair memobj, cap1 client
  ntfn) → **(status, socket id) in reply WORDS — caps do not
  travel in IPC replies in this kernel (Kernel.IPC.Reply drops
  them; transferring there was tried and reverted: servers leave
  dead request caps in their reply buffer, and every reply site
  in every server would have needed auditing — M75 later did the
  audit and lifted the restriction; the badged-mint design stays). The client mints
  its own cap on the service endpoint with badge = socket id
  instead.** Badges demux, they are not authority (the pid
  badges the file server forwards are equally self-asserted).
  Ops on the badged mint: `Op_Bind=21` (0 = ephemeral from
  49152+), `Op_Connect=22` (default peer + RX filter),
  `Op_Kick=23` (one-way Send), `Op_Poll=24` → (status, rx
  level, tx free, sticky error), `Op_Close=25`. Server → client
  ntfn bit 0 = RX readable, bit 1 = sticky error.
- [x] Ring pair: page 0 RX (server produces), page 1 TX (client
  produces); word0 head / word1 tail / word2 dropped; 4 slots ×
  1008 at offset 64; entry = len:u16, flags:u16, addr:u32,
  port:u32, ≤996 payload. TX entries carry the destination (0 =
  the Connect default); RX entries the source. Wire datagrams
  truncate at 996 (recv semantics).
- [x] UDP: closed local port → ICMP port-unreachable on the
  wire; hairpin (dst == own address) delivers internally, a
  closed hairpin port sets the sender's sticky error (1 =
  hairpin closed, 2 = ARP failed, 3 = usage). UDP checksum 0 on
  TX (legal in v4).
- [x] ICMP ping sockets (SOCK_DGRAM/IPPROTO_ICMP): netserv owns
  type/code/ident/checksum and the IP header; ident = socket id
  makes reply matching trivial; hairpin fabricates the reply.
- [x] `Akernel_User.Sockets` (Socket/Bind/Connect/Send_To/
  Recv_From/Poll/Close/Parse_IP/Ip_Image): client VA window
  16#4A00_0000# (16#4600# is the link base, 16#4800# the args
  page); waits poll the rings in 5 ms Sleep_Until slices.
- [x] Uniform command ABI gains handle 6 = netserv client
  endpoint (Scripting.Net_EP). Granted by: devmgr Spawn_Program
  (Sys: programs see it at handle 5), terminal → shells (6),
  fuzz → batch shells/commands (6; fuzz manifest token handle
  11), Scripting.Exec → commands (6). An invalid grant source
  fails the whole spawn — all spawners were extended in the same
  commit.
- [x] `Sys:C/Ping` (`ping [-c N] <ipv4>`, numeric only): RC 0
  all answered / 5 partial / 10 none-or-usage; RTT from the
  echoed timestamp payload.
- [x] `Net:` volume: status/address/gateway/dns/arp readable
  (root stat-able + enumerable; m64 is_dir in word 4);
  address/gateway/dns writable (dotted decimal, offset-0
  whole-value writes). Read/write buffer caps mapped at
  16#54A0_0000#, deleted per op. File-op dispatch is by LABEL
  (0..18), never badge — forwarded ops carry pid badges.
- [x] `Tests/Udp_Test` (manifest program 12, test mode): reads
  its own address from Net:address, hairpin A→B with source
  reporting + payload integrity, closed-port sticky error.
- [x] Fuzz e2e: `ping -c 1 10.0.2.2` RC 0, `ping -c 1 10.0.2.99`
  RC 10, `type Net:status` RC 0.
- [x] Full `make clean` + `make all` zero warnings; `make test`
  SMP1 and SMP4 pass end-to-end.

### M71 remaining plan (locked 2026-08-25)

Locked decisions: UDP+ICMP first, TCP is its own milestone (hand-rolled
Ada vs vendored lwIP decision deferred until M72); socket data plane =
per-socket shared ring pairs + notification readiness bits (app-port
style); runtime config = writable `Net:` volume served by netserv,
seeded from `ENV:Net.*` at boot; no new syscalls — everything is
endpoint protocols (socket ops are message labels, payloads move in
memobj caps/rings).

Layering:

```
Sys:C/Ping, user programs
  |  Akernel_User.Sockets  (client lib in rts/akernel)
  v  NETSRV_EP: socket ops as message labels; minted per-socket caps
  |  (badge = socket id, partmgr pattern); shared rings + client ntfn
System/Netserv  — Ethernet demux, ARP, IPv4, ICMP, UDP, Net: volume
  |  NETDEV_EP: frame protocol (Op_Info / Op_Tx / Op_Set_Rx ring+ntfn)
  v
Drivers/VirtioNet — class-1 PCI driver: RX/TX split queues, MSI-X
  v
QEMU: -netdev user,id=n0 -device virtio-net-pci,netdev=n0,addr=0x8
      (slirp: guest 10.0.2.15/24, gateway/DNS 10.0.2.2 / 10.0.2.3)
```

Chunks:

- **M71a — VirtioNet driver.** Two split queues (RX=0/TX=1, Num=16),
  RX pre-posted 2048-byte slots from a DMA memobj (repost on Pop,
  virtio_input eventq model), no feature negotiation (word 0 = 0 →
  transitional device runs legacy → 10-byte `virtio_net_hdr`; verify
  on first boot). MAC from device cfg offset 0..5. Service protocol:
  `Op_Info=0` → (status, mac_lo, mac_hi, mtu); `Op_Tx=1` (cap0 frame
  memobj, word0 length); `Op_Set_Rx=2` (cap0 RX ring memobj, cap1 ntfn
  Signal cap; single consumer; driver publishes frames, signals bit 0).
  RX ring: {head, tail} header + 2048-byte slots. Self-test: TX a
  crafted ARP request for 10.0.2.2, expect a reply frame. Wiring:
  devmgr records Net_EP for class 1 (first-wins, both spawn paths),
  `driver pci,1af4 Drivers/VirtioNet pci 1`, QEMU netdev line.
  Housekeeping: fuzz Highest_Known 35 → 42 and skip irq_msi_create.
- **M71b — Netserv skeleton.** ARP (16-entry cache, queue pending TX,
  answer requests, no aging), IPv4 (software checksums, TTL 64, drop
  frags/options), ICMP echo request+reply both ways, internal Op_Ping
  test op (RTT via Read_Time). Static config 10.0.2.15/24 gw/dns
  10.0.2.2/10.0.2.3, ENV:Net.* override. Manifest
  `program 10 System/Netserv console fs netdev net_server`; init mints
  NETSRV_EP (tokens: net_server = Receive, netdev = driver Send,
  net = client Send), pushes Op_Add_FS label Net. Single IPC_Recv
  multiplexing ops + synthetic Notification_Label RX kicks.
  Tests/Net_Test: ping the slirp gateway, assert reply + sane RTT.
- **M71c — sockets + ping + Net:.** `Op_Socket=20` (words
  domain/type/proto; cap0 ring-pair memobj, cap1 client ntfn) → minted
  socket cap (badge = socket id); ops on the socket cap: `Op_Bind=21`,
  `Op_Connect=22` (UDP default peer + filter), `Op_Kick=23` (one-way
  Send, "TX ring dirty"), `Op_Poll=24` (rx level/tx space/error),
  `Op_Close=25`. Server → client ntfn bit 0 = RX readable, bit 1 =
  error/closed. Datagram ring entry {len:u16, flags:u16, src_addr:u32,
  src_port:u32, payload…}. UDP sockets with closed-port → ICMP
  port-unreachable and hairpin loopback (dst == own addr loops
  internally — self-contained test). ICMP ping sockets =
  SOCK_DGRAM/IPPROTO_ICMP (Linux ping-socket semantics: netserv owns
  the IP header, assigns ident per socket, matches echo replies).
  `Akernel_User.Sockets` client lib (Socket/Bind/Connect/Send_To/
  Recv_From with ntfn+Sleep_Until timeout/Close/Poll). `Sys:C/Ping`:
  `ping [-c N] <ipv4>`, numeric only, Amiga RC 0/5/10. `Net:` volume
  (procfs-clone): status/address/gateway/dns/arp readable, writable
  address/gateway/dns via Op_Write. Fuzz e2e: ping gateway RC 0, UDP
  hairpin crate, type Net:status.

Later milestones (sketch):

### M72 — TCP via vendored lwIP (locked 2026-08-26)

Decision: **vendored lwIP, not hand-rolled.** Rationale: the project
needs a C-library integration path anyway (freetype is the next
candidate), so M72 doubles as its vanguard. Verified
2026-08-26: `alr exec -- riscv64-elf-gcc` 15.3.0 compiles+links
newlib code; the only stubs the link needs are exactly what
Akernel_User.Gloss (m53b) already exports; runtime_build.gpr is the
`Languages ("Ada", "C")` precedent with `-Wno-error` per-file hatches.

**Vendor policy (user-locked): no vendored code in git.** `third_party/`
is gitignored (exception: `third_party/patches/` for tracked patches);
tarballs in `third_party/download/`, extracted tree in
`third_party/lwip/`. If the tree is missing at make time: download
(curl -L, sha256-pinned) → extract → apply patches → stamp. Committed
side: the Makefile rules, `userspace/lwip/lwip.gpr` (static library
project, Source_Dirs point into ../../third_party/lwip) and
`userspace/lwip/port/*`.

**Architecture: lwIP NO_SYS raw API replaces netserv's hand-rolled
ARP/IPv4/UDP/ICMP internals; every external protocol stays
byte-identical** (ring pairs, ops 20–25, badges, Net: files).
- Port: `lwipopts.h` (NO_SYS=1, MEM_LIBC_MALLOC=1 — lwIP allocs ride
  newlib malloc → gloss _sbrk arena; LWIP_IPV6=0 — lwIP is dual-stack
  capable, our ring ABI is u32-addressed, revisit far later), `cc.h`,
  minimal `sys_arch` (sys_now off Read_Time), `akernel_netif.c`
  (linkoutput → virtio TX ring; RX → ethernet_input; **frame-level
  hairpin**: dst MAC == ours → feed frame back into ethernet_input,
  one loopback mechanism for UDP/ICMP/TCP).
- UDP socket → udp_pcb; ping sockets + Op_Ping → raw ICMP pcb (ident
  = socket id); Net:arp renders the etharp table; Net:status counters
  from lwip_stats; Net: writes → netif_set_addr (live).
- Ticker thread (Thread_Create + 50 ms Sleep_Until loop) signals the
  main loop's bound ntfn bit 2 → sys_check_timeouts(). No kernel
  changes; no new syscalls.
- TCP (m72c): tcp_pcb per socket. Op_Connect on TCP = tcp_connect +
  bounded poll-drain until the callback (NO_SYS ⇒ callbacks run in
  Drain_Ring/tick context); Op_Listen=26, Op_Accept=27 non-blocking
  (Poll reports backlog; Accept takes a fresh ring-pair memobj, reply
  carries child id, client mints badge — m71c pattern). Streams over
  the existing slot rings (recv callback chunks pbuf chains into ≤996
  slots; TX drain → tcp_write/tcp_output; graceful Op_Close with
  bounded FIN drain). Sticky errors +4 refused, 5 timeout, 6 reset.
  Tuning to ring geometry: TCP_MSS=996, TCP_WND=3984,
  TCP_SND_BUF=3984. Net:tcp netstat listing.

Chunks (each independently shippable + green):
- **M72a — plumbing (done).** gitignore + Makefile fetch rules; lwip.gpr +
  port layer; netserv.gpr withs it, lwip_init() smoke at startup,
  stack not yet switched. Gate: full suite green.
- **M72b — engine swap (done).** All m71c tests pass byte-for-byte unchanged
  (udp_test, ping ×3, Net: files, fuzz e2e) — the regression net.
  Hand-rolled ARP/IPv4/UDP/ICMP deleted.
- **M72c — TCP (done).** Tests/Tcp_Test (manifest program 13, deterministic
  hairpin: listen/accept/connect, bidirectional echo, multi-KB
  transfer, refused, orderly close) + tools/tcp_echo.py host server
  on 127.0.0.1 started by make test (guest → 10.0.2.2 via slirp) +
  fuzz `type Net:tcp`. Gates: zero-warning clean build, SMP1+SMP4.

Out of scope: DHCP, IPv6, lwIP socket/netconn APIs, cc tuning.

**M72a landed (2026-08-26).** `.gitignore` ignores `third_party/*`
except `third_party/patches/`; Makefile `LWIP_*` rules download
lwIP 2.2.1 (GitHub mirror of the savannah tag; the savannah release
mirrors 404), sha256-verify, extract, patch and stamp on demand.
`userspace/lwip/lwip.gpr` builds the vendored subset as a static
C-only library (`-Wno-error`; port files in `userspace/lwip/port/`
get `-Werror`): lwipopts.h (NO_SYS, MEM_LIBC_MALLOC → gloss _sbrk
arena, TCP_MSS/WND 996/3984), arch/cc.h (newlib stdio diagnostics;
SSIZE_MAX shim so arch.h takes unistd.h's ssize_t), arch/perf.h,
sys_arch.c (sys_now = akernel_rdtime/10^4). netserv links it and
calls lwip_init at bring-up ("netserv lwip 2.2.1 init ok").

**Found while gating: the fs<->netserv bring-up deadlock (latent
since m71c, ~50% SMP4 wedge once lwip_init widened the window).**
netserv did its blocking ENV: fs reads during bring-up while init
had already mounted Net: at spawn — so an early `Net:address` open
(udp_test) made the fs block forwarding to netserv while netserv
blocked on the fs: circular wait, whole-system wedge (forensics:
QEMU monitor physical-memory walks of the kernel thread table and
endpoint queues; queued message payloads named every actor). Fix:
init no longer pushes the Net: mount; **netserv self-registers via
Op_Add_FS as its last bring-up step**, using a new `net_register`
manifest token (Send+Transfer mint of NETSRV_EP — its Receive-only
net_server handle cannot mint Send). While serving, netserv makes
no blocking fs calls, so no cycle can form. udp_test retries its
first Net:address open for 2 s (registration window). Verified:
6/6 SMP4 + 2/2 SMP1 green incl. clean rebuild.

Watchlist addition: **kernel endpoint-queue integrity.** The wedged
machine's fs endpoint had a caller-queue tail pointing at a
non-thread heap address, and Thread_Exit never dequeues a thread
from endpoint caller queues (Dequeue_Caller skips Is_Dead nodes,
but an out-of-table link would be followed into a wild write).
Root corruption path unidentified; likely "death while queued".
Forensics tooling notes: qemu monitor `xp` reads PHYSICAL memory
(gdbstub reads fail for kernel BSS); strip ANSI echoes and parse
only `addr:` data rows (keystroke echo transients inject spurious
tokens); TCB/endpoint offsets via `gdb -batch -ex "ptype /o"`;
kernel VA→PA: text/bss -0xffffffff80000000+0x80000000, heap objects
(endpoint slab) live at 0xffffffc080xxxxxx.

**M72b landed (2026-08-28).** netserv's engine is lwIP 2.2.1 raw
API (`userspace/lwip/port/aknet_glue.c`): netif output does not
consume the caller's pbuf, input paths always consume, udp recv cb
owns its pbuf, raw recv cb nonzero = callback freed it. Hand-rolled
ARP/IPv4/UDP/ICMP deleted; the m71c suite passes byte-unchanged.
Bug crop: pbuf_ref before ip4_input on the hairpin (double-free
spin); raw-ICMP recv cb must free when "eaten"; the "udp closed
port reports error" flake (client kick is now an IPC_Call, netserv
Handle_Ping is async with Ping_Reply_H/Ping_Limit + Reply_To).

**The line-769 wedge root cause: a double schedule in Block_Current.**
Every trap-level block path must schedule exactly once. The recv/
IRQ-wait paths Set_State + Schedule_Saved_Context (one Yield), but
Sleep_Until and Thread_Wait called Block_Current — which Yielded
itself — and their trap handlers then called Schedule_Saved_Context
— a second Yield. The first Yield popped the ready-queue head and
made it Current; the second immediately re-queued it (tail) and
popped someone else. The victim never ran and lost its FIFO slot,
so one head-of-queue thread starved per sleep. Latent forever and
harmless while sleeps were rare; the M72b netserv ticker (sleeps
every tick for lwIP timers) churned it into a deterministic SMP1
livelock: fuzz→fs→netserv→virtio_net all parked behind a driver
that was popped-and-requeued every tick without running. SMP4
masked it (sibling harts pick the victim). Fix: Block_Current no
longer yields; the trap-level caller schedules once. Plus a real
forensics catch kept: Mark_Exited now unlinks a dying thread from
any endpoint caller queue (stale link corrupted queues and could
cross-deliver IPC to the slot's next occupant).

Wedge forensics, for the next time: `info virtio-queue-status
/machine/peripheral-anon/device[6]/virtio-backend <n>` names queue
PAs; HMP `gdbserver tcp::1235` starts a stub on a running VM;
runtime-spawned thread ids start at 1024 (watch modular-aliasing
in id-keyed debug counters); READ KERNEL STATE ONLY UNDER HMP
`stop` — a running-VM `xp` samples mid-transaction queue/array
states and produced hours of self-contradictory "evidence";
never run a second QEMU against the same disk.img (a timed-out
background `make test` respawned one and silently shared it).
The instr8 "PT page == RX ring frame" observation never recurred
in later runs and remains unexplained — keep on the watchlist.
Gates: SMP1 1413P/0F, SMP4 1414P/0F, zero-warning build.

**M72c landed (2026-08-28).** TCP end to end on the raw API.
New ops Op_Listen=26/Op_Accept=27 (non-blocking; the accept
callback parks the child pcb in a free table slot unclaimed and
ringless; Op_Accept transfers a fresh ring pair + ntfn on the
LISTENER's cap like Op_Socket and replies the child id, the client
mints its badge — `Accept_Connection`, `accept` being reserved).
Connect is deferred (Reply_Stash + 5 s deadline, sticky errors
4 refused / 5 timeout / 6 reset); Conn_State goes Connecting
BEFORE tcp_connect because hairpin callbacks fire synchronously.
EOF = zero-length ring slot, flags bit 0; Recv_From reports it as
Status_Ok/Count=0. Backpressure rides lwIP's refused-data: the rx
callback accepts a chain whole-or-nothing (TCP_WND 3984 == ring
capacity 4×996, load-bearing) and returns ERR_MEM otherwise, lwIP
parks it in refused_data and retries on the fast timer; CLOSED
(p==NULL → our eof cb) is delivered only after refused data
drains, so the EOF marker lands behind every byte. Tx backpressure
ERR_MEM → sent-cb + 50 ms tick retry. Tests/Tcp_Test (manifest
13): Net:address, hairpin listen/connect/accept, echo both ways,
8 KiB pattern (i*7+3 mod 256) interleaved send/recv, refused
connect, orderly close EOF, then slirp echo to the host's
tools/tcp_echo.py (make test starts it, 127.0.0.1:10007); fuzz
`type Net:tcp` netstat listing. Bug crop, all lwIP contracts now
commented in the port:
- tcp_in.c keeps parse state in file-statics, so a reentrant
  tcp_input (SYN hairpinned from inside tcp_connect) corrupts the
  in-flight handshake — the hairpin now QUEUES packets and drains
  them from top-level contexts only (the Op_Kick branch preserves
  m71c's send-then-receive ping semantics), same reason lwIP's
  loopif queues.
- tcp_process_refused_data dereferences refused_data->flags with
  no null guard (unless LWIP_WND_SCALE): aknet_tcp_kick must
  null-check first (stval=0x15 fault; pbuf.flags sits at 0x15).
- lwIP's input path MUTATES the pbuf it is handed
  (pbuf_remove_header): the hairpin must queue a COPY, never a
  pbuf_ref — a shared pbuf let tcp_input rewrite a segment still
  parked in the sender's unacked queue, which underflowed
  TCP_TCPLEN into an unpurgeable unacked entry and a nagle
  deadlock (child never sent).
- RTS Recv_From wrapped the modular copy loop for zero-length
  slots (0-1 = U64'Last → CONSTRAINT_ERROR in the first-ever
  empty slot, the EOF marker itself; process died in the LCH).
- tcp_recv/sent/err/poll all LWIP_ASSERT on LISTEN pcbs and the
  default LWIP_PLATFORM_ASSERT aborts: aknet_tcp_close skips the
  callback clearing for listeners (netserv died on listener close
  and took every later network test with it).
Gates: SMP1 1453P/0F ×8, SMP4 1453P/0F ×3, zero-warning build.

**SMP1 suite-time regression root-caused (2026-08-28): 9m36 →
4m16, now level with SMP4's ~4 min.** Two stacked costs, both in
the UP wakeup path, neither in M72c proper (15e0f45 timed the same
9m47 as e8fc564):
- IRQ-wake latency behind the hog. Drivers block in Ntfn_Wait; the
  external-IRQ path woke them boosted at the queue head but
  RETURNED to the interrupted thread — on UP, Notify_Work's IPI
  no-ops with one hart, so the waiter sat behind Tests/Spin for
  the rest of the 50 ms quantum on every device round trip (the
  boost only took effect at the next tick). Fix: new
  Kernel.Scheduler.Should_Boost_Preempt (queued boosted thread at
  priority >= an unboosted running thread) checked at
  external-interrupt exit on UP only, Handle_Preemption if set.
  SMP4 keeps tick/IPI semantics. Worth ~90 s alone.
- Spin's fair 50/50 share. The 3cf6791 "hog only fills idle" era
  predates the M70 scripting suite; CPU-bound spawn/script phases
  now dominate, and fair sharing with the hog doubles them. Fix:
  Spin demotes itself to priority -1 when CPU_Count = 1 — every
  woken thread strictly outranks it (priority preemption already
  fires at syscall tail and now IRQ exit), so it fills true idle
  only; the canary is intact (still spins forever, still hangs
  the boot if timer preemption breaks). SMP keeps priority 0.
  Worth ~4 min.
Measured: SMP1 9m36s pre-fix, 8m10s kernel-only, 4m16s both;
SMP4 4m16s, 0 FAIL everywhere.

**M73 landed (2026-08-29).** GNAT.Sockets works end to end,
including from a secondary Jorvik task.
- Vendored 17 libgnat socket units into `gnat_user/`; g-socthi
  adapted, g-stseme.adb rewritten onto newlib `strerror`.
- `akernel_gsocket.c` ports gsocket.c's `__gnat_*` helpers onto
  `Akernel_User.Sockets` IPC. Notable port semantics: BSD auto-bind
  on connect/send for unbound sockets (accepted sockets inherit the
  listener's local address); `gethostbyaddr` resolves numerically
  (dotted name via inet_ntop) because GNAT maps
  `Get_Host_By_Name(dotted)` onto it; the C DNS helper binds an
  ephemeral port first (netserv requires Bound for UDP send).
- **Clock-domain trap:** syscall 34 (`read_clock`) is the WALL clock
  (RTC s/ns); sleep deadlines live in the 10 MHz `time` CSR domain.
  The port reads ticks via `akernel_rdtime` (U-mode `csrr time`).
  Mixing them silently produces ~50 s sleeps / immediate wakeups.
- **Per-thread IPC buffer:** secondary threads get their own IPC page
  (s-osinte `Next_IPC_VA`); the kernel reads the message from the
  *calling* thread's page, but `Akernel_User.Syscalls.Message` was
  fixed at the initial thread's VA — task IPC sent an empty page.
  Fix: new syscall 43 `Sys_Thread_IPC_VA`; `Syscalls.Message` is now
  an access-returning function (implicit dereference keeps every
  `Message.Label/...` call site) with a 0-fallback for the initial
  thread.
- Socket pools bumped: netserv Max_Socks 8→16 with VA stride
  1 MiB→64 KiB (fits before Buf_Win), RTS Max_Socks 4→8.
- New `Tests/Gsock_Test` (manifest program 14, `console fs net`):
  address read, numeric gethostbyname/getaddrinfo/gethostbyaddr, UDP
  round trip + auto-bind, selector expire/readable/abort, TCP
  listen/connect/accept/echo/EOF, and a deterministic DNS hairpin —
  a Jorvik task answers an A-record query for "test.akernel" through
  the netserv loopback path.
- `s-oscons.ads` gained the full newlib errno block.
Gates: SMP1 1471P/0F, SMP4 1471P/0F, zero-warning build.

**M74 landed (2026-08-30).** Watchlist flakes: death-while-blocked
teardown, SMP kernel-stack use-after-free, UART THR overrun.
- Teardown audit: a dying thread now detaches from EVERY kernel
  object holding a raw TCB pointer, via one `Teardown_Thread`
  helper called from Mark_Exited's kill loop and Thread_Exit before
  the state change (the state-gated scans need the pre-death
  state): endpoint caller-queue unlink (existing), the missing
  `Cancel_Receive` (Waiting_Receiver slots — the recv-side brick:
  after TCB-slot reuse, Receive returned Invalid_Task forever),
  notification bindings/waiters (new
  `Kernel.Notifications.Cleanup_Thread`; `Clear_Waiter` previously
  had no call sites), IRQ line waiters (new
  `Kernel.Interrupts.Cleanup_Thread`, gated on Blocked_IRQ),
  Thread_Wait lists (existing).
- SMP: Mark_Exited freed sibling kernel stacks immediately while a
  sibling thread could still be executing in user mode on another
  hart (user mode runs lock-free) — its next trap wrote a full
  register frame into the reallocated frame (the m72b "endpoint
  queue tail = non-thread heap address" forensics). Stacks of
  threads that are some CPU's current now go onto THAT CPU's
  deferred list (new `Kernel.Scheduler.Current_CPU_Of`); deferred
  entries carry a per-hart trap epoch (`Note_Trap_Entry` bumps at
  every trap entry, before the drain) and are freed only two epochs
  after recording, because the victim's own first trap entry — and
  its drain — still runs on the doomed stack.
- Console line loss: both UART writers (kernel `Board.UART` and
  `Drivers/Serial`) wrote THR with zero flow control and FIFOs
  disabled; a QEMU chardev hiccup (or the other writer racing on
  SMP4 — the two writers share the device with no common lock) made
  the next write overwrite the pending byte, collapsing a whole
  line burst — the "bytes lost, not garbled" signature. Both
  writers now poll LSR THRE before every write and enable the 16550
  FIFOs (FCR=0x07). The IPC path itself was audited first: the
  queued-send pool blocks (never drops) on exhaustion, and no
  kernel-side message-drop path exists.
- Deferred (still watchlisted): reply-cap TCB-address ABA (no
  generation tags on reply caps / Waiting_Receiver),
  `Enqueue_Caller`'s blind Queue_Tail trust, `Process_Slot_Of`
  slot-0 fallback for out-of-table processes, `Exit_Current` not
  calling Remove_Sleeper.
- Gates: clean rebuild zero warnings; SMP1 1475P/0F x5, SMP4
  1472P/0F x4, no stall, no lost console lines. Note for future
  greps: PASS-count variance between runs is now COSMETIC — with
  byte loss gone, a writer preempted mid-burst can merge two
  verdicts into one physical line ("PASS tcp server seePASS tcp
  accept..."); every verdict's bytes are present (verified by
  fragment search), the line count just drops. If exact counts
  ever matter, count verdicts with a fragment-tolerant parser.

**M77 landed (2026-08-30).** Net-stack polish; the last watchlist
items closed:
- `Virtio.PCI` gains `Device_Features_Hi` (feature word 1,
  read-only diagnostic; negotiation stays word-0 only).
- virtio_net reports the negotiated datapath at boot after the
  FEATURES_OK check: "legacy datapath, virtio_net_hdr 10 bytes",
  noting when VIRTIO_F_VERSION_1 was offered but not negotiated.
  QEMU does offer it; we stay legacy by design. A modern-only
  device would reject FEATURES_OK and the driver exits, so the
  10-byte Hdr_Len assumption is now loud instead of implicit.
- Verified already landed and pruned from the watchlist: the
  driver RX ring drops new frames with a counter rendered as
  "dropped N" in Net:status. The ARP/socket/devmgr sizing and
  fixed-VA-window notes duplicated Working rules (current headroom
  fine: Max_Socks 16 vs 10+10 lwIP PCBs, devmgr 6/8 lines used).
- Gates: zero-warning serial build; SMP1 1473/1472P 0F x2,
  SMP4 1471/1472P 0F x2.

**M76 landed (2026-08-30).** The remaining M74 deferred kernel
hardening items, all closed:
- `Enqueue_Caller` no longer trusts a stored `Queue_Tail` blindly:
  the tail is used only while it still points at a thread queued
  on THIS endpoint with no successor; otherwise it is rebuilt by a
  bounded walk from `Queue_Head` (bound = thread-table size, so a
  corrupt cycle cannot hang the kernel), and an unusable head
  chain is dropped rather than followed. Closes the wild
  `Queue_Next` write.
- `Process_Slot_Of` is now a procedure with a `Found` out-param
  instead of silently aliasing slot 0 for null/out-of-table
  pointers; `Mark_Exited` guards its thread-count reset, and
  `Thread_Create`/`Thread_Exit` fail with `No_Slot` /
  `Invalid_Program`. A slot-0 alias in `Thread_Exit` would have
  decremented process 0's `Process_Thread_Count` and could trigger
  a false last-thread teardown.
- `Exit_Current` removes the dying thread from the sleep queue
  (`Remove_Thread` already did this for killed siblings); a stale
  entry would have been popped by the tick handler through a
  recycled TCB.
- Gates: zero-warning serial build; SMP1 1473/1472P 0F x2,
  SMP4 1472/1471P 0F x2.

**M75 landed (2026-08-30).** Caps travel in IPC replies; reply-cap
ABA closed; the libman manager path works for the first time.
- Kernel: `Kernel.IPC.Reply` now `Transfer_Message`s into the
  caller's buffer (was: caps zeroed, the m71c revert); the reply
  cap is still consumed with `Forget_Cap`, and a transfer failure
  wakes the caller with `Result_Transfer_Failed` (2) instead of
  dropping silently. `Transfer_Message` rejects `Reply_Object`
  caps (a rollback `Close_Cap` would wrongly fire
  `Fail_Reply_Target`). No trap-layer change.
- Reply-cap TCB-address ABA closed with generation tags:
  per-thread-slot `Thread_Slot_Generation` (outside the TCB, same
  pattern as process `Slot_Generation`, wrap 2**23) stamped into
  the reply cap's badge by `Mint_Reply_Cap`; `Reply` and
  `Fail_Reply_Target` (now takes the badge) refuse stale caps, so
  a cap left dangling by a dead caller can never cross-deliver to
  the slot's new owner.
- Userspace audit (the m71c blocker): every reply site now clears
  `Message.Caps` unless it deliberately sends one — helper-level
  in bureau `Win_Reply`, fileserver `Reply2` + the deferred pipe
  replies (a cross-REQUEST cap leak: reply on a stored handle
  while Message holds a later request's caps), virtio_gpu
  `Display_Reply`; per-site in virtio_blk (Op_Read/Write replied
  with the client's LIVE Buf_Cap in Caps(0)), virtio_net (Op_Tx
  Buf_Cap, Op_Set_Rx ring caps), virtio_input (would have bounced
  Bureau's endpoint cap to devmgr), virtio_rng.
- libman: mints the client service cap with Right_Transfer (the
  reply transfer requires it) and Cap_Deletes the mint after the
  reply. Enabling the path exposed three dormant bugs: init's
  `libman` grant was Send-only so `Libman_Available`'s cap_mint
  probe always failed (universal silent fallback to private
  spawns); libman received on handle 6 but grant handles are
  positional — `libman_server` is the 3rd manifest token, so its
  first `IPC_Recv` failed at boot and the endpoint died; and
  Close_Library told the manager before dropping its mint while
  `Expunge` polls the reap before replying — a three-party
  deadlock (the library exits only when its endpoint's last Send
  cap is gone). Fixed: Send+Transfer grant, Service_EP=3,
  delete-mint-first in Close_Library, and a libserv management
  label (`Shutdown_Label`=0, intercepted before Dispatch) that
  makes the library exit on expunge — the refcount-0
  Endpoint_Gone exit could never fire (the server's own cap keeps
  the count above zero; the "last client closed" comment was
  aspirational since M58).
- Regression hook: `Akernel_User.Libs.Opened_Via_Libman` + fuzz
  verdict `libs open delivered via libman reply cap` proves the
  reply cap delivers and the shared cache (not a private spawn)
  serves the open.
- Gates: zero-warning serial build (NOTE: parallel `make -jN`
  corrupts libakernel_user.a — every crate's gprbuild builds the
  same library project concurrently and gprlib crashes; build
  serially); SMP1 1475-1476P/0F x2, SMP4 1474-1475P/0F x2.

**M78a landed (2026-08-31).** DNS is netserv-resident: lwIP's
dns.c (compiled in — one-line `lwip.gpr`/`lwipopts.h` changes;
`MEMP_NUM_UDP_PCB` 10→11, `LWIP_RAND` defined as newlib `rand()`
— it has no opt.h default) backs a new `Op_Resolve=28` on the raw
service cap: the hostname rides cap0 as a one-page memobj (word0 =
length 1..255, mapped read-only at the Net: buffer window, deleted
per op), a 4-slot pending table (lwIP DNS_TABLE_SIZE) stashes the
reply cap, and the glue's found callback records the outcome for
the service loop's deferred-reply pass (the Op_Connect pattern;
lwIP's own timer bounds the wait off the 50 ms tick — no new
plumbing). Cache hits answer inline (`ERR_OK` fills the address
WITHOUT calling back — verified in dns_gethostbyname_addrtype).
`Net:dns` writes (and the boot config) now `dns_setserver` for
real; lwIP's OpenDNS default is unreachable behind slirp.
Client side: `Akernel_User.Sockets.Resolve` (+ `aknet_sock_resolve`
C export); akernel_gsocket.c's m73 hand-rolled resolver (fixed
txid 0x4D37, one ephemeral UDP socket per lookup, client-side
answer parser, ~160 lines) deleted — `__gnat_gethostbyname`/
`__gnat_getaddrinfo` keep their numeric short-circuits; a failed
lookup maps to HOST_NOT_FOUND (lwIP does not distinguish NXDOMAIN
from timeout), resolver-full to TRY_AGAIN.
- **Root-caused regression this milestone**: the m71c hairpin
  closed-port precheck in `Drain_Sock_Tx` scans only netserv's
  OWN socket table, so a hairpinned reply to a lwIP-internal pcb
  (the resolver's, dns.c-allocated with a random source port) drew
  sticky error 1 on the sender and was dropped — the resolver
  timed out after 4 retries while the test responder answered into
  the void. Fix: `aknet_udp_port_open` walks lwIP's `udp_pcbs`
  for a pcb owning the port WITHOUT our client recv callback
  (client-visible ports keep the exact m71c scan semantics,
  including the connected-socket peer filter). DHCP's pcb (m78b)
  rides the same path.
- gsock_test's deterministic DNS hairpin passes byte-unchanged
  (responder untouched — it echoes the query header, so lwIP's
  random txid and dns_recv's RFC 5452 source check are both
  satisfied) — it now exercises query AND reply through the
  hairpin queue from netserv's own pcb.
- Gates: full `make clean` + zero-warning serial build; SMP1
  1473P/0F, SMP4 1473P/0F.

**M78b landed (2026-08-31).** DHCP client, opt-in: lwIP's dhcp.c
(compiled in like m78a's dns.c — `MEMP_NUM_UDP_PCB` 11→12;
`LWIP_DHCP_DOES_ACD_CHECK 0` — 2.2 defaults it to LWIP_DHCP and
it would drag in acd.c) behind a readable+writable `Net:dhcp`
file (whole-value commands `start`/`stop`/`renew`; reads render
the DHCP_STATE_* name plus the lease while bound) and an
`ENV:Net.DHCP` boot flag (1/on/true/yes). Static config stays the
DEFAULT and address/gateway writes are rejected (status 2) while
the client runs; start stashes the pre-start values and stop
restores them in the same netserv activation (dhcp.c's
release-and-stop zeroes the netif address — the zero window never
escapes netserv's single thread). The 50 ms tick polls
dhcp_supplied_address and mirrors the netif's leased address/
gateway into My_IP/Gateway_IP on an edge (the ping/hairpin
checks and Net:status/Net:address renders read those mirrors;
lwIP sets the netif itself in dhcp_bind). DHCP's pcb (port 68)
is lwIP-internal, so the m78a aknet_udp_port_open hairpin
exception already covers it; slirp always answers DHCP with
10.0.2.15/10.0.2.2 for this MAC. Two latent fixes this
milestone: aknet_setup now copies the MAC BEFORE netif_add
(dhcp_create_msg reads netif->hwaddr), and dhcp_renew is gated
on bound in the glue (lwIP enters RENEWING unconditionally).
- **Test**: Tests/Dhcp_Test (manifest program 15, "console fs
  net") — static default → start → bound via slirp → lease
  mirrors (10.0.2.15 / 10.0.2.2) → static write rejected while
  on → ping gateway on the lease → renew → stop → off → static
  restored → ping again. Its pings retry through status 2:
  Op_Ping allows ONE outstanding request and net_test's ~2 s
  unreachable-target ARP timeout can hold it (found on the first
  run — two FAILs, both the ping collision).
- Fuzz: `type Net:dhcp` after `type Net:tcp`.
- Gates: full `make clean` + zero-warning serial build; SMP1
  1500P/0F, SMP4 1500P/0F + clean-build rerun 1498P/0F.

- **M73 — GNAT.Sockets (done).** Vendor g-socket/g-socthi/g-soccon/g-stsifd
  from gcc-15.3.1 libgnat into gnat_user/, port gsocket.c's __gnat_*
  helpers as akernel_gsocket.c over Akernel_User.Sockets, extend
  hand-written s-oscons.ads with AF_INET/SOCK_*/SOL_*/MSG_* (AKERNEL
  values, no host ABI). getaddrinfo numeric-only + slirp DNS helper.

Deferred: socket servers (finger etc.), external ICMP (slirp does
not forward it — tests target the gateway by design).

Net watchlist: empty. The virtio_net_hdr mode is asserted loud at
boot (M77); the RX ring already drops new frames with a counter
rendered as "dropped N" in Net:status; the ARP/socket/devmgr
sizing and fixed-VA-window items duplicate Working rules below.
All M74 deferred kernel items were fixed across M75 (IPC_Reply
caps, reply-cap ABA) and M76 (Enqueue_Caller tail,
Process_Slot_Of slot 0, Exit_Current sleeper); the SMP4
console-loss and whole-system stall flakes were fixed in M74.
