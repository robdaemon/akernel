# Milestone 58 progress checkpoint

## Done
- `Trinket.Listview` child package added (`userspace/trinket/trinket-listview.ads/adb`).
- `Trinket.Widgets` extended with `Set_Text` for labels and `Get_Item` added to listview.
- `userspace/fileman` crate created with `fileman_app.adb` using Listview + Scrollbar.
- `Fileman` added to `DISK_CRATES_SYSTEM` and `System/Startup` in Makefile.
- `fileman`, `edit`, `tdemo`, `demo`, `bureau` all build successfully.
- Terminal scrollbar adoption complete:
  - `Terminal_Buffer` and `Terminal_Scroll` packages wired into `terminal.adb`.
  - `terminal.adb` now renders via Trinket (scrollback text area + right-edge scrollbar) and handles nav keys and pointer scrolling.
  - Old direct-grid rendering (`Cur_Col`/`Cur_Row`, `Draw_Glyph`, `Scroll`, direct `Put_Char`) removed.
  - Bug fixed: `Terminal_Buffer.Put_Char` now keeps `Buffer(Current).Len` in sync with `Current_Len` so partial lines render immediately (typing echo works).
  - Solid block text cursor drawn at the current input position.
- End-to-end `make test` green: fuzz failures=0, kernel self-resets on both SMP1 and SMP4.
- Tier-1 Piece 1: library rendezvous design doc added to `docs/IPC.md` and `Akernel_User.Libs` skeleton (`akernel_user-libs.ads/adb`) compiles.
- Tier-1 Piece 2: `Libserv` helper crate created (`userspace/libserv/libserv.gpr`, `libserv.ads`, `libserv.adb`) and builds `liblibserv.a`.

- Tier-1 Piece 3: `Testlib` server + `Testlib_Client` hand-rolled client created, build, and install to `Sys:Libs/Testlib` and `Sys:C/Testlib_Client`; round-trip verified via non-interactive `Testlib_Smoke` startup entry (`testlib smoke: reply = [HELLO]`); `make test` still green. Fixed a wire-convention bug: the rendezvous cap must be granted to the library with `Send + Receive + Transfer` rights (not just `Receive + Transfer`) so the library can send the service cap back.
- Tier-1 Piece 4: implemented `Akernel_User.Libs.Open_Library`/`Close_Library` in `userspace/rts/akernel/akernel_user-libs.adb`; `Testlib_Client` now uses the API instead of hand-rolled code; `Testlib_Smoke` verifies the API end-to-end. `make test` green.

## In progress
- Tier-1 Piece 5: added directed fuzz tests in `userspace/fuzz/fuzz.adb` for the shared-library lifecycle: missing library returns `Invalid_Handle`; `Open`/`Uppercase`/`Close` round-trip; cap-count before/after unchanged; multiple concurrent opens return distinct caps; re-open after close works. `make test` green with `failures=0`.
- Tier-1 Piece 6: integration cleanup complete. `Makefile` installs `Testlib` into `Sys:Libs/` and `Testlib_Client` into `Sys:C/`; `docs/IPC.md` and `docs/M58_TIER1_PLAN.md` updated with the corrected `Send + Receive + Transfer` rendezvous-rights convention and the optional console/fs/bureau cap parameters.

## In progress
- (none)

## Not started
- (none)

## Design decisions taken
- Amiga-style library server for Tier-1 (no runtime code loading / relocations).
- Library clients will open a program on demand and receive its service endpoint via a rendezvous cap (handle 5; the uniform args page remains at handle 4).
