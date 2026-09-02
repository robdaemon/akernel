with Arch.SBI;

package body Kernel.Scheduler is
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;
   use type U64;

   --  M80b: the ready and sleep queues are intrusive lists linked
   --  through the TCB (the endpoint caller queue's Queue_Next is
   --  the precedent).  A queue never needs capacity beyond live
   --  threads, so linking through the TCB makes fullness
   --  unrepresentable — the old packed arrays (Max_Tasks = 320,
   --  Sleep_Index 0..319) and the silently-dropped Queue_Full
   --  results are gone as a class.  Ready selection is unchanged:
   --  best-priority walk, boosted ties first, then FIFO (the list
   --  order is the old array order: tail push, head boost-insert).
   Ready_Head : Kernel.Tasks.Thread_Access := null;
   Ready_Tail : Kernel.Tasks.Thread_Access := null;
   Ready_N    : Natural := 0;

   --  Sleep queue: sorted by ascending deadline, Sleep_Head first.
   --  A thread appears here only while its state is
   --  Blocked_Sleeping.
   Sleep_Head : Kernel.Tasks.Thread_Access := null;

   --  Per-hart running thread (SMP).  One global ready queue feeds
   --  all harts; threads migrate freely.  All state is protected by
   --  the big kernel lock (Kernel.Lock): every entry point here runs
   --  with it held.
   Current_TCBS : array (Kernel.CPUs.CPU_Index) of
     Kernel.Tasks.Thread_Access := (others => null);

   function My_Current return Kernel.Tasks.Thread_Access is
     (Current_TCBS (Kernel.CPUs.Current));

   procedure Set_My_Current (TCB : Kernel.Tasks.Thread_Access) is
   begin
      Current_TCBS (Kernel.CPUs.Current) := TCB;
   end Set_My_Current;

   --  Best-first ordering: strictly higher priority wins; at equal
   --  priority a boosted thread (freshly woken) wins; at equal
   --  (priority, boost) the earlier list position wins (FIFO), so
   --  the scan only replaces Best on a strict improvement.
   function Better
     (Cand : Kernel.Tasks.Thread_Control_Block;
      Best : Kernel.Tasks.Thread_Control_Block) return Boolean
   is
   begin
      return Kernel.Tasks.Priority (Cand)
               > Kernel.Tasks.Priority (Best)
        or else (Kernel.Tasks.Priority (Cand)
                   = Kernel.Tasks.Priority (Best)
                 and then Kernel.Tasks.Is_Boosted (Cand)
                 and then not Kernel.Tasks.Is_Boosted (Best));
   end Better;

   --  True when a running hart is executing a thread that TCB
   --  strictly outranks.  Drives the cross-hart preemption IPI:
   --  without it a priority-crossing wake would wait for the
   --  victim hart's next tick (50 ms) or block.
   function Outranks_Running
     (TCB : Kernel.Tasks.Thread_Control_Block) return Boolean
   is
      Cur : Kernel.Tasks.Thread_Access;
   begin
      for CPU in Current_TCBS'Range loop
         Cur := Current_TCBS (CPU);
         if Cur /= null
           and then Kernel.Tasks.State (Cur.all) = Kernel.Tasks.Running
           and then Kernel.Tasks.Priority (TCB)
                      > Kernel.Tasks.Priority (Cur.all)
         then
            return True;
         end if;
      end loop;
      return False;
   end Outranks_Running;

   --  Detach TCB from the ready list.  Caller must know TCB is
   --  linked (Is_Queued).
   procedure Unlink_Ready (TCB : Kernel.Tasks.Thread_Access) is
      P : constant Kernel.Tasks.Thread_Access :=
        Kernel.Tasks.Ready_Prev (TCB.all);
      N : constant Kernel.Tasks.Thread_Access :=
        Kernel.Tasks.Ready_Next (TCB.all);
   begin
      if P /= null then
         Kernel.Tasks.Set_Ready_Next (P.all, N);
      else
         Ready_Head := N;
      end if;
      if N /= null then
         Kernel.Tasks.Set_Ready_Prev (N.all, P);
      else
         Ready_Tail := P;
      end if;
      Kernel.Tasks.Set_Ready_Next (TCB.all, null);
      Kernel.Tasks.Set_Ready_Prev (TCB.all, null);
      Kernel.Tasks.Set_Queued (TCB.all, False);
      Ready_N := Ready_N - 1;
   end Unlink_Ready;

   procedure Push
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status;
      Notify : Boolean := True;
      Boost  : Boolean := False)
   is
      Was_Empty : constant Boolean := Ready_Head = null;
   begin
      if TCB = null
        or else Kernel.Tasks.State (TCB.all) = Kernel.Tasks.Dead
      then
         Result := Invalid_Task;
         return;
      end if;

      if Kernel.Tasks.Is_Queued (TCB.all) then
         Result := Ok;
         return;
      end if;

      --  Boosted threads (freshly woken by IPC/notification, or
      --  preempted while still boosted) jump the queue: a CPU hog
      --  then only runs when nobody interactive is ready.  The
      --  boost orders WITHIN a priority class; a strictly higher
      --  priority elsewhere still wins the pop.
      if Boost then
         Kernel.Tasks.Set_Ready_Prev (TCB.all, null);
         Kernel.Tasks.Set_Ready_Next (TCB.all, Ready_Head);
         if Ready_Head /= null then
            Kernel.Tasks.Set_Ready_Prev (Ready_Head.all, TCB);
         else
            Ready_Tail := TCB;
         end if;
         Ready_Head := TCB;
      else
         Kernel.Tasks.Set_Ready_Next (TCB.all, null);
         Kernel.Tasks.Set_Ready_Prev (TCB.all, Ready_Tail);
         if Ready_Tail /= null then
            Kernel.Tasks.Set_Ready_Next (Ready_Tail.all, TCB);
         else
            Ready_Head := TCB;
         end if;
         Ready_Tail := TCB;
      end if;
      Kernel.Tasks.Set_Queued (TCB.all, True);
      Ready_N := Ready_N + 1;

      --  Empty -> nonempty: an idle hart may be sleeping in wfi;
      --  IPI it so it reschedules promptly.  Priority crossing: a
      --  running hart whose thread TCB outranks must preempt now,
      --  not at its next tick.  Skipped for Yield's own requeue
      --  (the same hart pops again immediately).
      if Notify
        and then (Was_Empty or else Outranks_Running (TCB.all))
      then
         Kernel.CPUs.Notify_Work;
      end if;

      Result := Ok;
   end Push;

   --  Insert a thread into the sleep queue keeping ascending-
   --  deadline order.  Caller must have already set the thread's
   --  sleep deadline.
   procedure Insert_Sleeper (TCB : Kernel.Tasks.Thread_Access) is
      Deadline : constant U64 := Kernel.Tasks.Sleep_Deadline (TCB.all);
      Prev     : Kernel.Tasks.Thread_Access := null;
      Cur      : Kernel.Tasks.Thread_Access := Sleep_Head;
   begin
      --  New sleepers go AFTER existing equals (FIFO among equal
      --  deadlines, matching the old array's shift-insert).
      while Cur /= null
        and then Kernel.Tasks.Sleep_Deadline (Cur.all) <= Deadline
      loop
         Prev := Cur;
         Cur := Kernel.Tasks.Sleep_Next (Cur.all);
      end loop;

      Kernel.Tasks.Set_Sleep_Prev (TCB.all, Prev);
      Kernel.Tasks.Set_Sleep_Next (TCB.all, Cur);
      if Prev /= null then
         Kernel.Tasks.Set_Sleep_Next (Prev.all, TCB);
      else
         Sleep_Head := TCB;
      end if;
      if Cur /= null then
         Kernel.Tasks.Set_Sleep_Prev (Cur.all, TCB);
      end if;
   end Insert_Sleeper;

   --  Remove a thread from the sleep queue if present.  Safe to
   --  call when the thread is not sleeping (walk-and-compare;
   --  sleep lists are short and this runs on death/wake paths).
   procedure Remove_Sleeper (TCB : Kernel.Tasks.Thread_Access) is
      Cur  : Kernel.Tasks.Thread_Access := Sleep_Head;
      Prev : Kernel.Tasks.Thread_Access := null;
   begin
      while Cur /= null loop
         if Cur = TCB then
            declare
               N : constant Kernel.Tasks.Thread_Access :=
                 Kernel.Tasks.Sleep_Next (Cur.all);
            begin
               if Prev /= null then
                  Kernel.Tasks.Set_Sleep_Next (Prev.all, N);
               else
                  Sleep_Head := N;
               end if;
               if N /= null then
                  Kernel.Tasks.Set_Sleep_Prev (N.all, Prev);
               end if;
               Kernel.Tasks.Set_Sleep_Next (Cur.all, null);
               Kernel.Tasks.Set_Sleep_Prev (Cur.all, null);
            end;
            return;
         end if;
         Prev := Cur;
         Cur := Kernel.Tasks.Sleep_Next (Cur.all);
      end loop;
   end Remove_Sleeper;

   procedure Pop
     (TCB    : out Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
      Best : Kernel.Tasks.Thread_Access := null;
      Cand : Kernel.Tasks.Thread_Access := Ready_Head;
      Next : Kernel.Tasks.Thread_Access;
   begin
      --  One pass: unlink null/dead entries (the lazy GC the old
      --  array did while compacting) and find the best thread.
      while Cand /= null loop
         Next := Kernel.Tasks.Ready_Next (Cand.all);
         if Kernel.Tasks.State (Cand.all) = Kernel.Tasks.Dead then
            Unlink_Ready (Cand);
         elsif Best = null or else Better (Cand.all, Best.all) then
            Best := Cand;
         end if;
         Cand := Next;
      end loop;

      if Best = null then
         TCB := null;
         Result := Queue_Empty;
         return;
      end if;

      Unlink_Ready (Best);
      --  The boost is POSITIONAL, not a property of the thread:
      --  the old ring spent it with one head-insert, after which a
      --  yielded thread tail-pushed like everyone else.  Consume
      --  it here or a woken-then-yielding thread (a reap poll
      --  storm) keeps winning the scan and starves the queue.
      Kernel.Tasks.Set_Boosted (Best.all, False);
      TCB := Best;
      Result := Ok;
   end Pop;

   procedure Initialize is
   begin
      Ready_Head := null;
      Ready_Tail := null;
      Ready_N := 0;
      Sleep_Head := null;
      Current_TCBS := (others => null);
   end Initialize;

   procedure Add_Task
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
   begin
      if TCB = null then
         Result := Invalid_Task;
         return;
      end if;

      Kernel.Tasks.Set_State (TCB.all, Kernel.Tasks.Ready);
      Push (TCB, Result);
   end Add_Task;

   procedure Set_Current
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
   begin
      if TCB = null then
         Result := Invalid_Task;
         return;
      end if;

      Set_My_Current (TCB);
      Kernel.Tasks.Set_Queued (TCB.all, False);
      Kernel.Tasks.Set_State (TCB.all, Kernel.Tasks.Running);

      Result := Ok;
   end Set_Current;

   function Current return Kernel.Tasks.Thread_Access is
   begin
      return My_Current;
   end Current;

   procedure Current_CPU_Of
     (TCB   : Kernel.Tasks.Thread_Access;
      Found : out Boolean;
      CPU   : out Kernel.CPUs.CPU_Index)
   is
   begin
      Found := False;
      CPU   := Kernel.CPUs.CPU_Index'First;
      for C in Current_TCBS'Range loop
         if Current_TCBS (C) = TCB then
            Found := True;
            CPU   := C;
            return;
         end if;
      end loop;
   end Current_CPU_Of;

   --  True when a queued thread strictly outranks this hart's
   --  running thread.  Checked at syscall exit and on the
   --  preemption IPI so a priority-crossing wake takes over the
   --  hart immediately instead of waiting for the 50 ms tick.
   function Should_Preempt return Boolean is
      Cur  : constant Kernel.Tasks.Thread_Access := My_Current;
      Cand : Kernel.Tasks.Thread_Access;
   begin
      if Cur = null
        or else Kernel.Tasks.State (Cur.all) /= Kernel.Tasks.Running
      then
         return False;
      end if;

      Cand := Ready_Head;
      while Cand /= null loop
         if Kernel.Tasks.State (Cand.all) /= Kernel.Tasks.Dead
           and then Kernel.Tasks.Priority (Cand.all)
                      > Kernel.Tasks.Priority (Cur.all)
         then
            return True;
         end if;
         Cand := Kernel.Tasks.Ready_Next (Cand.all);
      end loop;
      return False;
   end Should_Preempt;

   --  True when a boosted (freshly woken) thread waits in the ready
   --  queue and this hart's running thread is unboosted and no
   --  higher in priority.  On UP there is no IPI to deliver a wake
   --  (Kernel.CPUs.Notify_Work no-ops with one hart), so without an
   --  explicit check a driver woken by its IRQ sits behind a CPU
   --  hog for the rest of the 50 ms quantum — the Spin canary then
   --  costs real wall time per device round trip.  Checked at
   --  external-interrupt exit; Handle_Preemption no-ops for
   --  kernel/idle traps.  Boost stays positional: the pop consumes
   --  it, so a preempted hog simply resumes at the next tick.
   function Should_Boost_Preempt return Boolean is
      Cur  : constant Kernel.Tasks.Thread_Access := My_Current;
      Cand : Kernel.Tasks.Thread_Access;
   begin
      if Cur = null
        or else Kernel.Tasks.State (Cur.all) /= Kernel.Tasks.Running
        or else Kernel.Tasks.Is_Boosted (Cur.all)
      then
         return False;
      end if;

      Cand := Ready_Head;
      while Cand /= null loop
         if Kernel.Tasks.State (Cand.all) /= Kernel.Tasks.Dead
           and then Kernel.Tasks.Is_Boosted (Cand.all)
           and then Kernel.Tasks.Priority (Cand.all)
                      >= Kernel.Tasks.Priority (Cur.all)
         then
            return True;
         end if;
         Cand := Kernel.Tasks.Ready_Next (Cand.all);
      end loop;
      return False;
   end Should_Boost_Preempt;

   procedure Yield (Result : out Status) is
      Next : Kernel.Tasks.Thread_Access;
   begin
      if My_Current /= null
        and then Kernel.Tasks.State (My_Current.all) = Kernel.Tasks.Running
      then
         Kernel.Tasks.Set_State (My_Current.all, Kernel.Tasks.Ready);
         Push (My_Current, Result, Notify => False);
         if Result /= Ok then
            return;
         end if;
      end if;

      Pop (Next, Result);
      if Result = Queue_Empty then
         if My_Current /= null
           and then Kernel.Tasks.State (My_Current.all) = Kernel.Tasks.Running
         then
            Result := Ok;
         else
            Set_My_Current (null);
         end if;
         return;
      elsif Result /= Ok then
         return;
      end if;

      Set_My_Current (Next);
      Kernel.Tasks.Set_Queued (My_Current.all, False);
      Kernel.Tasks.Set_State (My_Current.all, Kernel.Tasks.Running);
      Result := Ok;
   end Yield;

   procedure Block_Current
     (New_State : Kernel.Tasks.Thread_State;
      Result    : out Status)
   is
   begin
      if My_Current = null then
         Result := No_Current_Task;
         return;
      end if;

      Kernel.Tasks.Set_State (My_Current.all, New_State);
      --  Voluntary block ends the boost: the next wake re-earns it.
      Kernel.Tasks.Set_Boosted (My_Current.all, False);
      Set_My_Current (null);
      --  No Yield here: every caller (Sleep_Until, Thread_Wait) is
      --  a trap-level path that ends in Schedule_Saved_Context,
      --  which performs the single schedule.  A second Yield popped
      --  the ready-queue head and re-queued it without running it,
      --  starving that thread on every sleep (m72b wedge).
      Result := Ok;
   end Block_Current;

   procedure Exit_Current (Result : out Status) is
   begin
      if My_Current = null then
         Result := No_Current_Task;
         return;
      end if;

      --  A dying thread must leave the sleep queue too (Remove_Thread
      --  already does this for killed siblings); a stale entry would
      --  be popped by the tick handler through a recycled TCB.
      Remove_Sleeper (My_Current);

      Kernel.Tasks.Set_State (My_Current.all, Kernel.Tasks.Dead);
      Kernel.Tasks.Set_Queued (My_Current.all, False);
      Set_My_Current (null);
      Result := Ok;
   end Exit_Current;

   procedure Wake
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
   begin
      if TCB = null then
         Result := Invalid_Task;
         return;
      end if;

      if Kernel.Tasks.State (TCB.all) = Kernel.Tasks.Dead then
         Result := Invalid_Task;
         return;
      elsif Kernel.Tasks.State (TCB.all) = Kernel.Tasks.Running
        or else Kernel.Tasks.State (TCB.all) = Kernel.Tasks.Ready
      then
         Result := Ok;
         return;
      end if;

      if Kernel.Tasks.State (TCB.all) = Kernel.Tasks.Blocked_Sleeping then
         Remove_Sleeper (TCB);
      end if;

      Kernel.Tasks.Set_State (TCB.all, Kernel.Tasks.Ready);
      Kernel.Tasks.Set_Boosted (TCB.all, True);
      Push (TCB, Result, Boost => True);
   end Wake;

   procedure Sleep_Until
     (Deadline : U64;
      Result   : out Status)
   is
      Cur : constant Kernel.Tasks.Thread_Access := My_Current;
      Now : constant U64 := Arch.SBI.Time;
   begin
      if Cur = null then
         Result := No_Current_Task;
         return;
      end if;

      --  Past or equal deadlines return synchronously (Ada semantics
      --  for delay until a time already reached).
      if Deadline <= Now then
         Result := Ok;
         return;
      end if;

      Kernel.Tasks.Set_Sleep_Deadline (Cur.all, Deadline);
      Insert_Sleeper (Cur);
      Arch.SBI.Set_Timer (Next_Timer_Deadline (Now));
      Block_Current (Kernel.Tasks.Blocked_Sleeping, Result);
   end Sleep_Until;

   procedure Check_Sleepers
     (Now           : U64;
      Next_Deadline : out U64)
   is
      TCB         : Kernel.Tasks.Thread_Access;
      Wake_Result : Status;
   begin
      while Sleep_Head /= null
        and then Kernel.Tasks.Sleep_Deadline (Sleep_Head.all) <= Now
      loop
         TCB := Sleep_Head;
         Remove_Sleeper (TCB);
         --  The thread may already have been woken by another path
         --  (e.g., a signal); Wake is a no-op for Ready/Running.
         Wake (TCB, Wake_Result);
      end loop;

      if Sleep_Head = null then
         Next_Deadline := U64'Last;
      else
         Next_Deadline := Kernel.Tasks.Sleep_Deadline (Sleep_Head.all);
      end if;
   end Check_Sleepers;

   function Next_Timer_Deadline (Now : U64) return U64 is
      Next_Sleep : U64;
   begin
      Check_Sleepers (Now, Next_Sleep);
      return U64'Min (Now + Quantum_Interval, Next_Sleep);
   end Next_Timer_Deadline;

   procedure Remove_Thread
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
   begin
      if TCB = null then
         Result := Invalid_Task;
         return;
      end if;

      for CPU in Current_TCBS'Range loop
         if Current_TCBS (CPU) = TCB then
            Current_TCBS (CPU) := null;
         end if;
      end loop;

      --  A dying or forcibly removed thread must leave the sleep queue
      --  too, otherwise it could be woken after its resources are gone.
      Remove_Sleeper (TCB);

      if Kernel.Tasks.Is_Queued (TCB.all) then
         Unlink_Ready (TCB);
      end if;

      Result := Ok;
   end Remove_Thread;

   function Ready_Count return Natural is
   begin
      return Ready_N;
   end Ready_Count;
end Kernel.Scheduler;
