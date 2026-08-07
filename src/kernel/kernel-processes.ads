with Interfaces;
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
      Result      : out Status);

   procedure Mark_Exited (Thread : Kernel.Tasks.Thread_Access);

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
   Info_Word_Count : constant := 8;
   type Process_Info_Words is array (0 .. Info_Word_Count - 1) of U64;

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
end Kernel.Processes;
