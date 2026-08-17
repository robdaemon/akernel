with Interfaces;
with System;
with Kernel.Capabilities;
with Kernel.Tasks;

package Kernel.Processes is
   subtype U64 is Interfaces.Unsigned_64;

   type Status is
     (Ok,
      Invalid_Program,
      No_Slot,
      Load_Failed,
      Cap_Failed,
      Scheduler_Failed,
      Invalid_Parent,
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
   --      5 blocked-notification, 6 dead)
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
