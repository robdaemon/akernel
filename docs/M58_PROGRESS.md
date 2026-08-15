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

## In progress
- (none)

## Not started
- Tier-1 shared-library machinery (Amiga-style library server).

## Design decisions taken
- Amiga-style library server for Tier-1 (no runtime code loading / relocations).
- Library clients will open a program on demand and receive its service endpoint via a rendezvous cap (convention handle 6, later fixed at 4 for minimal first version).
