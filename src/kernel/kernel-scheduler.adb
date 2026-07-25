package body Kernel.Scheduler is
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;

   type Queue_Index is range 0 .. Max_Tasks - 1;
   type Ready_Queue is array (Queue_Index) of Kernel.Tasks.Thread_Access;

   Queue : Ready_Queue := (others => null);
   Head  : Queue_Index := Queue_Index'First;
   Tail  : Queue_Index := Queue_Index'First;
   Count : Natural range 0 .. Max_Tasks := 0;

   Current_TCB : Kernel.Tasks.Thread_Access := null;

   procedure Push
     (TCB    : Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
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

      Queue (Tail) := TCB;
      Kernel.Tasks.Set_Queued (TCB.all, True);
      if Tail = Queue_Index'Last then
         Tail := Queue_Index'First;
      else
         Tail := Queue_Index'Succ (Tail);
      end if;
      Count := Count + 1;
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
      Current_TCB := null;
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

      Current_TCB := TCB;
      Kernel.Tasks.Set_Queued (Current_TCB.all, False);
      Kernel.Tasks.Set_State (Current_TCB.all, Kernel.Tasks.Running);
      Result := Ok;
   end Set_Current;

   function Current return Kernel.Tasks.Thread_Access is
   begin
      return Current_TCB;
   end Current;

   procedure Yield (Result : out Status) is
      Next : Kernel.Tasks.Thread_Access;
   begin
      if Current_TCB /= null
        and then Kernel.Tasks.State (Current_TCB.all) = Kernel.Tasks.Running
      then
         Kernel.Tasks.Set_State (Current_TCB.all, Kernel.Tasks.Ready);
         Push (Current_TCB, Result);
         if Result /= Ok then
            return;
         end if;
      end if;

      Pop (Next, Result);
      if Result = Queue_Empty then
         if Current_TCB /= null
           and then Kernel.Tasks.State (Current_TCB.all) = Kernel.Tasks.Running
         then
            Result := Ok;
         else
            Current_TCB := null;
         end if;
         return;
      elsif Result /= Ok then
         return;
      end if;

      Current_TCB := Next;
      Kernel.Tasks.Set_Queued (Current_TCB.all, False);
      Kernel.Tasks.Set_State (Current_TCB.all, Kernel.Tasks.Running);
      Result := Ok;
   end Yield;

   procedure Block_Current
     (New_State : Kernel.Tasks.Thread_State;
      Result    : out Status)
   is
   begin
      if Current_TCB = null then
         Result := No_Current_Task;
         return;
      end if;

      Kernel.Tasks.Set_State (Current_TCB.all, New_State);
      Current_TCB := null;
      Yield (Result);
   end Block_Current;

   procedure Exit_Current (Result : out Status) is
   begin
      if Current_TCB = null then
         Result := No_Current_Task;
         return;
      end if;

      Kernel.Tasks.Set_State (Current_TCB.all, Kernel.Tasks.Dead);
      Kernel.Tasks.Set_Queued (Current_TCB.all, False);
      Current_TCB := null;
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
      Push (TCB, Result);
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

      if Current_TCB = TCB then
         Current_TCB := null;
      end if;

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
