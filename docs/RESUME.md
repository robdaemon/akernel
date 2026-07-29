# Resume prompt (next session)

```text
Read docs/STATE.md, docs/NEXT.md, docs/IPC.md. Implement milestone 8:
Akernel_User.Streams — Root_Stream_Type over endpoint caps as the I/O
substrate; console output path as first consumer (replaces
debug_putchar for normal programs).

Milestone 7 landed (b3a60d0..c38aa0b): Akernel_User.IPC typed RPC
wrappers (generic over request/response records, 48-byte word-area
limit), echo migrated, init namespace composition (manifest grant
tokens = bootinfo names via Boot_Cap/Boot_Cap_Rights; only ipc_test
special). 40/40 fuzz PASS.

Key files: userspace/rts/akernel/akernel_user-ipc.* (typed wrappers),
akernel_user-syscalls.* (raw ABI + bootinfo), userspace/echo/echo.adb
(protocol showcase), userspace/serial/serial.adb (UART MMIO driver —
likely console server host). Design rules in docs/IPC.md: protocol
lives in userspace, kernel never parses payloads; console should be a
server holding the UART caps, clients get endpoint caps.
Build/run: make all && make run. Commit per milestone; docs
current-state only.
```
