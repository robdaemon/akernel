with Interfaces;
with System;
with Kernel.Capabilities;
with Kernel.Tasks;

package Kernel.Processes is
   subtype U64 is Interfaces.Unsigned_64;

   --  User main stack geometry (M83): the stack descends from the
   --  top of the user VA window [0x4000_0000, 0x8000_0000).  M82g
   --  overflowed the old 12-page stack descending from
   --  0x7000_0000 (store fault at 0x6FFF3FF0 in the ZCX unwinder;
   --  the IPC buffer page at 0x6FFF_0000 capped that layout at 15
   --  pages).  0x7000_0000..0x7FF0_0000 stays free, reserved for
   --  the M80d helper arena (docs/LIMIT_FIXES.md).  Stacks are
   --  eager PMM frames: user page faults are fatal, there is no
   --  demand paging or guard page.
   User_Stack_Top   : constant U64 := 16#8000_0000#;
   User_Stack_Pages : constant := 64;

   --  Thread-table bound (M80b: 256 -> 512; thread ids are a
   --  monotonic counter, so unlike pids there is no encoding
   --  ceiling).  Exported so the IPC caller-queue walk bound
   --  (kernel-ipc.adb) derives from it instead of duplicating a
   --  literal.  Ceiling retained deliberately (M80g sizing):
   --  512 threads x ~300 KB/thread (TCB + kernel stack +
   --  guard + initial user frames) ~= 150 MB worst-case PMM,
   --  comfortably inside the 8 GB memory map.
   Max_Thread_Slots : constant := 512;

   type Status is
     (Ok,
      Invalid_Program,
      No_Slot,
      Load_Failed,
      Cap_Failed,
      Scheduler_Failed,
      Invalid_Parent,
      Invalid_Cap,
      Not_Exited);

   procedure Initialize;

   --  Spawn grant-list ABI (docs/IPC.md): the parent lays out up to
   --  Max_Grants entries of 24 bytes (handle u64, rights mask u64,
   --  badge u64) in its IPC buffer page at Grant_List_Offset. The
   --  kernel validates each (handle open in parent, not a reply cap,
   --  rights a subset of the parent's, mask within Valid_Rights_Mask)
   --  and mints the caps into the child's table at handles 1..N in
   --  list order. Rights-mask encoding: Kernel.Capabilities.To_Rights.
   Max_Grants        : constant := 32;
   Grant_List_Offset : constant U64 := 128;

   procedure Spawn_Boot_Image
     (Parent      : Kernel.Tasks.Thread_Access;
      Image_Cap   : Kernel.Capabilities.Handle;
      Grant_Count : U64;
      Result      : out Status;
      Process_Cap : out Kernel.Capabilities.Handle);

   procedure Reap_Process
     (Parent      : Kernel.Tasks.Thread_Access;
      Process_Cap : Kernel.Capabilities.Handle;
      Exit_Code   : out Kernel.Capabilities.U64;
      Result      : out Status);

   procedure Mark_Exited
     (Thread : Kernel.Tasks.Thread_Access;
      Code   : Kernel.Capabilities.U64);

   --  Threading primitives (Milestone 66).
   --  Thread_Create: create a new thread in the caller's process.
   --  The caller writes a parameter block into its IPC buffer:
   --    words(0) = stack top VA
   --    words(1) = stack pages
   --    words(2) = entry PC
   --    words(3) = argument (passed in a0)
   --    words(4) = TLS base
   --    words(5) = priority (signed, raw bits)
   --    caps(0)  = stack memory cap (Map+Read+Write)
   --    caps(1)  = IPC buffer memory cap (Map+Read+Write)
   --    caps(2,3) = 0
   --  Returns the new thread cap handle (Thread_Object, Manage+Wait)
   --  or U64'Last on failure.
   procedure Thread_Create
     (Parent      : Kernel.Tasks.Thread_Access;
      Thread_Cap  : out Kernel.Capabilities.Handle;
      Result      : out Status);

   --  Thread_Exit: terminate the current thread. If it is the last
   --  thread of the process, the process exits with code 0.
   procedure Thread_Exit
     (Thread : Kernel.Tasks.Thread_Access;
      Result : out Status);

   --  Thread_Wait: block until the thread named by Thread_Cap has
   --  exited. Returns Ok if the wait succeeds, Invalid_Cap if the
   --  handle is not a Thread_Object cap with Wait right, or
   --  Invalid_Parent if the calling thread is unknown.
   procedure Thread_Wait
     (Caller     : Kernel.Tasks.Thread_Access;
      Thread_Cap : Kernel.Capabilities.Handle;
      Result     : out Status);

   --  Thread_Self: stable kernel thread id for the current thread.
   function Thread_Self
     (Thread : Kernel.Tasks.Thread_Access)
      return Kernel.Tasks.Thread_Id;

   --  Kernel stacks cannot be freed by the thread still running on
   --  them.  Thread_Exit / Mark_Exited push the frame onto a per-CPU
   --  deferred list; the trap handler / idle loop drains it once the
   --  CPU is no longer on that stack.  Deferred entries carry the
   --  hart's trap epoch: a stack becomes freeable two epochs after
   --  recording, because a thread killed while running in user mode
   --  on another hart (Mark_Exited) still takes its first trap —
   --  and the trap-entry drain — on the doomed stack.
   procedure Free_Kernel_Stack_Later (Stack_Top : U64);
   procedure Drain_Deferred_Kernel_Stacks;

   --  Bump this hart's trap epoch (called by the trap handler at
   --  every trap entry, before Drain_Deferred_Kernel_Stacks).
   procedure Note_Trap_Entry;

   --  Process introspection (milestone 37a): fixed-size binary
   --  snapshot of one process for the process_info syscall; the
   --  userspace caller renders it (kernel never formats text).
   --  Word layout (all U64):
   --    0 process id
   --    1 spawner process id (0 = kernel-started)
   --    2 lifecycle (Process_State'Pos: 0 initializing, 1 alive,
   --      2 dead)
   --    3 thread state (Thread_State'Pos: 0 ready, 1 running,
   --      2 blocked-send, 3 blocked-receive, 4 blocked-irq,
   --      5 blocked-notification, 6 blocked-sleeping,
   --      7 blocked-thread-wait, 8 dead)
   --    4 open cap count
   --    5 flags: bit0 awaiting reply, bit1 reply wanted,
   --      bit2 wakeup-boosted, bit3 ready-queued
   --    6 endpoint object the thread is blocked receiving on
   --      (0 = not in a receive wait)
   --    7 badge recorded at the thread's last Call
   --    8 scheduling priority, sign-extended (-128 .. 127;
   --      milestone 62)
   Info_Word_Count : constant := 9;
   type Process_Info_Words is array (0 .. Info_Word_Count - 1) of U64;

   --  Sys_Set_Priority backing op (milestone 62): set the
   --  priority of the (single) thread owned by the process whose
   --  PCB is at Process_Object (a Process_Object cap's object
   --  address, authority already checked by the caller).  Found is
   --  False when the address names no live table process.
   procedure Set_Thread_Priority
     (Process_Object : System.Address;
      New_Priority   : Kernel.Tasks.Thread_Priority;
      Old_Priority   : out Kernel.Tasks.Thread_Priority;
      Found          : out Boolean);

   --  Process table bound for by-slot enumeration.
   function Slot_Count return Natural;

   --  Snapshot slot Slot (0-based); Found is False for an unused
   --  slot. Only meaningful under the big kernel lock (the syscall
   --  path holds it).
   procedure Read_Process_Info
     (Slot  : Natural;
      Words : out Process_Info_Words;
      Found : out Boolean);

   --  Snapshot the process owning Thread. Works for kernel-started
   --  processes (bootstrap, driver, init) that have no table slot.
   procedure Read_Own_Process_Info
     (Thread : Kernel.Tasks.Thread_Access;
      Words  : out Process_Info_Words);

   --  Sys_Cap_Info record (milestone 39): one cap-table slot.
   --    0 handle, 1 object-kind position, 2 rights mask (To_Mask
   --    encoding), 3 object address, 4 badge, 5 valid (0/1),
   --    6..7 zero
   Cap_Info_Word_Count : constant := 8;
   type Cap_Info_Words is array (0 .. Cap_Info_Word_Count - 1) of U64;

   --  Snapshot cap Cap_Index of slot Slot; Found is False for an
   --  unused process slot, an out-of-range index, or an empty
   --  cap-table slot (sparse by-index walk, Op_ReadDir idiom).
   procedure Read_Cap_Info
     (Slot      : Natural;
      Cap_Index : U64;
      Words     : out Cap_Info_Words;
      Found     : out Boolean);

   procedure Read_Own_Cap_Info
     (Thread    : Kernel.Tasks.Thread_Access;
      Cap_Index : U64;
      Words     : out Cap_Info_Words;
      Found     : out Boolean);

   --  Sys_Thread_Regs record (milestone 39): saved trap frame.
   --    0..30 = x1..x31, 31 = sepc, 32 = satp, 33 = thread-state
   --    position, 34 = process id, 35..39 zero
   Regs_Word_Count : constant := 40;
   type Thread_Reg_Words is array (0 .. Regs_Word_Count - 1) of U64;

   --  Snapshot slot Slot's thread. Found is False for an unused
   --  slot. Busy is True (and Words zero) when the thread is ready
   --  or running — its live registers are not in the saved frame;
   --  there is deliberately no cross-hart stop-the-world.
   procedure Read_Thread_Regs
     (Slot  : Natural;
      Words : out Thread_Reg_Words;
      Found : out Boolean;
      Busy  : out Boolean);
end Kernel.Processes;
