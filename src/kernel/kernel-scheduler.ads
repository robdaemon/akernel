with Kernel.Tasks;

package Kernel.Scheduler is
   --  128 process slots (one task each) + IRQ tasks + margin.
   Max_Tasks : constant := 144;

   type Status is
     (Ok,
      Queue_Full,
      Queue_Empty,
      Invalid_Task,
      No_Current_Task);

   procedure Initialize;

   procedure Add_Task
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status);

   procedure Set_Current
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status);

   function Current return Kernel.Tasks.Thread_Access;

   procedure Yield (Result : out Status);

   procedure Block_Current
     (New_State : Kernel.Tasks.Thread_State;
      Result    : out Status);

   procedure Exit_Current (Result : out Status);

   procedure Wake
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status);

   procedure Remove_Thread
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status);

   --  True when a queued thread strictly outranks this hart's
   --  running thread (milestone 62 priorities).  Checked at
   --  syscall exit and on the preemption IPI so a priority-
   --  crossing wake reschedules immediately, not at the next tick.
   function Should_Preempt return Boolean;

   function Ready_Count return Natural;
end Kernel.Scheduler;
