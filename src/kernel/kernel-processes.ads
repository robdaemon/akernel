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
end Kernel.Processes;
