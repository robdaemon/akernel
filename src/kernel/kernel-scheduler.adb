with Kernel.CPUs;

package body Kernel.Scheduler is
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;

   type Queue_Index is range 0 .. Max_Tasks - 1;
   type Ready_Queue is array (Queue_Index) of Kernel.Tasks.Thread_Access;

   Queue : Ready_Queue := (others => null);
   Head  : Queue_Index := Queue_Index'First;
   Tail  : Queue_Index := Queue_Index'First;
   Count : Natural range 0 .. Max_Tasks := 0;

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

   procedure Push
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status;
      Notify : Boolean := True;
      Boost  : Boolean := False)
   is
      Was_Empty : constant Boolean := Count = 0;
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

      if Count = Max_Tasks then
         Result := Queue_Full;
         return;
      end if;

      --  Boosted threads (freshly woken by IPC/notification, or
      --  preempted while still boosted) jump the queue: a CPU hog
      --  then only runs when nobody interactive is ready.
      if Boost then
         if Head = Queue_Index'First then
            Head := Queue_Index'Last;
         else
            Head := Queue_Index'Pred (Head);
         end if;
         Queue (Head) := TCB;
      else
         Queue (Tail) := TCB;
         if Tail = Queue_Index'Last then
            Tail := Queue_Index'First;
         else
            Tail := Queue_Index'Succ (Tail);
         end if;
      end if;
      Kernel.Tasks.Set_Queued (TCB.all, True);
      Count := Count + 1;

      --  Empty -> nonempty: an idle hart may be sleeping in wfi;
      --  IPI it so it reschedules promptly.  Skipped for Yield's own
      --  requeue (the same hart pops again immediately).
      if Notify and then Was_Empty then
         Kernel.CPUs.Notify_Work;
      end if;

      Result := Ok;
   end Push;

   procedure Pop
     (TCB    : out Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
   begin
      while Count > 0 loop
         TCB := Queue (Head);
         Queue (Head) := null;
         if TCB /= null then
            Kernel.Tasks.Set_Queued (TCB.all, False);
         end if;
         if Head = Queue_Index'Last then
            Head := Queue_Index'First;
         else
            Head := Queue_Index'Succ (Head);
         end if;
         Count := Count - 1;

         if TCB /= null
           and then Kernel.Tasks.State (TCB.all) /= Kernel.Tasks.Dead
         then
            Result := Ok;
            return;
         end if;
      end loop;

      TCB := null;
      Result := Queue_Empty;
   end Pop;

   procedure Initialize is
   begin
      Queue := (others => null);
      Head := Queue_Index'First;
      Tail := Queue_Index'First;
      Count := 0;
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
      Yield (Result);
   end Block_Current;

   procedure Exit_Current (Result : out Status) is
   begin
      if My_Current = null then
         Result := No_Current_Task;
         return;
      end if;

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

      Kernel.Tasks.Set_State (TCB.all, Kernel.Tasks.Ready);
      Kernel.Tasks.Set_Boosted (TCB.all, True);
      Push (TCB, Result, Boost => True);
   end Wake;

   procedure Remove_Thread
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
      New_Queue : Ready_Queue := (others => null);
      New_Tail  : Queue_Index := Queue_Index'First;
      New_Count : Natural range 0 .. Max_Tasks := 0;
      Scan      : Queue_Index := Head;
      Candidate : Kernel.Tasks.Thread_Access;
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

      for I in Natural range 1 .. Count loop
         Candidate := Queue (Scan);
         Queue (Scan) := null;

         if Candidate /= null then
            Kernel.Tasks.Set_Queued (Candidate.all, False);

            if Candidate /= TCB
              and then Kernel.Tasks.State (Candidate.all) /= Kernel.Tasks.Dead
            then
               New_Queue (New_Tail) := Candidate;
               Kernel.Tasks.Set_Queued (Candidate.all, True);
               if New_Tail = Queue_Index'Last then
                  New_Tail := Queue_Index'First;
               else
                  New_Tail := Queue_Index'Succ (New_Tail);
               end if;
               New_Count := New_Count + 1;
            end if;
         end if;

         if Scan = Queue_Index'Last then
            Scan := Queue_Index'First;
         else
            Scan := Queue_Index'Succ (Scan);
         end if;
      end loop;

      Queue := New_Queue;
      Head := Queue_Index'First;
      Tail := New_Tail;
      Count := New_Count;
      Result := Ok;
   end Remove_Thread;

   function Ready_Count return Natural is
   begin
      return Count;
   end Ready_Count;
end Kernel.Scheduler;
