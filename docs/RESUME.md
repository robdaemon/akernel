# Resume prompt (next session)

```text
Read docs/STATE.md, docs/NEXT.md, docs/IPC.md. Implement milestone 9:
Memory objects — alloc/map/unmap syscalls, Memory_Object cap kind
(Map/Read/Write rights), PMM-backed frames, refcounted teardown.
Needed by RTS heap, bulk IPC, DMA later. Design sketch in docs/IPC.md
("Memory objects (bulk/DMA)"). Follow with milestone 10 (RTS heap on
memory objects) if scope allows.

Milestone 8 landed: Akernel_User.Streams Endpoint_Stream (Ada.Streams
Root_Stream_Type over endpoint caps; a-stream/a-ioexce vendored into
userspace/rts/akernel, per-program -gnatg in each userspace .gpr),
Akernel_User.Console Put/Put_Line, init-minted console endpoint
(console = Send / console_server = Receive manifest tokens),
Drivers/Serial console server (UART RX opportunistic; IRQ RX waits
on notifications), fuzz/echo/spin migrated off debug_putchar.
42/42 directed PASS, fuzz failures=0.

Key files: userspace/rts/akernel/akernel_user-streams.* (stream
protocol + Endpoint_Stream), akernel_user-console.* (client print
path), userspace/serial/serial.adb (console server), init.adb
(console endpoint minting). Gotcha: any console print round-trips
through the caller's IPC message buffer — snapshot IPC replies into
locals before printing (see fuzz echo rounds). Kernel uses raw
light-rv64imafdc; vendored RTS units are userspace-only.
Build/run: make all && make run. Commit per milestone; docs
current-state only.
```
