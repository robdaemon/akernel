# Userspace tasking runtime design (Ravenscar first)

This is the design for enabling Ada tasking in userspace. The first
target is the **Ravenscar profile**: library-level tasks, protected
objects, `delay until`, and ceiling priorities. Full Ada tasking
(task entries, `select`, abort, dynamic tasks) is intentionally left
for a later milestone.

## Current state

`userspace/gnat-rts/gnat_user/system.ads` has:

```ada
pragma Restrictions (No_Tasking);
```

and `userspace/gnat-rts/runtime_build.gpr` builds a near-native
libgnat **without** tasking. The kernel already has threads,
priorities (milestone 62), and notifications, but no userspace thread
creation or blocking sleep primitive.

## Goal

Map each Ada task onto one kernel thread. Tasks in the same process
share the address space and cap table. The main (environment) task runs
`main`; dependent tasks are activated before `main` starts and reaped
before program exit.

## Kernel primitives to add

| syscall | purpose |
|---|---|
| `Thread_Create` | create a kernel thread in the caller's process; takes stack memobj, entry PC, arg, TLS base, priority; returns a thread cap |
| `Thread_Exit` | terminate the current thread; when the last thread exits the process exits |
| `Thread_Self` | return a stable thread id for `Ada.Task_Identification.Current_Task` |
| `Thread_Wait` / `Thread_Reap` | join a thread, mirroring `Reap_Process` |
| `Sleep_Until` | block the calling thread until an absolute `Ada.Real_Time.Time`; kernel maintains a sleep queue and programs the timer |
| `Mutex_Create` / `Mutex_Lock` / `Mutex_Unlock` | kernel mutex with FIFO wait queue (for the RTS global lock and protected objects) |
| `Cond_Wait` / `Cond_Signal` | condition variable, or reuse notification objects per wait |
| per-thread IPC buffer | each thread needs its own 4 KiB message page; today `0x6FFF_0000` is per-process |

### Per-thread IPC buffer

Today the kernel expects the IPC buffer at fixed VA `0x6FFF_0000`. With
tasking that address must become per-thread. Proposal:

- The kernel assigns each thread a unique IPC-buffer VA, e.g.
  `0x6FFF_0000 - Thread_Id * 0x1000`, maps the page at thread
  creation, and records the physical address in the TCB.
- The trap handler reads/writes the **TCB's buffer**, not a fixed VA.
- Userspace runtime keeps a per-task `Message` record at that VA.
- `Akernel_User.Syscalls.Message` changes from a fixed-address global
to a per-thread variable (stored in TLS or accessed via the thread's
IPC-buffer VA).

For secondary threads the runtime will allocate the buffer page with
`Mem_Alloc` and pass it to `Thread_Create`. The initial thread's buffer
stays at the legacy VA so existing code keeps working during the
transition.

### Thread-local storage

RISC-V `tp` register points to the current task's TLS block.

- Linker script gains `.tdata` and `.tbss` sections.
- `start-riscv64.s` copies the TLS template into the initial task's
  TLS block and sets `tp` before calling `__libc_init_array` / `main`.
- For secondary tasks `Thread_Create` receives a TLS base; the kernel
  sets `tp` when the thread starts.
- GNAT tasking uses TLS for `System.Soft_Links` jump-table pointers,
  the Ada Task Control Block (`ATCB`), and the secondary-stack pointer.
  The runtime copies `.tdata`/zero `.tbss` for each new task.

## Runtime architecture

### `system.ads` changes

Remove `No_Tasking`. Set the usual Ravenscar-compatible parameters:

- `Max_Priority`, `Max_Interrupt_Priority` aligned with the kernel's
  `-128..127` range.
- `Preallocated_Stacks := True`.
- `Stack_Check_Probes := False` (kernel guard pages are not planned
  yet).

### Tasking packages to provide / customize

The compiler expects a GNAT tasking ABI. We will provide a minimal
`gnat_user/` shadow layer:

| package | responsibility |
|---|---|
| `System.Soft_Links` | per-task jump table: `Lock_Task`, `Unlock_Task`, `Get_Jmpbuf_Address_Soft`, `Get_Stack_Check_Limit`, etc. |
| `System.Task_Info` | small per-task info block, points to ATCB |
| `System.Task_Primitives` (`s-taprop.adb`) | `Create_Task`, `Self`, `Yield`, `Sleep`, `Lock`, `Unlock`, `Set_Priority`, `Get_Priority`, `Exit_Task` |
| `System.Task_Lock` (`s-tasloc.adb`) | already exists; calls Soft_Links lock/unlock |
| `System.Tasking.Initialization` | task activation / termination |
| `Ada.Real_Time` | already implemented over `rdtime`; needs `Sleep_Until` backing |
| `Ada.Task_Identification` | provided by GNAT once primitives exist |

`s-taprop.adb` is the main integration point. It maps GNAT primitives
to Akernel syscalls:

- `Create_Task` → `Thread_Create` (stack allocated by runtime via `Mem_Alloc`).
- `Self` → `Thread_Self`.
- `Yield` → existing `Syscalls.Yield`.
- `Sleep` / `Timed_Sleep` → `Sleep_Until`.
- `Write_Lock` / `Unlock` → global RTS mutex (`Mutex_Lock` / `Mutex_Unlock`).
- `Set_Priority` / `Get_Priority` → existing `Set_Priority` syscall.
- `Exit_Task` → `Thread_Exit`.

### Protected objects

Ravenscar protected objects compile to calls into GNAT's protected
object runtime (`s-tpobop`, `s-tpoben`, `s-tpocon`). Those ultimately
use the global RTS lock plus condition variables. We can map them to
the same `Mutex` / `Cond` primitives used by `s-taprop`, or reuse a
per-protected-object mutex allocated by the runtime. For Ravenscar the
number of protected objects is statically bounded, so a kernel mutex
per PO is acceptable.

### Delays

`delay until T` will call `Sleep_Until (T)`. The kernel scheduler keeps
a sorted sleep queue keyed on absolute time. The existing 20 Hz tick
is too coarse; the kernel should program the CLINT timer for the next
wakeup deadline, preserving the current quantum tick when no sleeps
are pending.

### Stack allocation

Each task gets a fixed-size stack allocated as a memory object.
Ravenscar lets us declare sizes statically (`Storage_Size`), so the
runtime allocates exactly that. Guard pages are out of scope for the
first milestone; stack overflow will corrupt adjacent memory.

### Task activation and finalization

- The environment task's `main` is wrapped by the GNAT tasking startup
  sequence: activate library-level tasks first, then call `main`.
- `adafinal` joins all tasks before process exit.
- `Thread_Exit` on the last non-environment task wakes the environment
  task if it is waiting; `Thread_Exit` from the environment task
  terminates the process.

## GUI toolkit consequences

Tasking lets GUI apps keep a responsive event loop while doing work in
the background.

### Recommended pattern

- **Event-loop task** (usually the environment task): runs
  `Trinket.Window.Run`, blocks on `IPC_Recv`, and dispatches input
  events to widgets. It owns the widget tree and all `Surface_*`
  calls.
- **Worker tasks**: perform compute/IO (file load, image decode, search,
  etc.). They write results into a **protected event queue** and
  signal the event-loop task's notification so it wakes and redraws.

Because each task has its own IPC buffer, a worker task can make
filesystem or library calls without blocking the event loop. The event
loop blocks only on `IPC_Recv`, and that call is woken by either Bureau
input or a worker notification.

### Toolkit changes

- Add `Trinket.Application` / `Trinket.Event_Loop` helpers that run the
  loop in a dedicated task if the app wants `main` free for workers.
- Add `Trinket.Events.Protected_Queue` for worker → UI communication.
- Widget `Draw` and `Surface_Commit` stay single-threaded; workers only
  mutate model state and enqueue damage requests.

## Build integration

1. Remove `No_Tasking` from `system.ads`.
2. Add `.tdata`/`.tbss` to `linker-riscv64.ld`.
3. Update `start-riscv64.s` to set up the initial TLS block and `tp`.
4. Add new tasking shadow units under `userspace/gnat-rts/gnat_user/`.
5. Ensure `runtime_build.gpr` includes them in the override directory.
6. Add kernel syscalls and bump the syscall table.
7. Update `Akernel_User.Syscalls` to expose `Thread_Create`, etc., and
to make `Message` per-thread.

## Staged implementation plan

1. **Kernel threads**: `Thread_Create/Exit/Self/Wait`, per-thread IPC
   buffer VA, TLS base in context.
2. **Sleep + delays**: `Sleep_Until` syscall and kernel sleep queue.
3. **TLS + start.s**: linker sections, initial thread setup.
4. **Ravenscar runtime**: `s-taprop.adb`, Soft_Links, task lock,
   protected-object mutex, enable `No_Tasking => False`.
5. **GUI worker demo**: a Trinket app that loads/decodes an image in a
   worker task and updates the UI when done.
6. **Full Ada tasking**: task entries, `select`, abort, dynamic tasks
   — deferred.

## Open questions for tomorrow

1. Do we want a brand-new kernel `Mutex`/`Cond` object kind, or can we
   build task synchronization entirely on top of existing notification
   objects plus a kernel mutex for the RTS lock?
2. Should `Sleep_Until` be a separate syscall, or should we extend the
   existing `Set_Priority`/timer machinery with a "block until time
   X" flag?
3. How large should the default task stack be, and do we want a
   `Storage_Size` default enforced by the runtime or by the kernel?
4. Should the GUI demo use a static Ravenscar worker task, or do we
   want to prototype a task-pool generic?
