with Interfaces;
with Kernel.CPUs;
with Kernel.Tasks;

package Kernel.Scheduler is
   --  M80b: no Max_Tasks — the ready and sleep queues are intrusive
   --  lists linked through the TCB, so queue capacity equals the
   --  live-thread count and queue fullness is unrepresentable.

   subtype U64 is Interfaces.Unsigned_64;

   --  Preemptive round-robin quantum: 20 Hz.  The timer interrupt
   --  fires at most this often, but will fire earlier when a sleep
   --  deadline is sooner.
   Quantum_Interval : constant U64 := 500_000;

   type Status is
     (Ok,
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

   --  Which CPU currently has TCB as its running thread, if any.
   --  Process teardown consults this to defer freeing a kernel
   --  stack whose owning hart may still be executing on it in
   --  user mode (m74 SMP stack-free fix).
   procedure Current_CPU_Of
     (TCB   : Kernel.Tasks.Thread_Access;
      Found : out Boolean;
      CPU   : out Kernel.CPUs.CPU_Index);

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

   --  Boost analog of Should_Preempt, for the UP IRQ-exit path
   --  (see the body).  Not consulted on SMP: sibling harts absorb
   --  the wake latency there.
   function Should_Boost_Preempt return Boolean;

   function Ready_Count return Natural;

   --  Sleep queue (milestone 66b).  Deadline is an absolute time in
   --  the same units as Arch.SBI.Time (mtime ticks).  A deadline in
   --  the past returns immediately without blocking.
   procedure Sleep_Until
     (Deadline : U64;
      Result   : out Status);

   --  Wake any threads whose deadline has passed.  Returns the
   --  earliest still-pending deadline, or U64'Last when empty.
   procedure Check_Sleepers
     (Now           : U64;
      Next_Deadline : out U64);

   --  Convenience for timer reprogramming: earliest of the next
   --  quantum tick and the next sleep deadline.
   function Next_Timer_Deadline (Now : U64) return U64;
end Kernel.Scheduler;
