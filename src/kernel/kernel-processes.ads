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

   UART_MMIO_Grant_Bit : constant U64 := 1;
   UART_IRQ_Grant_Bit  : constant U64 := 2;

   procedure Spawn_Program
     (Parent      : Kernel.Tasks.Thread_Access;
      Program_Id  : U64;
      Grant_Mask  : U64;
      Result      : out Status;
      Process_Cap : out Kernel.Capabilities.Handle);

   procedure Spawn_Boot_Path
     (Parent      : Kernel.Tasks.Thread_Access;
      Path_Offset : U64;
      Path_Length : U64;
      Grant_Mask  : U64;
      Result      : out Status;
      Process_Cap : out Kernel.Capabilities.Handle);

   procedure Reap_Process
     (Parent      : Kernel.Tasks.Thread_Access;
      Process_Cap : Kernel.Capabilities.Handle;
      Result      : out Status);
end Kernel.Processes;
