# Akernel resume

Live state and open work. Landed milestone narratives live in
`docs/HISTORY.md`; from M74 on, the `git log` commit bodies carry
per-milestone detail too.

## Project rules (permanent — read first)

Project rules are stored in the AGENTS.md file in the root of the
repository.

## Planned: (none — M93 shipped)

## Recently shipped

- **M94** (`3accf5a`): spawn-ABI unification + Drawer button fix.
  Startup programs (devmgr Spawn_Program) now receive the full
  uniform command ABI — handles 1..6 = console, fs, bureau, args,
  elevation, netserv — the same layout shell commands get, so any
  GUI app can Scripting.Spawn_Cmd its children (double-clicking an
  ELF or a file into Edit failed before: the old Startup ABI left
  netserv at handle 5 with no 6, and an invalid grant source fails
  the whole spawn). Terminal/Desktop/Fileman constants moved
  elevation 4→5 and netserv 5→6; Desktop's Drawer spawn and
  Fileman's Spawn_Edit grant the full 6-handle layout (M92's
  4-handle workaround retired). Drawer Top_Row: path label weight
  20 vs the Parent button weight 1 so the button no longer
  balloons. Drawer open carries three 'drawer: t=' rdtime phase
  prints (deficons/scan/open) to chase the still-open slow-open
  report — BeFS serves reads one 1 KiB block per block-endpoint
  IPC, latency-bound for big-ELF staging and scans. Gates: make
  test 1874 PASS / 0 FAIL SMP4 and SMP1 (real elevated shutdown +
  clean qemu exit) and test-replay ok.

- **M93** (`e2a8205`): BeFS becomes Sys:. disk.img is now 512 MiB

  split 50/50 — partition 1 (BD0) a 256 MiB BeFS "Sys" volume
  (mkbefs --stage host tree + attrs manifest incl. README fixture
  attrs), partition 2 (BD1) 256 MiB FAT32 "Data" with the FAT
  fixtures; offsets computed from sgdisk, run-recipe ENV reads via
  befs_get. Built on M93p1 (multi-AG allocator, `028b4c7`) and
  M93p2 (staging/attrs + befs_get, `833b30f`). The swap surfaced
  real bugs, all fixed here: the Bfs server's 16 KiB read window
  silently truncated every 32 KiB client read (staged ELFs ran half
  garbage — the trap/wedge that started this); fuzz's BD0/BD1
  re-target stragglers (lowercase bd0:, Tests/Img + System/C: on
  the wrong volume, case-exact BeFS names); command lookup relied
  on FAT case-insensitivity (Resolve_Command now does a CI dir
  scan; BeFS is case-sensitive); engine Tree_Next yielded garbage
  from emptied leaves (delete-heavy scans stalled) plus loop guards
  on all unbounded btree walks and a Get_Block bounds check; and
  the host post-test index greps now bound 1..64 (Sys: legitimately
  carries ~27 indexed ENV config files at rest). befs_mkdirty
  rewritten on befs_dump's AG/depth-aware walker for test-replay.
  Gates: 1873 PASS / 0 FAIL SMP4 and SMP1; test-replay ok. Payoff
  per the M93 plan: per-app ICON attrs + drawer geometry persistence
  work with zero icon-code changes (drawer/dir QMP smoke still to
  re-run by hand).

- **M92** (`6239675`): Desktop backdrop launcher (userspace/desktop,
  DEST=system; Startup line right after Bureau). One
  full-screen Flag_Backdrop+Flag_Borderless window at
  (0, Screen_Bar_H+1) size W x (H-Bar_H-1) — geometry queried
  via the Set_Screen_Mode pure-query form — holding a bare
  Trinket.Iconview of mounted volumes: Op_List_Volumes scan
  filtered to fs volumes whose Op_Volume_Info answers Ok
  (capacity is the disk discriminator — Proc:/Net: answer
  Bad_Args), all with the 32x32 VOLUME.XPM deficon.
  Double-click spawns Sys:System/Drawer <label:>; "Desktop"
  menu has Refresh (re-poll; no mount fan-out exists). Kind-6
  re-fills the screen across M90 switches. Two real bugs found
  by QMP: (1) Bureau's Forward_Pointer and the v4 capture test
  hardcoded the chrome content origin (X+Frame,
  Y+Frame+Title_H) — for a borderless window the pane IS the
  frame, so the desktop's top 24 px band dropped every click
  and the rest arrived offset; both now use the
  borderless-aware Pane_X/Pane_Y. (2) The Startup-spawn ABI is
  NOT the command ABI (4=elevation, 5=netserv, no handle 6),
  so Scripting.Exec.Spawn_Cmd's Net_EP=6 grant fails the whole
  spawn from a Startup context — Desktop spawns Drawer with
  Fileman's local 4-handle GUI-tool pattern instead. QMP
  verified at both 1024x768 and 1280x800: volume icons render,
  dbl-click spawns Drawer on Sys:/Befs:, backdrop clicks focus
  but never raise (z-order stable), Refresh picks, kind-6
  re-fill + full interactivity after a live mode switch, depth
  gadget and ScreenMode Okay/Cancel exit paths clean. Wild
  goose chase worth recording: an apparent "process wedge on
  Cancel" + "dead depth gadget" was entirely stale QMP pointer
  scaling — qmp.py cached W/H=1280x800 across a 1024x768 boot,
  so clicks landed at ~80% coords; the helper now re-syncs
  from a screendump on every invocation. Gates: 1851/0 SMP4,
  1847/0 SMP1. Next: M93 BeFS-as-Sys: swap.

- **M91** (`ac7fab9`): Icon view + Drawer app (desktop icons
  phase 1). Window protocol: Op_Surface_Create w2 gains
  Flag_Backdrop=2 (focus on click, NEVER raises; z-bottom;
  send-to-back lands above it) and Flag_Borderless=4 (no chrome:
  FW=PW, no title band/gadgets/drag), w3/w4 = explicit frame
  X/Y (0,0 = cascade; honored only with the new flags so
  pre-M91 clients are untouched); input event kind 6
  (Input_Event_Screen_Mode) goes to backdrop windows on an M90
  switch — Bureau owns the target (0, Bar_H+1) through the zoom
  pending-geometry machinery with Pend_Screen_Mode suppressing
  the Zoomed toggle, Trinket.Window acks it like kind 5 and
  gained an On_Resize callback (post-layout). File protocol:
  Op_List_Volumes=26 (stateless index scan -> Vol_Kind_* +
  label/device name) + Files.Volume_List. Trinket.Iconview:
  96x64 cells (32x32 icon + centered label), column count
  derived from width at draw/hit-test time so RESIZE REFLOWS
  for free, widget-timed double-click (Listview's M84c
  pattern), arrow-key nav, New_Scrolled_Icons composite
  (pixel-range bar, cell-row step). Nine fresh 32x32 XPMs in
  assets/icons32/ (volume/drawer/file/tool deficons + fileman/
  terminal/edit/font/screenmode app icons) ->
  Sys:System/Icons32/; the 16x16 set stays for Fileman rows.
  System/Drawer (userspace/drawer, DEST=system): arg = drawer
  path (default Sys:); drawers-first Ada.Directories scan with
  per-entry fault isolation; ICON attr (CSTR XPM path) wins,
  else 32x32 deficons with ELF-magic tool sniffing; the FAT32
  driver answers Bad_Args for attr ops so No_Attrs latches for
  the rest of the drawer (BeFS attr-less Not_Found must NOT
  latch); double-click navigates same-window (Parent button +
  path label; Parent_Of cuts the last component —
  Normalize_Path ignores TRAILING empties by design, "c/" is c
  not its parent), spawns ELFs via Scripting.Exec.Spawn_Cmd,
  opens other files in System/Edit with the path; Drawer menu
  Refresh/Parent. Geometry persistence WITHOUT any Snapshot
  concept: On_Resize writes DRAWER:GEOM "WxH" on the drawer
  (journaled on BeFS, silent Bad_Args no-op on FAT32), open
  reads it back. The initial scan runs BEFORE Window.Open
  (~1.6 s of FAT path resolutions — every VFS op costs ~100 ms
  there; BeFS btrees should crush it at M93) so the window
  appears populated. QMP-verified: populated open, Icons32
  navigate, Parent back (found the trailing-slash bug), Edit
  tool spawn (no-arg) and file->Edit (path arg), zoom reflow
  to 12 columns with the attr write no-op clean, Refresh menu
  pick. Fuzz: Op_List_Volumes enumeration PASSes.
  Gates: 1847/0 SMP4, 1849/0 SMP1 (both fuzz
  volume-list PASSes present). Next: M92 Desktop launcher.

- **M90** (`d5293d7`): ScreenMode prefs + runtime mode
  switch. Display protocol gains Op_Set_Mode (16) +
  Status_Bad_Mode (5): the driver validates against the static
  640x480..1920x1080 clamp (BEFORE Natural conversion — a
  garbage-huge word would raise), deletes the stored compositor
  chunk caps (old geometry's), UNREFs and re-creates the scanout
  resource, re-attaches its own FB and clears; the compositor
  re-pushes and re-commits like boot. Backing/scanout plumbing
  factored into Attach_Backing/Detach_Backing/Set_Scanout
  helpers shared by boot, Commit_Buffer and Set_Mode
  (Backing_Attached tracks whether DETACH is needed).
  BURN + fix: FB objects must be FULL 64-page allocations — a
  partial tail object (boot 1280x800 = 15x64+40) strands
  capacity the M90 growth path cannot top up, so 1080p needed a
  33rd object past the 32-slot table and the switch came back
  Status_Device. Window protocol gains Op_Set_Screen_Mode (32,
  w0/w1 = 0 queries; reply always carries the mode in effect) +
  Status_Bad_Mode (6); Bureau's Apply_Mode folds cursor+menu,
  runs the driver call, tears down and rebuilds the compositing
  buffer (Teardown_Buffer/Build_Buffer, boot now uses the same
  helper; old frames return to the PMM on last-cap close),
  clamps window origins on-screen (saturating — a window bigger
  than the new screen pins to 0, its title bar can slide under
  the screen bar; cosmetic), full repaint. Prefs/ScreenMode
  (userspace/prefs/screenmode, second nested crate): static
  8-mode list, current mode queried+preselected on open, Okay =
  Op_Set_Screen_Mode + ENV:Screen.Width/Height, Cancel quits.
  Boot persistence: the Makefile run recipe mtypes those ENV
  files out of disk.img into QEMU xres/yres (QEMU_GPU_FLAGS
  still overrides) — which exposed that the disk recipe's
  rm -f $@ WIPED ::Prefs/Env on every rebuild (M89's ENV:Font
  survived exactly one boot); the recipe now carries ::Prefs/Env
  across rebuilds (mcopy out before, restore after). QMP-verified:
  1280x800 -> 640x480 (windows clamp, repaint clean) -> 1920x1080
  (growth path), reboot boots 1080p via "gpu flags:,xres=1920,
  yres=1080", back down to 1280x800, reboot follows again;
  fsck.fat clean. QMP lesson: scale pointer coords by the CURRENT
  console size — a stale 1280x800 scaling at 640x480 clicked the
  terminal under the picker and buried the picker's window behind
  it (clamped near-fullscreen), which reads exactly like a silent
  app exit. 1846/1847 PASS SMP4/SMP1, 0 FAIL.
  Next: per-app screen bar title, terminal UTF-8/codepage wiring
  (the M89 extended glyphs are loadable but unreachable from
  shell text), or a Trinket text editor.

- **M89** (`8eb284e`): Prefs folder + Font prefs editor.
  Sys:Fonts/ grew real choices: font2bdf.py --tall doubles rows
  for font8x8t.bdf (same family, PIXEL_SIZE 16; font8x8p keeps
  its own family — different metrics), and Terminus 12/14/16
  arrives via a sha256-pinned third_party tarball (SourceForge
  4.49.1, OFL; license ships as Sys:Fonts/OFL.TXT; BDFs shipped
  UNFILTERED — line-drawing glyphs stay). Trinket.Fonts:
  glyph coverage extends past ASCII to 16#25FF# via a sparse
  (codepoint, glyph) table (768 slots, ~1.7x the Terminus
  set — sizing argument in comment) with Draw_Glyph/Has_Glyph
  codepoint primitives; a loadable Handle API (Load/Unload/
  per-handle Draw_Text/Line_Height/Text_Width) plus a
  header-only Probe (FAMILY_NAME/PIXEL_SIZE) back the picker's
  live preview and family grouping; Init consults ENV:Font
  before the default path (saved choice applies to newly
  launched apps; the global latch stays). Two latent loader
  bugs fixed on the way: raw Files.Open needs the fs endpoint
  bound — Fonts now binds handle 2 lazily, never clobbering a
  custom binding (fonts from disk silently fell back since
  m56 in apps whose first fs touch was the font load), and
  Files.Read answers at most Buf_Bytes per call — the read now
  loops (the old 64 KiB "font cap" was that one-shot
  semantics). Prefs/Font (userspace/prefs/font, first nested
  crate; new-crate gains DEST=prefs, DISK_CRATES_PREFS list,
  ::Prefs mcopy loop with basename handling; nested gpr needs
  an explicit Runtime override — relative Runtime paths
  resolve against the extending project): the Amiga
  fontrequester — families listview left, sizes right, live
  preview panel (custom widget drawing two sample lines with a
  preview Handle), Okay/Cancel. Okay writes ENV:Font.
  Preselection happens AFTER Window.Open — a zero-height
  listview reports Visible_Rows = 1, so selecting before
  layout parked Top at row 1 and hid the first family.
  QMP-verified: scan finds 6 fonts, preselect font8x8p,
  Terminus -> 12/14/16 -> 16 repaints the preview in Terminus,
  Okay persists ENV:Font = Sys:Fonts/TER-U16N.BDF (confirmed
  on the image afterwards, fsck clean), a second tdemo
  instance renders wholly in Terminus 16. 1846/1847 PASS
  SMP4/SMP1, 0 FAIL.
  Next: M90 ScreenMode editor + runtime Op_Set_Mode.

- **M88** (this commit): in-window popup/overlay. New
  `Trinket.Widgets.Popup` menu-list widget (MUI popup-list
  lineage): raised Pane panel, one row per item, hover inverts
  the row (listview selection style), release-over fires
  Pick_Callback with the 1-based index; items cap at
  Max_Children/Max_Text (transient menu text, Group's
  justification). Not a layout citizen, not a focus-chain
  member — `Trinket.Window` owns it: Open_Popup sizes to
  Min_Size, clamps the anchor into the surface, installs as
  W.Overlay; while active the Run loop routes keys to the
  overlay only (Tab suppressed, Esc dismisses), pointer presses
  inside go to it, presses outside dismiss and are SWALLOWED
  (no focus change, no content dispatch), and a Popup pick
  closes after the app callback runs. Flush_Dirty collects the
  overlay's Dirty_List plus a pending-damage band (the rect the
  overlay vacated, stashed by Close_Popup, unioned into the
  first cluster if the list is full) and draws the overlay
  last in every band (z-order). One overlay at a time; opening
  replaces. tdemo showcase: a Popup button in Btn_Row opens a
  3-item Alpha/Beta/Gamma menu anchored above itself, picks
  reporting on the status line. QMP-verified: open -> hover
  Beta inverts -> click picks ("picked Beta" on status line),
  reopen -> click-outside dismisses, reopen -> Esc dismisses,
  vacated rects repaint clean (no ghosting).
  1848/1846 PASS SMP4/SMP1, 0 FAIL. Anchor fix `f55c0a0` on
  top: Open_Popup initialized both locals from X ("PX, PY :
  U64 := X"), so the popup opened at (X, X) — split the
  declarations.

- **Widgets split** (`8bc1563`): Trinket.Widgets had grown to
  573+2760 lines — split into per-widget child packages. Root
  keeps the framework only: Widget base, damage machinery, M87h
  focus chain, shared callback profiles (Click/Change), Group,
  plus a private part with the helpers gadget bodies share
  (Set_Text cell copy, Add_Rect, Toggle_* geometry, Min/Max,
  Glyph_Col; Max_Text/Text_Len/Text_Rec/Text_Array stay PUBLIC —
  a public child spec can't see the parent's private part, and
  gadget records embed them). New children: Image, Label, Input,
  Button, Gauge, Separator, Toggles (Checkbox+Radio — shared
  box/label helpers + Radio_Set), Scrollbar, Slider, Tabs,
  Cycle, Numeric. Behavior-neutral code motion with two
  adjustments: Group's scrollbar pinning became dispatching
  layout hooks Fixed_Main/Narrow_Cross on the base Widget
  (Scrollbar overrides) so Group never names the Scrollbar
  child; fileman's Set_Focused/Is_Focused call sites became
  prefixed dispatching calls (inherited-primitive overload
  resolution doesn't cross package boundaries). Apps gain one
  with + qualification per widget (tdemo 10, fileman 3, edit 2,
  Text_Edit/Listview/terminal_scroll requalify Scrollbar ops).
  1847/1847 PASS SMP4/SMP1, 0 FAIL; QMP smoke: tdemo tab-focus
  ring + checkbox toggle identical to pre-split.
  Next: M88 in-window overlay/popups.

- **M87h** (`5e021df`): Tab focus chain with app-overridable
  ranks. Base Widget gains Tab_Rank/
  Focused + Wants_Focus (default False), Set_Tab_Rank/
  Set_Focused/Is_Focused primitives, and the Cycle_Focus/
  Clear_Focus tree walks. Window.Run intercepts Tab (never
  delivered to widgets) -> Cycle_Focus: chain rebuilt fresh
  each press (depth-first add-order collect, stable sort by
  rank; rank 0 = add position, ranked beats the natural slot
  occupant so rank 1 really is "first", equal ranks keep add
  order) and clears+sets focus. Single-focus invariant:
  Clear_Focus before every pointer Press, the pressed gadget
  re-takes it — clicking a dead spot defocuses (subsumes the
  old app-side Input defocus; Input.Focused moved to base).
  Members: Input, Button, Checkbox, Radio, Cycle, Numeric,
  Slider, Tabs (disabled toggles/buttons skip; Text_Edit/
  Listview deliberately not in — their key paths predate
  focus). Focused gadgets draw a dotted Paint.Focus_Ring and
  answer keys: Enter/Space activates buttons/toggles/cycle,
  arrows step Numeric/Slider, Left/Right switch Tabs pages.
  Max_Focus_Chain 64 = transient per-Tab staging, justified in
  comment. tdemo ranks its Worker numeric 1. QMP-verified:
  tab order numeric -> Work -> Slider -> Bold (rank override
  visible), space toggles focused Bold + clicks focused Save,
  arrows step the focused numeric, 14th tab wraps to numeric,
  dead-spot click clears the ring. 1846/1846 PASS SMP4/SMP1,
  0 FAIL.
  Next: M88 in-window overlay/popups.

- **M87g** (`41e43d6`): Numeric gadget — Cycle's integer
  sibling. Sunken Pane field, value right-aligned against a
  separated 18px glyph column with independent up/down arrow
  mini-buttons (split at mid-height). Release-over steps by the
  public Step field (default 1), clamps to Min..Max, fires
  On_Change (Value : U64) only on real change; Set_Value clamps
  without firing. Down-steps pre-clamped (M87b wrap hazard).
  M86c battery: hover Face_Hi on the hovered arrow half, press
  sinks it + shifts the chevron. Min_Size = Text_Width
  (Max'Image) + padding + glyph column, LH+8 tall. tdemo: 0..100
  numeric in the Worker row, steps drive the Gauge alongside the
  slider. QMP-verified: 3x up = 3, 2x down = 1, gauge tracks,
  digits render. (QEMU gotcha, same as M87f: title-band clicks
  hit no child — the dbg round-trip of "dead widget" was again
  aiming 6px high into the Worker title band; the rect dump
  settled it.) 1848/1847 PASS SMP4/SMP1, 0 FAIL.
  Next: M87h Tab focus chain with app-overridable ranks; M88
  in-window overlay/popups later.

- **M87f** (`dfae8d5`): Cycle gadget — MUI lineage. Raised
  field showing the current entry + up/down chevron pair in a
  separated right glyph column; release-over rotates to the
  next entry (wraps) and fires On_Change; Set_Selected does the
  same programmatically. M86c battery: hover Face_Hi, press
  sinks + shifts text and glyph. Entries cap at Max_Children(12)
  x Max_Text(48) — Group's ceiling. Tab_Label_Rec generalized
  to Text_Rec/Text_Array shared with Tabs. tdemo: first/second/
  third cycle in the Choices row, rotations report "cycle N" on
  the status line. QMP-verified: press sunken, first -> second
  -> third -> wrap to first. (QEMU gotcha re-learned: a click
  into a TITLED group's 16px title band hits no child — aim at
  the widget body, not the row's visual center.) 1847/1847 PASS
  SMP4/SMP1, 0 FAIL.
  Next: M87g Numeric, h Tab focus chain with app-overridable
  ranks; M88 in-window overlay/popups later.

- **M87e restyle** (`1f07ebf`): tabs look like tabs, not
  buttons. User review of the first cut: inactive tabs drew as
  full Bevel2 button boxes (bottom border included) sitting ON
  the frame line. Now: 2px-chamfered (rounded) top corners, a
  3px gap between tabs, and no bottom edge of their own — the
  page frame's top line is the shared boundary, the active tab's
  Face fill runs 2px lower to merge. Press feedback is a label
  shift (no sunken box any more). QMP-verified: chamfers, gap,
  hover brighten, merge on switch both ways. 1845/1847 PASS
  SMP4/SMP1, 0 FAIL.

- **M87e** (`190e2d0`): Tabs widget — MUI register-group
  lineage. `Tabs` is a `Group` subtype: pages are the kids
  (Add_Tab appends label + page), but only the SELECTED page is
  laid out / drawn / dispatched; hidden pages hold a zero rect
  and `Dirty_List` walks the active page only (their stale dirty
  flags never union as zero-area bands). Strip/draw restyled in
  the follow-up commit above (rounded corners, gaps, shared
  bottom boundary).
  Set_Selected re-lays-out immediately, full-redraws, fires
  On_Change. Min_Size: strip LH+8 + tallest page + frame; width
  = max(whole strip, widest page). Caps: labels Max_Text(48),
  pages Max_Children(12) — Group's ceiling. tdemo: two-page
  strip between Font and the button row, switches report "tab N"
  on the Worker status line. QMP-verified both directions (page
  swap + status text + active-tab merge pixels). 1848/1847 PASS
  SMP4/SMP1, 0 FAIL.
  Next: M87f Cycle, g Numeric, h Tab focus chain with
  app-overridable ranks; M88 in-window overlay/popups later.

- **M87e-prep** (`0642014`): scrollbars are component parts,
  not app wiring. User feedback on M87c: the bars sat a group
  spacing away from the edit box and the h-bar spanned the full
  group width (past the v-bar). Fix is architectural: new
  scrolled composites — `Text_Edit.New_Scrolled_Editor (Editor
  : out ...)` and `Listview.New_Scrolled_List (LV : out ...,
  On_Change)` — each a `Widgets.Group` subtype whose Layout pins
  the bars FLUSH (v-bar right edge, h-bar exactly under the
  content, corner square left window-face) and whose Draw
  re-syncs bar metrics from the content first (free: Set_Range/
  Set_Pos no-op on unchanged metrics). Bar→content direction:
  Scrollbar.On_Change now carries the bar (`Bar_Callback =
  access procedure (Bar : Any_Widget; Pos : U64)`) and bars have
  a public `Ctx : Any_Widget` — one package-level `Bar_Moved`
  per content package serves every instance (bar Dir picks the
  axis; editor h-bar keeps Step=8px). Replaces M87c's
  Text_Edit.Set_On_Change hook (removed — the Draw-time sync
  covers it). edit app drops Scroll_Moved/HScroll_Moved/
  Sync_Scrollbar/Editor_Changed/Mid_Row entirely; fileman drops
  per-pane Scroll fields + Sync_Scrollbar, one
  New_Scrolled_List per pane; terminal (custom canvas, no
  widget tree) just updates its handler signature. Widgets.Arrow
  (16) moved to the spec so composites can size against it.
  QMP-verified: edit bars flush + h-bar exactly text width,
  v/h arrows step correctly after typed growth (12 RETs grew
  v-range live), fileman panes flush with selection intact.
  1847/1847 PASS SMP4/SMP1, 0 FAIL.

- **M87c+M87d** (`e19abd7`): horizontal Scrollbar + Separator,
  and Text_Edit h-scroll. Scrollbar takes `Dir : Direction` —
  Horizontal mirrors everything across the diagonal (arrow cluster
  at the RIGHT, < > chevrons, stripes by row, PX-driven pointer
  path, Min_Size 3*Arrow x Arrow); Group.Layout pins a scrollbar
  to Arrow in its cross axis in BOTH group directions now, so a
  horizontal bar drops into a vertical group without a weight
  share. New `Step` field + Set_Step: arrow-click delta in Pos
  units (default 1; pixel bars want ~a char cell, edit uses 8).
  Set_Range no-ops on unchanged metrics (per-keystroke re-syncs
  stay free). Text_Edit: HOff pixel scroll against the
  proportional font — HSkip drops whole chars + sub-char Spill so
  text slides smoothly, Draw/Locate/Ensure_Cursor_Visible all
  HOff-aware; new Set_On_Change hook fires after handled keys and
  Clear/Append_Line so apps re-sync bars on typed growth (the
  once-after-Open sync left the bar dead when an empty document
  grew past the view — found via QMP). Separator (M87d): etched
  groove (Bevel_Lo + Bevel_Hi under), Min_Size 0x2, tdemo shows
  one between Choices and Font. edit app wires HScroller under
  the text area. QMP-verified: auto-scroll while typing past the
  edge, Home snaps to 0, arrow steps 8px/click both ways, knob
  drag scrolls live; separator groove pixel-checked
  (Bevel_Lo/Bevel_Hi pair). 1848/1846 PASS SMP4/SMP1, 0 FAIL.
  Next: M87e Tabs, f Cycle, g Numeric, h Tab focus chain with
  app-overridable ranks; M88 in-window overlay/popups later.

- **M87b** (this commit): Slider widget. Horizontal continuous
  value gadget, Scrollbar's sibling: sunken track channel,
  raised 12px knob with grip lines, track-click pages 10% of
  range, knob drag over the same v4 pointer capture; M86c state
  battery (hover face, sunken+shifted grips while dragging);
  On_Change on user moves only. Min_Size 64x14. tdemo wires it
  to the Gauge (slider % = gauge fill). Latent Scrollbar bug
  fixed in passing: down-steps (up arrow / track-above) computed
  Pos - By in U64, WRAPPED past Min, and Clamp_Pos read the wrap
  as past-Max — the up arrow at the top jumped to the bottom;
  both widgets now pre-clamp (Step_Down helper). QMP-verified:
  knob drag 20% -> 94% with the gauge label tracking live, track
  click pages +10. 1848/1847 PASS SMP4/SMP1, 0 FAIL.

- **M87a** (this commit): Gauge widget — the M87 widget arc's
  first slice (planned: b Slider, c horizontal Scrollbar +
  d Separator, e Tabs, f Cycle, g Numeric, h Tab focus chain
  with app-overridable ranks; M88 overlay/popups later,
  in-window). Workbench fuelgauge lineage: sunken frame,
  Sel_Blue fill, centered "NN%" label drawn light-on-fill /
  dark-on-empty via two Set_Clip passes; Set_Fraction clamps
  and dirties only on a rendered change. Min_Size from birth
  (M86g): "100%" + 16 wide, LH + 8 tall. Pure display, no
  input handling. tdemo "Worker" showcase: Work click -> 50%,
  worker completion -> 100% (0% on failure). QMP-verified:
  idle "0%" dark-on-pane, post-Work "100%" light-on-fill.
  1848/1844 PASS SMP4/SMP1, 0 FAIL.

- **M86g** (this commit): content-size negotiation. The Widget
  protocol gains `Min_Size (W; MW, MH : out U64)` (default 0x0),
  overridden per widget from the CURRENT font metrics — Label/
  Button/Checkbox/Radio wrap `Text_Width` + bevel/padding, Input
  and inset Labels floor at `Line_Height + 8`, Scrollbar pins
  Arrow x 3*Arrow, Image its bitmap, Listview two rows, Text_Edit
  two lines; Group recurses (layout direction sums, cross takes
  the max, plus the title band). Group.Layout is now two-pass:
  every child gets its min in the layout direction FIRST, then
  only the remainder splits by weight (cumulative fractions, as
  before) — weights now express who gets the slack, never who
  gives up content; minimums past the inner extent overflow and
  the canvas clip takes it (a huge user font degrades to
  clipping, never to a negative size). Window.Open grows the
  requested surface to the root's Min_Size, so app pixel sizes
  are preferences, not load-bearing budgets — this reverts the
  M86f-follow-up app-side tunes (fileman back to 720 wide with
  "New Drawer" fitting via its button min, tdemo back to
  400x420 with the File row's inset label floored at 16px).
  First-pass bug caught by screendump: Group.Min_Size had the
  horizontal MW/MH swapped (max-kid-HEIGHT fed MW), which grew
  fileman's window to a ~450px-tall button bar. QMP-verified:
  New Drawer 15px clear each side at 720, tdemo File label 4/3px
  top/bottom clearance at 420. Follow-up (this commit too):
  Button's min height LH+4 left the glyph cell touching the
  bottom bevel (tdemo button row) — now LH+8, same vertical
  slack as Input. 1847 PASS SMP4+SMP1, 0 FAIL.

- **M86f** (this commit): proportional UI font. tools/font2bdf.py
  gains `--proportional`: each glyph is trimmed to its ink bounds
  with DWIDTH = ink + 1 (space = 4) — the classic pseudo-
  proportional treatment on the SAME compiled-in 8x8 glyph data
  (zero license risk; only metrics change). The Makefile now ships
  both `Sys:Fonts/FONT8X8.BDF` (untouched) and `FONT8X8P.BDF`, and
  `Trinket.Fonts.Init`'s default path flips to the p variant
  (MUI XEN-font look; Bureau chrome never used this package and
  stays monospace Topaz-style). The runtime keeps a second
  `Mono_Glyphs` table — the compiled-in untrimmed 8x8 set on fixed
  8px advances — behind the new `Draw_Text_Mono`; the terminal (a
  grid device, cell alignment beats look) switches to it and is
  pixel-identical to pre-M86f. Proportional fallout fixed in the
  widgets: `Input` h-scroll (`Ensure_Visible`) and click-to-cursor
  are now pixel-granular against `Text_Width` prefix sums (was
  char-cells * 8), and `Text_Edit`'s `Locate`/selection
  band/cursor bar ditto via a `Col_X` prefix-sum helper. tdemo
  grew a "Font" group ("iiii llll vs WWW MMM") as the live
  showcase. QMP-verified: screendump ink runs on the label row —
  i/l advance 5px, W advance 8px (mono would be uniform 8).
  1848/1846 PASS SMP4/SMP1, 0 FAIL.

- **M86e** (this commit): toggle widgets. Trinket gains
  `Checkbox` and `Radio` (MUI CheckMark/RadioButton lineage):
  14px framed box (square / disc drawn with a doubled-coordinate
  circle test) + label, the whole rect is the hit area, state
  flips on release-inside and fires `On_Change (On : Boolean)`.
  The full M86c battery applies: hover Face_Hi box face, held
  press sinks the bevel and shifts the glyph, Disabled ghosts.
  Checked = embossed check (dark stroke, white +1,+1 shadow);
  selected radio = solid dot. Radios sharing a `Radio_Set`
  (access passed to `New_Radio`'s `Peers`) are mutually
  exclusive — selecting one clears + dirties the others
  (`Max_Radio` = 8/set is a documented policy constant).
  Programmatic `Set_Checked`/`Set_Selected` never fire the
  callback. tdemo grew a "Choices" group (Bold/Italic checkboxes
  + Left/Center/Right radio set) as the live showcase.
  QMP-verified: glyph pixels probed, Italic toggle-on, and
  Center-select clearing Left's dot. 1851/1850 PASS SMP4/SMP1.

- **M86d** (this commit): Xen scrollbars. Trinket `Scrollbar`
  restyled to the MUI/Xen look decoded from the Xen prefs preview:
  flat black/white frame, vertical 1px striped track and knob
  (Win_Face/Face), and MUI's signature layout — BOTH arrow boxes
  stacked at the bottom (up over down) with thin embossed chevron
  glyphs (black + white left shadow) replacing the old top/bottom
  filled triangles. (The first cut also stapled a blue checker
  "cap" under the knob, misreading the xenbar track-background
  accent as a knob part — dropped in the follow-up commit.)
  `Knob_Rect`/`On_Pointer` track region is now `Y+2 .. H-2*Arrow`
  with an underflow guard for degenerate bars (H <= 2*Arrow+2
  renders plain face, ignores pointer). M86c press feedback
  (sunken + glyph shift, sunken knob while dragging) kept at the
  new positions. QMP-verified. 1851 PASS SMP4 + SMP1.

- **M81** — WB chrome + real zoom (commits 95292ac, 3f07002, and
  the v5 commit closing this entry): screen-bar menus now REPLACE
  the "Bureau" title (start at x=8); title gadgets are full
  band-height and flush to the edges with WB glyphs (close box /
  zoom square / depth squares); the depth gadget toggles
  front/back with focus following (gadget gestures are eaten
  wholesale — Eat_Gesture — so a send-to-back can't retarget a
  held-button drag at the new front window). Trinket damage is
  per-cluster (Dirty_List + merge, Dirty_Union fallback past 8).
  Window protocol v5: Op_Surface_Create w2 flags (bit 0 =
  resizable), Input_Event_Resize (kind 5, Pack_Size value),
  Op_Surface_Resize (28) — Bureau asks, the client acks with a
  fresh buffer cycle, geometry moves only at ack (no rendezvous;
  non-complying clients leave the window untouched). Trinket
  Open(Resizable => True default) reallocates + re-lays out;
  raw clients (terminal/demo) get a ghosted inert zoom gadget.
  Headroom in the same commits: Trinket chunks 4→16, bureau
  Surf_Max_Objects 8→16 (a zoomed 1024x768 pane = 12 chunks).
  Slot-reuse now also resets Menu_Count (latent leak).
- **M79** — host file sharing via virtio-9p: `Drivers/Virtio9p`
  speaks 9P2000.L over a single virtqueue and serves the `Host:`
  volume (full read/write/create/delete/mkdir/rename/truncate).
  Runtime opt-in via qemu args only — no device on the bus, no
  driver, no mount, no error. `make test` attaches `./share` by
  default (QEMU_9P_FLAGS; empty = suite skips Host: checks) and
  asserts guest writes host-side after the run. fileserver
  Max_Volumes 8→12 (the table was full; Net: lost the race).
- **M78b** — opt-in DHCP client (lwIP dhcp.c behind a writable
  `Net:dhcp` file + `ENV:Net.DHCP` boot flag; static config stays
  the default, restored on stop). Tests/Dhcp_Test boots in the
  test manifest (program 15).
- **M78a** — netserv-resident DNS resolver (lwIP dns.c behind
  `Op_Resolve=28`); the m73 per-client resolver deleted; hairpin
  closed-port precheck learned about lwIP-internal pcbs.
- **M77** — net-stack polish: virtio_net_hdr legacy-vs-modern
  asserted loud at boot; net watchlist cleared.
- **M76** — kernel hardening: endpoint caller-queue tail
  validation, `Process_Slot_Of` no longer aliases slot 0,
  `Exit_Current` removes the dying thread from the sleep queue.
- **M75** — caps travel in IPC replies (+ reply-cap generation
  tags); the libman manager path works for the first time.

(detail: `git log`, `docs/HISTORY.md`)

## Recently completed

**M82 done — BeFS file server** (metadata in the filesystem:
typed attributes, indices, journal; BeOS/Haiku BFS is MIT-licensed).
Route: **pure-Ada re-implementation** (Bfs_Engine), with the Haiku
BFS sources as reference reading only — the vendored-C++ route was
explored and abandoned (~11k LoC subset, ~15-header shim surface,
block_cache API churn between the pinned snapshot and master).
Plan: M82a C++ toolchain gate (built, proven, then dropped with the
vendoring route); M82b host-side mkbefs fixture + second GPT
partition; M82c pure-Ada BFS server (read-only); M82d attribute
ops on the wire (19/20, done); M82e R/W + journal (done); M82f
indices/query (done — one-shot queries); M82g (done — buffer-carried
result paths, size/mtime index sync, live queries with ntfn
doorbells); M82h (done — multi-leaf btree splits, indirect stream
growth, attribute writes).

- **M82a reverted**: the xPack g++ gate was built and proven
  (cxx_test: static ctors, vtables, new/delete in-guest) but the
  vendored-C++ route it gated was abandoned, so the toolchain
  rules, gprkb KB addition, cxxbin wrapper, and Tests/Cxx_Test are
  removed again.

- **M82b done**: tools/mkbefs.py generates a valid 8 MiB BeFS image
  from scratch (superblock, allocation bitmap, empty 512-block log,
  inodes with small_data attributes, data streams with direct block
  runs, single-leaf btrees, populated name index + empty
  APP_SIG/last_modified/size indices); fixture tree = README.TXT
  (BEOS:TYPE + META:comment attrs), EMPTY.TXT, FRAGMENT.BIN (two
  runs, deliberate free hole), SUBDIR/HELLO.TXT. tools/befs_dump.py
  is the read-only lister / ground truth (and the parsing
  reference). disk.img grew to 72 MiB with GPT partition 2 (8 MiB,
  Haiku's registered BeFS type GUID) at sector 124928, befs.img
  dd'd in at the offset sgdisk reports. fuzz.adb part_query expects
  2 partitions; virtio_blk capacity check is 147456 sectors.

- **M82c done** (this commit): userspace/bfs is a pure-Ada
  read-only BeFS server — bfs_engine.ads/adb (superblock gates
  incl. empty-log check, 16-slot 1024-byte block cache over the
  partition endpoint, inode reader, direct+indirect data-stream
  mapping (double-indirect bails cleanly), B+tree iterator with
  leftmost-leaf descent and right-link follow, path Lookup, Stat /
  Read / Read_Dir / Volume_Info) + bfs.adb wire front in the
  fat32.adb shape (handles 1/2/3 = console/partN/svc; mutating ops
  answer Status_Bad_Args). Manifest program 17 "System/Bfs console
  part1 bfs_server"; init grants BFS_EP via the bfs_server token
  and Push_Bfs_Mount ("BD1"/"Befs", case-sensitive). fuzz Bfs_Tests
  (22 checks: content, run-boundary crossing, EOF semantics,
  case-sensitivity, nested paths, readdir, dir-open rejection,
  read-only rejections, volume info) — as a nested procedure
  because sibling declare-block locals accumulate in the parent
  frame and inline tests overflowed the 12-page user stack inside
  the ZCX unwinder. 1577 PASS / 0 FAIL.

- **M82d done**: attribute ops on the wire,
  append-only — Op_Attr_List = 19 (path words 0..3, index w4 ->
  status, type fourcc, data size, name[24]) and Op_Attr_Read = 20
  (path words 0..3, attr name words 4..5, buffer cap -> status,
  count, full size, type; whole-attribute read). Client API
  Akernel_User.Files.Attr_List/Attr_Read; fileserver forwards both
  verbatim for Is_FS volumes (non-FS: Not_Found empty-list for
  list, Bad_Args for read); fat32 rejects both via its default
  branch. Bfs_Engine walks the inode small_data region at 232
  ([type u32][name_size u16][data_size u16][name][NUL+2 pad]
  [data][NUL], name_size 0 ends). KEY FORMAT FACT: every file
  inode carries a NAME pseudo-attribute FIRST (type 'CSTR'
  FILE_NAME_TYPE, name_size 1, name byte 0x13 FILE_NAME_NAME,
  data = the file name) so the name index can back-refer; like
  Haiku's attribute iterator and befs_dump.py, both walks skip it
  (this cost a long debugging session: the engine was right and
  the test expectations were wrong — console IPC clobbers
  Syscalls.Message, which made mid-handler debug prints lie).
  fuzz Bfs_Tests grew 12 attr checks (list order/types/sizes,
  whole-attr reads of BEOS:TYPE/META:comment/root be:volume_id,
  empty list, unknown attr/file, fat rejection). 1591 PASS /
  0 FAIL.

- **M82e done** (this commit): journaled write path. Every
  mutating wire op is ONE journal transaction, WAL-ordered in
  Haiku's log format (Journal.cpp): modified blocks snapshot into
  the transaction, a run_array block {count, max_runs=127, merged
  sorted destination runs} + contents land in the 512-block log at
  log_end, the superblock goes DIRT ('DIRT' at 512+84) with the
  new log_end, blocks write to their destinations, then the
  superblock goes CLEN with log_start = log_end (immediate
  checkpoint — the log never accumulates). Mount replays a
  non-empty log (log offsets are positions within the log area,
  mod log length) before serving. Block allocator = first-fit over
  bitmap block 1 (bit i = block i, lsb-first) with a scan hint;
  used_blocks persists in the clean superblock write (engine-side
  Used_Pending delta folds in at commit). Btrees stay SINGLE-LEAF
  (no node splits): leaf insert/remove decode-sort-rebuild the
  node, duplicate keys allowed after existing equals (the name
  index needs them); a leaf without room fails the op with
  Bad_Args — fixture-scale directories never approach it. File
  data lives in the 12 direct runs only (indirect streams refuse
  delete/truncate, growth past 12 runs fails). Ops: Write
  (create-in-parent like fat32, no sparse, RMW partial blocks,
  grow-by-whole-runs with merge-when-contiguous), Delete, Truncate,
  Mkdir, Rmdir (empty-only), Rename (move across dirs, ".." fixup,
  own-subtree guard via ".." walk, small_data name attr rebuilt
  in place). Create/delete/rename keep the NAME index in sync
  (mtime/size indices still untouched — M82f material). Timestamps
  from Syscalls.Read_Clock (secs << 16; fixture epoch when no
  RTC). KEY BUG found by the fuzz round: uncommitted block
  modifications lived only in evictable cache slots, so a mid-
  transaction re-read could pull stale disk contents — Get_Block
  now overlays the open transaction's snapshots onto fresh disk
  reads. fuzz Bfs_Tests grew the idempotent write block (leftover
  cleanup first, full cleanup at the end; free-space must round-
  trip exactly = no leaked blocks): create-by-write, append,
  sparse rejection, bad-parent rejection, mkdir/dup-mkdir,
  nested write + readdir, rmdir non-empty rejection, delete,
  rename, cross-dir move with content intact, subtree-move
  rejection, truncate, fixture-intact re-check. `make test` now
  host-validates the mutated image with tools/befs_dump.py
  (parsable, log empty, README/HELLO intact, name index back to
  5 entries). New `make test-replay`: tools/befs_mkdirty.py
  injects a pending transaction (README's data block re-journaled
  with identical content, superblock DIRT) into the built image,
  boots the suite with SKIP_DISK=1 (new `run` escape hatch — the
  image rule's phony crate deps would otherwise rebuild it and
  wipe the injection), and requires "bfs: journal replayed" +
  0 FAIL + clean log afterwards. NOTE: `make test`/`run` always
  rebuild disk.img (phony deps), so each boot starts from a fresh
  fixture — fuzz idempotency is belt-and-braces. 1614 PASS /
  0 FAIL, replay test green.

- **M82f done** (this commit): one-shot BeFS queries, op 21
  (Op_Query). Wire: path words 0..3 (volume root — queries are
  volume-wide), match index in w4, NUL-terminated predicate in
  the buffer cap -> (status, size, is_dir, volume-relative
  path[24] in words 3..5); stateless like Op_ReadDir (index-th
  match, Not_Found ends). fileserver forwards verbatim for Is_FS
  volumes (buffer-cap forwarding + delete, attr-read shape);
  fat32's default branch answers Bad_Args. Bfs_Engine.Query:
  recursive-descent parser (term == != < <= > >= over quoted
  strings — \" \\ escapes — or decimal integers; && || ! and
  parens; AST = 24-node package array) -> enumeration rides the
  NAME INDEX leaf chain (complete index of every named entry,
  m82e keeps it synced) -> per-inode eval: name = */? glob on
  the index key, size = int64, last_modified = int64 SECONDS
  (mtime >> 16 — Haiku's shifted-index comparison special case
  does not apply to us), any other identifier reads the inode's
  small_data attribute (string preds glob the data bytes <= 64,
  numeric preds compare 4/8-byte LE data) -> result path
  materialized by walking the parent chain (inode+44) collecting
  name attrs; > 24 chars fails loud (impossible at fixture
  depth). KEY BUG: the AST nodes are package state and Pred_New
  only set .Kind — Attr_L/Str_L accumulated across calls so
  every query after the first mis-parsed; Pred_New now resets
  the record to defaults. Files.Query client API (predicate via
  the shared client buffer). New C command Sys:C/Query (`query
  BD1 name=="*.TXT" && size>0` — predicate = args 2..N joined,
  the shell passes '"' through). fuzz grew 16 query checks
  (exact name, cross-dir glob order, && / || / ! / parens, size
  ranges, BEOS:TYPE/META:comment attr terms, mtime, exhaustion,
  parse-error + fat rejection, command exit codes). 1650 PASS /
  0 FAIL; test-replay still green. DEFERRED (M82g candidates):
  live queries + notification plumbing, size/last_modified index
  sync (int64 numeric-key leaf variant), per-term index range
  acceleration, result paths > 24 chars.

- **M82g done** (this commit): the M82f deferrals, minus range
  acceleration (invisible optimization; enumeration is already
  name-index-driven). (1) Result paths ride the client buffer:
  Op_Query reply w3 = path length, bytes written into the RW-
  mapped buffer (engine Materialize_Path caps raised to 16
  components of 64 chars; request wire still caps qualified paths
  at 32); Files.Query reads the path back from its buffer; the
  C: Query command's path buffer is 255 now. (2) size /
  last_modified index sync: Init discovers both index inodes
  alongside "name"; new int64 leaf ops (8-byte LE keys compared
  numerically, btree data_type 3); hooks in Create_Entry (files
  join at size 0 — Build_Inode now takes the timestamp so inode
  and index agree), Write/Truncate (remove+add on change,
  journaled with the data), Remove_Entry (files leave both
  indices). Makefile post-test greps grew "size: 0 entries" /
  "last_modified: 0 entries" round-trips. (3) Live queries, ops
  22/23/24: Op_Query_Open (predicate in buffer cap 0, client
  notification cap in slot 1 — the kernel hands receivers a
  full-rights copy, so bfs can Signal) snapshots the parsed AST
  into a 4-slot subscription table -> (status, handle);
  Op_Query_Poll pops the oldest queued event -> (status, kind
  1=added/2=removed/3=resync, path in the buffer); Op_Query_Close
  releases slot + ntfn copy. Mutation ops diff per-subscription
  match bits before/after their change (Was captured from the
  lookup-time Inode_Info, Now re-read through the transaction
  overlay after the mutation) and queue path events; delivery is
  the Trans_Commit epilogue (never for aborted ops) — enqueue +
  Ntfn_Signal bit 0; an 8-deep queue overflow raises a one-shot
  resync event. Rename also updates the inode parent run (offset
  44) on cross-directory moves now — query path materialization
  walks it (latent M82e gap). RTS: Files.Query_Open/Poll/Close.
  fuzz: 7 long-path checks (26-char result through the buffer)
  + 20 live-query checks (doorbell on create/delete, added/
  removed events, non-match silence, closed-handle rejection,
  10-create overflow -> resync). 1675 PASS / 0 FAIL; test-replay
  green. KEY BUGS: (a) Eval_Node briefly took the ~2.5 KiB AST
  store by VALUE while recursing — passes by access now; (b) the
  fuzz live block's locals were hoisted into Bfs_Tests' frame and
  tipped the 48 KiB process stack (store fault at 0x6FFF3FF0 in
  streams__write's prologue, 240 bytes of headroom left) — the
  tests live in their own Live_Query_Tests procedure now, called
  after the big declare blocks close. The kernel's fatal trap
   dump grew sp/ra/proc lines (sbi_asm trap_frame_get_sp/ra) to
   diagnose (b) — kept as permanent diagnostics.

- **M82h done** (this commit): BeFS scale — the M82e "single-leaf,
  direct-runs only, append-only attrs" limits are gone. (1) Multi-
  leaf btree WRITES: Leaf_Max 24 -> 64 (1024-byte node capacity,
  real key sizes), block cache 16 -> 24 slots, scratch leaves moved
  to package state. New engine machinery: Tree_Descend (internal
  entries route right-of-separator: first separator STRICTLY
  greater than the target, else the overflow link; links/child
  pointers are STREAM OFFSETS, leaf values are inode blocks),
  Tree_Insert (in-place when the leaf fits, else split: lower half
  moves to a NEW LEFT node, push up (first key of the upper half,
  left node) — the separator is COPIED for leaves, DROPPED for
  internal nodes where its value becomes the left half's overflow;
  root split allocates a new root, depth caps at 3 = loud
  Bad_Args), Tree_Locate/Tree_Remove (duplicates land rightmost;
  Tree_Locate walks LEFT while the left neighbor's last key equals
  the target — splits can straddle equals), Tree_Alloc_Node
  (appends a block to the stream's direct runs, patches inode
  @72/@168/@208). No merge-on-remove (nodes leak until the whole
  stream is freed — Haiku-compatible layout, self-consistent
  split convention; the split test's free-space check uses a
  24-block bound with a printed delta instead of exact round-
  trip). tools/befs_dump.py walks multi-level btrees now (first-
  child descent by depth + right-link leaf chains). (2) Indirect
  stream growth: Stream_Read's indirect path was fixed to Haiku
  semantics (index blocks hold 128 VARIABLE-length block_runs;
  coverage accumulates from Max_Direct; max_indirect = absolute
  end) — the old fixed-length reading was never fixture-exercised.
  Indirect_Append grows into ONE index block (full array = loud
  Bad_Args; double-indirect still rejected by Delete/Truncate);
  once a file goes indirect its direct range never grows again;
  Free_Stream frees indirect data runs + the index block, so
  free-space round-trips EXACTLY. (3) Attribute writes,
  Op_Attr_Write = 25: path words 0..3, attr name (<= 16 chars)
  words 4..5, buffer cap carries le64 type @0 + le64 length @8 +
  data @16 (the IPC message has only 6 words — hence the buffer
  header); length 0 REMOVES. Bfs_Engine.Attr_Write insert/replace/
  remove in the small_data region with tail shifts (the 8-byte
  zeroed terminator rides the tail), guards the name pseudo-attr
  (1-char 0x13) and rejects data > Block_Size; live queries get
  Was/Now diffing like the other mutations; single transaction.
  fuzz: Btree_Split_Tests (56 SP files + 28 duplicate-name dirs
  force multiple splits incl. an internal-node split at depth 2;
  query over the split index; leak-bound check), Indirect_Stream_
  Tests (two files interleaved 28 KiB -> 12 direct + 16 indirect
  runs each; readback spot-checks; exact free round-trip),
  Attr_Write_Tests (18 checks: insert/replace grow+shrink/readback,
  list order, query sees fresh attr, remove + survivor intact,
  remove-absent Not_Found, fat32 Bad_Args). 1712 PASS / 0 FAIL;
  test-replay green. KEY BUGS: Hdr_Put64 on a header field writes
  only the le32 half where the next field starts at +4 (max_depth
  @8 clobbers data_type @12 otherwise — Hdr_Put32 for those);
  sparse writes (offset > EOF) are rejected, so the interleaved
  indirect test must append at exactly EOF; `make test` is ~6.5
  min now (the split test made the suite slower) — capture to a
  log, don't treat long runs as wedges.

- **M82i done** (this commit): long request paths (255) via a
  client buffer. Wire: an op whose qualified path exceeds its
  inline capacity (48 chars at words 0..5, 32 at 0..3 or 2..5)
  sets the first path word to Path_In_Buf (all-ones) and passes
  a one-page path memobj in the first cap slot the op does not
  otherwise use (0 for path-only ops, 1 when slot 0 is a data/
  predicate/rename-TO buffer, 2 for query-open); append-only —
  old servers would just Not_Found the marker "name". Client
  (akernel_user-files): lazy 1-page path buffer at the new fixed
  window 0x4400_8000 (above the 8-page read buffer, below the
  0x4600_0000 link base), Stage_Path picks inline vs buffer per
  op; Q strings widened to Max_Path. VFS (fileserver):
  Fetch_Path maps/reads/unmaps/cap_deletes the received copy
  immediately; forwards use the VFS's own 1-page staging memobj
  (Stage_Forward_Path, lazily allocated); Max_Expanded 96 -> 288;
  Handle_Rename's TO read/rewrite widened 48 -> 255. fs drivers:
  Path_Of (First, Slot) marker fallback in both fat32 and bfs;
  bfs TO buffer widened. Bfs_Engine: 21 internal path/component
  buffers widened 32 -> Max_Path_Len (255) — Split_Path would
  have raised CE on a 56-char component. fuzz: Long_Path_Tests
  (17 checks: 61-char dir, 113-char file; mkdir/write/readback/
  stat_ex/readdir/attr write+read+list/rename long FROM+TO/
  delete/rmdir; fat32 long-path miss probe). KEY DEBUG LESSON:
  Akernel_User.Console.Put_Line from a server MID-OP clobbers
  Syscalls.Message (the console write reuses the IPC buffer) —
  every "words look corrupted" observation via an inserted print
  was the print's own fault; use Syscalls.Debug_Put_Line for
  server instrumentation. 1738 PASS SMP4 / 1733 SMP1, 0 FAIL
  (one thread_regs flake on the first SMP4 run, green on
  re-run).

  **M82 complete** (a..i; a reverted with the vendored-C++
  route). Nothing else queued.

- **M86c done** (this commit): widget states. Listview selected
  rows draw inverted (white on the blue band). Button: Hover
  (face brightens to Theme.Face_Hi) + Disabled (embossed ghost
  label, pointer-inert; New_Button gained a Disabled parameter;
  tdemo shows a "Ghost" button). Scrollbar: held arrow draws
  sunken with the glyph shifted 1px; knob sunken while dragging
  (Arrow_Dn -1/0/+1). TWO NON-OBVIOUS FIXES: (1) hover needs
  move events where the pointer ISN'T — Group.On_Pointer only
  delivered to children containing the point, so a leave never
  cleared hover; Move now falls through to all children like
  Release already did. (2) Bureau stops delivering at the
  content edge, so a hovered gadget latched when the pointer
  left the window: Wins gained Ptr_Inside, and Forward_Pointer
  delivers ONE move one pixel past the bottom-right corner on
  the inside->outside transition (Inside() False everywhere =
  unlatch), coalesced like any move, one per transition only.
  QMP-verified: hover #CFCFCF->#AFAFAF on leave, ghost emboss,
  selection inversion, arrow bevel flip + glyph shift.
  1850 PASS SMP4 / 1851 SMP1, 0 FAIL.

- **M86b done** (this commit): Xen skin. Palette decoded from
  sasg.com's preview.gif (pixel-sampled via PIL in-memory, no
  files written) + MUI 3.8 Presets/XEN.prefs (IFF PREF; pen
  strings are BGR hex) + XEN/Plain brush CMAPs (.mf0/.mbr are
  ILBM; a ~40-line in-memory python ILBM decoder — FORM chunks,
  ByteRun1, planar->chunky — printed palette+ASCII art).
  THE LOOK: steel blue #3B67A2 title AND full window frame
  (frame fill follows focus: blue/gray), mid gray #959595
  window face, light gray #AFAFAF gadgets/panes (Xen gadgets
  sit LIGHTER than the window — inverse of the old flat WB
  gray, so Trinket's Face/Win_Face split: band fills and the
  Group title punch band moved to Win_Face, gadgets keep
  Face), soft #7B7B7B bevel shadows, panes (incl. terminal)
  AFAFAF, desktop solid #888888 (marble dither average), bar/
  menus AFAFAF with blue hot items, focused title text gets
  MUI's "shadow" style (dark +1,+1 copy under white).  Values
  live only in Akernel_User.Theme.  Known nit left for M86c:
  selected listview rows draw dark text on the blue band
  (uninverted).  QMP-verified colors pixel-exact.  1851 PASS
  SMP4 / 1850 SMP1, 0 FAIL.

- **M86a done** (this commit): Akernel_User.Theme — the single
  palette source (userspace/rts/akernel/akernel_user-theme.ads,
  dependency-free constants, opt-in like Font8x8: only programs
  that with it carry it).  Bureau's and Trinket's hand-synced
  palette blocks are now renames of Theme constants; the
  Pane drift (#F8F8F8 bureau / #FFFFFF trinket) unified on
  #FFFFFF (bureau's copy only blanked not-yet-mapped windows,
  visually nil).  Object renames in Ada take NO "constant"
  keyword ("constant not permitted in renaming declaration");
  and pragma Pure/Preelaborate can't be used — the Akernel_User
  root is uncategorized ("wrong categorization" errors).
  VERIFICATION LESSON: full-frame screendump pixel-diffs are
  useless across boots — startup spawn order is racy, so window
  cascade positions and focus stacking differ run to run;
  compare the SET of distinct colors instead (solid fills, no
  AA: identical palette-in-use <=> identical color set; 17/17
  here).  1850 PASS SMP4 / 1846 SMP1, 0 FAIL.

- **M85c done** (this commit): glob wiring. Dir and List take a
  wildcard pattern argument (Akernel_User.Glob syntax): the
  pattern is the tail after the last ':' or '/' (no separator:
  the whole arg, listed from the cwd — Dir) and the walk stays
  Start_Search ("*") with a Glob.Match filter per Simple_Name.
  Arguments WITHOUT wildcard tokens keep the old behaviour, so
  "Dir BD0:SUBDIR" still lists SUBDIR's contents rather than
  exact-matching the name. A matchless pattern is RC_Ok with no
  output (the N=0 "can't open" quirk only applies without a
  pattern). scripting-exec: Has_Metachar and the pipeline
  splitter now ignore '|'/'>'/'<' at paren depth > 0, so glob
  alternation "dir BD0:X/(a|c).dat > out" routes correctly
  (paren '|' is not a pipe; bare '>' still redirects). fuzz:
  FZDIR fixture (A.TXT 5, B.TXT 4, C.DAT 9) with redirected
  listings — containment checks for multi-match (readdir order
  is FS-dependent), exact Check_File for single-match
  ("  B.TXT 4", "  C.DAT 9"), plus a cwd-relative pattern-only
  arg. 1851 PASS SMP4 / 1850 SMP1, 0 FAIL.

- **M85b done** (this commit): Akernel_User.Glob — the shared
  Amiga MatchPatternNoCase analog, pure and syscall-free.
  Tokens: ? (any char), * (shorthand for #?), #x (zero or more
  of item x — literal, ?, %, escaped char or group), % (empty
  string), (a|b|c) alternation (no nesting), ~pat negation (to
  the end of the current group level), ' escape; case-insensitive;
  malformed patterns (trailing escape, unterminated group, bare
  '#') never match.  Match is anchored at both ends; Is_Pattern
  scans for any wildcard token.  Recursive anchored-slice
  matcher (MS over pattern/string index ranges); groups and '#'
  of a group try every prefix split (bounded by the 255-char
  name limit).  fuzz: 31-check battery (all tokens, anchoring,
  case, escapes, negation, malformed).  NOTE: bfs_engine has
  its own minimal Glob_Match (*, ? only, case-sensitive) behind
  C:Query — left alone deliberately; swapping it for
  Akernel_User.Glob would change Query to case-insensitive
  semantics and is a separate decision.  1776 PASS SMP4 /
  1777 SMP1, 0 FAIL.

- **M85a done** (this commit): EndCLI. New streams op
  Op_Endcli = 5 (append-only) + Akernel_User.Streams.Endcli
  (Endpoint) helper; reply Count 0 = "closing, exit" / 1 = "not
  a window, stay up" / IPC failure = 1. Terminal handles it by
  REPLYING FIRST (rendezvous discipline: calling Bureau before
  the reply would deadlock the pair), then taking the
  close-gadget path (Surface_Destroy + Process_Exit) — the
  surface dies, the shell's channel with it, and the shell
  exits on its own when its next Op_Read fails. Serial replies
  Count = 1 explicitly (the unknown-op fallthrough replies 0,
  which the shell would read as "closing"). Shell: "exit" is
  gone, "endcli" replaces it — same running-jobs double-tap
  warning (renamed Exit_Warned -> Endcli_Warned), then
  Endcli (Console_EP): 0 -> Process_Exit; else prints "endcli:
  console is not a window" and returns RC_Warn (5, below the
  default failat 10, so scripts continue). fuzz: script
  "endcli / set FZENDCLI=alive" — the marker proves the shell
  survives endcli on serial. QMP smoke: typed endcli+ret into
  the GUI terminal; window closed, File Manager frontmost, no
  faults. 1750 PASS SMP4 / 1748 SMP1, 0 FAIL.

- **M84c done** (this commit): double-click open. Detection lives
  in Trinket.Listview (Bureau pointer events carry no timestamps,
  so the widget times presses with Syscalls.Read_Time):
  Set_On_Double_Click + per-list Last_Press_Row/Time state;
  same row again within Double_Click_Ticks (4_000_000 = 400 ms
  at the 10 MHz mtime) fires the callback after the usual
  selection update; a press below the last row resets the pair
  state. Fileman: Open_Clicked's body refactored into
  Open_Item (P, Index), shared by the Open button and the new
  Double_L/R callbacks. QMP smoke: 900 ms-apart pair selects
  only; 160 ms-apart pair on the System drawer navigates the
  pane. 1738 PASS SMP4 / 1737 SMP1, 0 FAIL.

- **M84b done** (this commit): paint performance. Users were
  right: maximize/restore painted at ~1.2 s. In-guest
  instrumentation (Read_Time around Handle_Resize phases in
  trinket-window, Composite_Band paint vs present in bureau;
  QMP input-send-event to drive the zoom gadget headless)
  measured: bureau Paint_Band 480 ms for a 1M-px band, client
  buffer teardown+re-push 500 ms, client repaint 30 ms, present
  ~1 ms. Root cause: the runtime's required switches (from
  runtime.xml) carry NO -O flag, so ALL userspace built at -O0
  with checks; the compositor's per-pixel pane-copy/fill loops
  ran ~0.5 us/pixel. Fixes: (1) -O2 in akernel_program.gpr's
  new Compiler package (project switches land after the
  runtime's, so it wins); (2) bureau Fill_Rect + Draw_Window
  pane copy + trinket-paint Fill_Rect now use row-slice
  assignment (block set/copy, not per-pixel checked stores).
  -O2 surfaced strict-aliasing warnings in Akernel_User.Tables
  instantiations: Element_Access is carved by address
  arithmetic, now carries pragma No_Strict_Aliasing. Result:
  1M-px composite 478 -> 11 ms; maximize total ~1.2 s -> ~90
  ms. SMOKE-TEST RECIPE (recorded for reuse): headless GUI runs
  need QEMU_ARGS="-nographic -display none" — plain "-display
  none" drops -nographic and the guest serial console goes to
  the vc, so userspace output never reaches the log; and
  background QEMU needs setsid+disown or the tool-call process
  group kill takes it down.

- **thread_regs flake, REAL root cause** (this commit): the
  "10 ms" poll sleep added in the earlier flake fix was
  `Read_Time + 100` — but mtime ticks at **10 MHz** on qemu
  virt (the M66b comment's "10 kHz" was wrong; fixed), so +100
  = 10 us, and the kernel's past-deadline gate returned the
  sleep SYNCHRONOUSLY: the poll was a busy spin that never
  yielded the hart. At SMP4 other harts ran echo2 anyway
  (masking it); at SMP1 the spin fits inside one 50 ms quantum,
  so echo2 stayed Ready for the whole poll (debug run: state=0
  for all 100 tries, and each iteration measured ~0.5 s of
  actual sleep when the deadline finally did stick). Fixed:
  Sys_Yield + a real 10 ms sleep (+100_000) per poll. The
  earlier entry's "10 ms" claim was aspirational; this is the
  version that actually sleeps.

- **M84 done** (this commit): Fileman reworked into a
  Directory-Opus-style dual-pane lister. Per-pane state record
  (path/listview/scrollbar/path gadget) x 2 with an Active pane
  (click anywhere in a pane activates it — new listview
  On_Press callback, since On_Change only fires on selection
  CHANGE and re-clicking the selected row must count too);
  per-pane editable path boxes (Enter commits: ':'-qualified =
  absolute incl. volume switch, bare = relative to the pane;
  failure reverts the gadget); single equal-width 9-button bar
  (Open/Parent/Copy/Move/Rename/Swap/New Drawer/Delete/Quit);
  Copy/Move default to selection -> OTHER pane's dir (name
  field overrides for copy-as/rename/newdir); Move = fs rename,
  cross-volume fallback copy+delete (files only); Swap
  exchanges pane directories. Root group overrides On_Key:
  focused Inputs first, then the ACTIVE pane's list, then the
  other — the generic reverse-add-order walk would steer all
  nav keys to one pane. Initial loads' auto-selections fire
  activation, so Active is reset to 1 after them. KEY BUG found
  by QMP screendump smoke: the input seat keymap delivers
  Return as LF (10), but Input.On_Key committed only on CR (13)
  — On_Commit had NEVER fired anywhere; both accepted now.
  Manual gate via QMP input-send-event + screendump: dual-pane
  render, typed path commit (BD0: -> BD0:System, "Right pane
  active"), Swap exchange. 1739 PASS SMP4 / 1738 SMP1, 0 FAIL.

- **thread_regs flake fixed** (this commit): the fuzz check used
  a 256-iteration Sys_Yield loop waiting for the spawned echo to
  park in Receive. Two race modes: Sys_Yield returns instantly
  when the local ready queue is empty, so all 256 tries could
  burn before a busy hart ran echo2's first instruction (never
  Status=0); and a dump landing in a transient RTS-startup block
  read a non-receive state word ("frame fields sane" failed with
  a successful dump). Now the test polls process_info's state
  word for 3 = Blocked_Receive with 10 ms Sleep_Until between
  polls (wall time passes on every hart), then dumps exactly
  once. 4 consecutive clean gates (3x SMP4, 1x SMP1; 1737-1739
  PASS, 0 FAIL). Kernel side needed no change: the BKL
  (amoswap.d aq/rl) serializes kernel mode, and recv's block
  path saves the trap context before Set_State.

- **M83 done** (this commit): IPC/stack geometry. The user main stack
  moves from 0x7000_0000 to the top of the user window
  (User_Stack_Top = 0x8000_0000) and grows 12 -> 64 pages (48 ->
  256 KiB) — the IPC buffer page at 0x6FFF_0000 capped the old
  layout at 15 pages and M82g actually overflowed it
  (0x6FFF3FF0). User_Stack_Top/User_Stack_Pages live in
  kernel-processes.ads now; init (previously 4 pages with a
  duplicated constant in akernel.adb) shares them. The IPC buffer
  page is NOT relocated — the stack move alone removes the
  ceiling — but the last two fixed-constant userspace references
  (Thread_Create_Write_Params, Set_Grant) now discover the VA
  through syscall 43 like everything else. The ELF loader rejects
  segments outside [0x4000_0000, 0x8000_0000) or overlapping the
  stack (it had no VA bounds check at all).
  0x7000_0000..0x7FF0_0000 stays free, reserved for M80d's helper
  arena. fuzz: blocked-thread sp range follows the new layout;
  new deep-recursion check (~150 KiB — fatal before this
  change). 1714 PASS / 0 FAIL; test-replay green.

In flight: **M80 grow-on-demand tables** (the Max_* limit-fixes
pass) — spec `docs/LIMIT_FIXES.md`. Slices land one commit each:

- **M80b done** (this commit): scheduler queues -> intrusive TCB
  lists (Rdy/Slp Next/Prev on the TCB, endpoint Queue_Next
  precedent). Ready = doubly-linked list (tail push, boost head-
  insert, best-priority walk pop — same ordering as the packed
  array it replaces); sleep queue = sorted linked insert. Queue
  capacity now equals live-thread count, so fullness is
  unrepresentable: Max_Tasks=320, Sleep_Index 0..319 and
  Queue_Full deleted, the seven silently-dropped Wake/Sleep_Until
  results no longer hide a capacity failure. Threads 256 -> 512
  (Max_Thread_Slots exported; kernel-ipc's Max_Queue_Walk derives
  from it). Deferred-stack table drop now prints + counts (leak
  indicator). M80a placeholder bits: init decodes spawn failures
  loudly (No_Slot vs Scheduler/Cap/Load/Invalid), fuzz prints
  process/thread occupancy each run. 1715 PASS SMP4 / 1716 SMP1,
  0 FAIL both; boot smoke to shell clean.

- **M80c done** (this commit): notifications + queued sends ->
  PMM frame slabs on the endpoint Grow_Pool template (frames
  never returned, addresses stable, exhaustion = PMM OOM).
  Notifications: the first slot of each frame doubles as the
  frame-list link (never enters the free list); the old Slot_Of
  contiguity decode — the only address->index decode in any
  pool — is now a frame-range + alignment walk (Integer_Address
  is modular, so a negative diff wraps huge and the range check
  rejects it — same trick as before); all entry points went
  access-based, and Cleanup_Thread's waiter scan walks frames x
  slots. Max_Notifications=32 deleted (~24 peak at test boot).
  Queued sends (64 fixed): slab with a Next_Free link; alloc
  failure still falls back to blocking rendezvous (now OOM-only).
  1714 PASS / 0 FAIL, SMP4 and SMP1.

- **M80d done** (this commit): userspace grow-on-demand tables.
  New RTS helper Akernel_User.Tables (generic over element type,
  chunk-append growth over Mem_Alloc, 64-page chunks mapped into
  the new Table_Arena window 0x7000_0000..0x7FF0_0000 — the hole
  M83 left below the stack; compile-time arena-fit guard; lazy
  init since crates run no library elaboration; chunk-append
  never realloc-copies so user-visible indices stay stable;
  60-entry chunk directory = 15 MiB of table data, a documented
  sanity bound with 17x headroom under the 255 MiB window).
  Old array names survive as renames of Ref, so the 100+
  Table (I).Field sites read unchanged; scans run 1 .. Last and
  free-slot searches fall through to Append. fileserver:
  File_Table, Volumes, Assigns, Forward_Caps (1024-entry
  "bounded leak" comment retires), Pipes (32 x 16 KiB rings out
  of BSS), Pendings — all growable; exhaustion = arena/PMM OOM,
  answered loud per op. Fold-in: init's Push_* mount/name
  helpers now check the reply STATUS WORD, not just IPC_Ok (the
  m79 Net: silent no-mount class is dead — a fileserver
  rejection prints REJECTED at boot). CORRECTION to the M83-era
  notes: the helper arena is 255 MiB (0x7000_0000..0x7FF0_0000),
  not 15 — the 60-chunk directory bound is policy, not geometry.
  1714 PASS SMP4 / 1716 SMP1, 0 FAIL both.

- **M80e done** (this commit): network tables + s-osinte thread
  tables growable. netserv: Socks/Pend/Resolves are
  Akernel_User.Tables chunk chains (sock ids stay stable chunk
  indices — the badge is the id); Alloc_Sock appends when no
  free slot, capped at Max_Sock_Ids = the ring-window capacity;
  the sock-ring VA window grew 8 MiB -> 86 MiB (0x5420_0000..
  0x5B00_0000, 1376 pairs at the existing 64 KiB stride), with
  Buf_Win/ticker moved to 0x5B00/0x5B10/0x5B20/0x5B30. Glue:
  AKNET_MAX_SOCKS=8 listen-pcb array replaced by a malloc'd
  id->pcb list (open candidate 3 retires). lwIP: pools were
  already malloc-backed (MEMP_MEM_MALLOC=1); DNS_TABLE_SIZE
  4 -> 16 is the effective concurrent-resolve bound. Client RTS
  Akernel_User.Sockets: ring stride 1 MiB -> 64 KiB, ring window
  0x4A00..0x5100 (1792 pairs), Resolve_VA moved to 0x5100_0000,
  slot table via the helper. s-osinte: the mod-64 Descriptor/
  ATCB/Priority arrays (two live threads with congruent cap
  handles silently clobbered each other) replaced by a growable
  search table keyed by the exact cap handle — pages of 128
  entries mapped on demand at the new 0x5300_0000 window,
  linear search; no initializers anywhere (GNARL env-task setup
  calls in BEFORE body elaboration in some binder orders — an
  initializer would wipe a live table; BSS zero is the initial
  state). Debugging notes: own-address-space authority is cap
  255, NOT 0 (the pre-existing TLS map in Thread_Create passes
  0 and silently no-ops; left as-is); Makefile's crate -> RTS
  dependency was order-only, so RTS rebuilds never relinked
  program .elfs — now a normal prereq. 1719 PASS / 0 FAIL,
  SMP4 and SMP1.

- **M80f done** (this commit): remaining server tables ->
  Akernel_User.Tables. serial Lines (appends stamp the U64'Last
  free marker — zeroed chunk slots would alias badge 0) and
  Sinks; devmgr Lines (append-only manifest table; Last doubles
  as Line_Count) and Input_Svc (0..3 -> growable), both with a
  LOUD drop print on arena OOM instead of the silent manifest
  overflow; shell Jobs (job numbers user-visible via jobs/wait/
  kill — chunk-append keeps them stable; allocate = free slot,
  then steal oldest Done, then grow); libman Entries + client
  Akernel_User.Libs Open_Table (Cap=0 free markers match the
  zeroed default); gloss FDs (the chunk index IS the fd —
  lowest-free-fd semantics preserved, slots 1..2 padded once so
  the first file fd stays 3) and Dir_Slots (DIR* = index); bfs
  live-query Subs growable with the diff machinery decoupled to
  a fixed 64-wide match bitset (Live_Width is now a generous
  POLICY cap; Ev_Resync stays the queue-depth backstop) — the
  0-based slot numbering survives via a Ref (I + 1) wrapper;
  bureau Wins + Z chunk-appended, capped by the surface-region
  capacity (Surf 0x6800..0x6E00 = 24 slots at the 4 MiB stride,
  queues moved to 0x6E00, menu scratch to 0x6E10;
  Max_Win_Slots derives from the region so the table can never
  outrun the VA window; >24 windows and 1920x1080 surfaces are
  M80g's region rework, documented in the layout comment).
  Flake note: fuzz "thread_regs frame fields sane" failed once
  in four runs (racy blocked-thread register dump — the echo
  server must be parked in Receive when dumped; retry loop is
  bounded at 256 yields), green on re-run and at SMP1.
  1717 PASS SMP4 / 1719 SMP1, 0 FAIL both.

- **M80g done** (this commit): display ceiling 1024x768 ->
  1920x1080. virtio_gpu: clamp 1920x1080; attach-backing
  entries 768 -> 2048 (DMA pages 5..12, DMA_Pages 8 -> 13);
  FB_Objects is now a CEIL divide (the truncating formula gave
  31 x 64 = 1984 pages < 2025 at 1080p — latent at the old
  ceiling too, just never reachable). bureau: Max geometry +
  same ceil fix; Surf_Max_Objects 16 -> 32; surface stride
  4 -> 8 MiB (1080p pane = 2025 pages = 7.9 MiB), region
  0x6800..0x6E00 now holds 12 slots (documented: past 12 the
  region itself must move). terminal: Max geometry + ceil fix.
  Makefile: QEMU_GPU_FLAGS appended to the virtio-gpu device
  (default empty = 1024x768; big boot via
  QEMU_GPU_FLAGS=",xres=1920,yres=1080"). Gates: default
  geometry 1718 SMP4 / 1715 SMP1 (0 FAIL); one 1080p boot
  1719 PASS / 0 FAIL ("bureau display info ok" and "terminal
  surface ok" exercise the big path).

- **M80h done** (this commit): policy + census. AGENTS.md gains
  the capacity rule: tables grow on demand (Akernel_User.Tables
  chunk chains / kernel PMM slabs) or wire to a policy constant
  with room; a surviving static Max_* carries a written
  justification (wire format, hardware ring, boot order,
  transient staging, sizing). Census-comment cleanup:
  kernel-ipc Max_Words/Max_Caps (wire format), kernel-cpus
  Max_CPUs (boot-time config), terminal Max_Hist (UX policy),
  Max_Thread_Slots note refreshed now that M80b landed (sizing
  argument retained). fuzz gains a capacity-census group:
  Sys:/Net: mounts are hard checks (Sys: probed via README.TXT —
  its root does not answer Stat_Ex as a directory), Host:
  checked only when the 9p share is attached, and each run
  prints "m80 census: Net:tcp lines N, Proc: entries N, Host:
  mounted|absent" so capacity drift is visible in the log.
  Gates: 1721/1722 SMP4 (one thread_regs flake, green on
  re-run), 1722 SMP1, 0 FAIL.

  **M80 complete** (b/c/d/e/f/g/h); M82i landed after it.

## Open candidates

1. **Register fast path** — measure IPC call/recv cost, then decide
   whether a kernel-level register read/write primitive is worthwhile.
2. **ILBM image decoder** — add a `Trinket.Images.ILBM` decoder child.

Deferred (not candidates): socket servers (finger etc.), external
ICMP (slirp does not forward it — tests target the gateway by
design).

## Build / run

- `make all && make run` — interactive GUI.
- `make test` — suite (QEMU_SMP=4 default, also gated at SMP1).
- `make disk.img` — rebuild the GPT/FAT32 data partition.
- Host share (Host: volume) is runtime opt-in via qemu args:
  `make run QEMU_ARGS="-nographic $(QEMU_9P_FLAGS)"` exports
  `./share` read/write; `make test` attaches it by default
  (QEMU_9P_FLAGS= to disable).
