# Milestone 58 — Tier-1 shared-library machinery (breakdown)

Goal: Amiga-style shared libraries without runtime code loading or
relocations. A library is a server program; clients obtain its service
endpoint cap and talk to it through ordinary IPC.

Design decisions already locked:
- No dynamic linking / ELF relocations in the kernel or RTS.
- Client opens a library by spawning its ELF image on demand.
- The library returns its service endpoint to the client through a
  rendezvous cap.
- For the minimal first version, **handle 4** is reserved for this
  rendezvous/service endpoint (reused: client passes rendezvous in,
  library replies service endpoint out; client keeps the service cap
  at handle 4).
- Uniform program ABI stays unchanged otherwise: 1 = console Send,
  2 = fs Send, 3 = Bureau svc Send, 4 = library service endpoint
  (empty / unused when the program is not a library client).

---

## Piece 1 — Design doc & client-side API skeleton

Files: `docs/IPC.md` addition, `userspace/rts/akernel/akernel_user-libs.ads`

- Write the wire convention for library rendezvous:
  - Client creates an endpoint (`EP_Create`).
  - Client spawns `Sys:Libs/<Name>` with the rendezvous cap granted at
    handle 4 (Receive right).
  - Library startup creates its own service endpoint and sends it back
    on the rendezvous cap (a plain `Send` of a cap transfer).
  - Client receives the service cap, closes the rendezvous cap, and
    returns the service cap from `Open_Library`.
  - `Close_Library` sends a `Lib_Exit` request (or simply closes the
    service cap; the library server can watch the cap and exit).
- Add `Akernel_User.Libs` package skeleton:
  - `function Open_Library (Name : String) return U64;`
  - `procedure Close_Library (Cap : U64);`
- No implementation yet; just the spec and the protocol note.

Acceptance: package compiles, docs describe the rendezvous flow.

---

## Piece 2 — Library server helper crate

Files: `userspace/libserv/libserv.gpr`, `userspace/libserv/libserv.ads/adb`

- Create `Libserv` static library crate that links on top of the RTS.
- Provide:
  - `procedure Run (On_Open : access procedure);`
  - Reads the rendezvous cap from handle 4.
  - Creates the library service endpoint.
  - Sends the service cap back to the client through the rendezvous.
  - Enters a service loop receiving on the service endpoint.
  - Provides a `Shutdown` hook so the server exits cleanly when the
    last client closes its cap (endpoint teardown already wakes/warns
    queued callers from milestone 34).
- Keep it minimal: the actual library function dispatch is left to the
  library author; Libserv only handles the lifecycle boilerplate.

Acceptance: a trivial `userspace/testlib` crate (next piece) can be
built on top of Libserv and launched manually from the shell.

---

## Piece 3 — Example library and a hand-tested client

Files: `userspace/testlib/testlib.adb`, `userspace/testlib_client/testlib_client.adb`

- `testlib`: a server that uses Libserv and exposes one function:
  - Protocol label `1` = `Uppercase`, takes a 40-byte string and
    returns the uppercased string.
  - Install as `Sys:Libs/Testlib` on the disk image.
- `testlib_client`: a command-line program that:
  - Calls `Akernel_User.Libs.Open_Library ("Sys:Libs/Testlib")`.
  - Sends the Uppercase request with `Argument(1)`.
  - Prints the reply.
  - Closes the library.
- Test by typing `Testlib_Client hello` at the shell; expect `HELLO`.

Acceptance: interactive round-trip works, no crashes, cap leaks checked
by eye (both client and library delete transferred/minted caps).

---

## Piece 4 — `Open_Library` / `Close_Library` implementation

Files: `userspace/rts/akernel/akernel_user-libs.adb`, spawn path in
`Akernel_User.CLI` or a new helper.

- Implement `Open_Library`:
  - Resolve `Sys:Libs/<Name>` through the fs cap (handle 2).
  - Stage the ELF into a memory object (reuse the memstage pattern).
  - `EP_Create` a rendezvous endpoint.
  - `Set_Grant(0, Console_EP, Send, 0)`.
  - `Set_Grant(1, FS_EP, Send, 0)`.
  - `Set_Grant(2, Bureau_EP, Send, 0)`.
  - `Set_Grant(3, Args_Cap, Map+Read, 0)`.
  - `Set_Grant(4, Rendezvous_Cap, Send+Receive+Transfer, 0)`.
  - `Set_Grant(5, Elevated_Svc, Send, 0)` if needed.
  - `Spawn` the library.
  - `IPC_Recv` on the rendezvous endpoint to collect the service cap.
  - `Cap_Delete` the rendezvous cap and the staging object cap.
  - Return the service cap.
- Implement `Close_Library`:
  - Optional: send a `Lib_Close` label on the service cap.
  - `Cap_Delete` the service cap.

Acceptance: `Testlib_Client` works using the real `Akernel_User.Libs`
implementation instead of hand-rolled code.

---

## Piece 5 — Fuzz / regression tests

Files: `userspace/fuzz` addition or a new directed test crate.

- Add directed tests:
  - Open a non-existent library returns 0.
  - Open → call → close does not leak caps (use `Sys_Cap_Info` or a
    before/after cap count if admin introspection is available).
  - Multiple clients can open the same library concurrently.
  - Library server exits after the last client closes.
- Ensure `make test` stays green.

Acceptance: fuzz failures = 0, kernel self-resets, fsck clean.

---

## Piece 6 — Integration cleanup

Files: `Makefile`, `docs/M58_PROGRESS.md`, `docs/NEXT.md`

- Add `libserv` and `testlib` to crate lists.
- Install `Testlib` into `Sys:Libs/` on disk.img.
- Add `Sys:Libs/` directory creation in the disk recipe.
- Update M58_PROGRESS.md: mark Tier-1 as shipped.
- Update NEXT.md deferred list: remove Tier-1, add any follow-ups
  (e.g. library versioning, reference counting across multiple opens).

Acceptance: `make test` green, docs current.

---

## Order and dependencies

1. Piece 1 (design + API skeleton)
2. Piece 2 (Libserv helper) — depends on Piece 1
3. Piece 3 (example + hand test) — depends on Pieces 1–2
4. Piece 4 (client implementation) — replaces the hand-rolled code in
   Piece 3
5. Piece 5 (tests)
6. Piece 6 (cleanup + docs)

Each piece is intended to fit in a single focused session.
