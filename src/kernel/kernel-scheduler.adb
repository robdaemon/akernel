package body Kernel.Scheduler is
   use type Kernel.Tasks.Task_Access;
   use type Kernel.Tasks.Task_State;

   type Queue_Index is range 0 .. Max_Tasks - 1;
   type Ready_Queue is array (Queue_Index) of Kernel.Tasks.Task_Access;

   Queue : Ready_Queue := (others => null);
   Head  : Queue_Index := Queue_Index'First;
   Tail  : Queue_Index := Queue_Index'First;
   Count : Natural range 0 .. Max_Tasks := 0;

   Current_TCB : Kernel.Tasks.Task_Access := null;

   procedure Push
     (TCB    : Kernel.Tasks.Task_Access;
      Result : out Status)
   is
   begin
      if TCB = null then
         Result := Invalid_Task;
         return;
      end if;

      if Count = Max_Tasks then
         Result := Queue_Full;
         return;
      end if;

      Queue (Tail) := TCB;
      if Tail = Queue_Index'Last then
         Tail := Queue_Index'First;
      else
         Tail := Queue_Index'Succ (Tail);
      end if;
      Count := Count + 1;
      Result := Ok;
   end Push;

   procedure Pop
     (TCB    : out Kernel.Tasks.Task_Access;
      Result : out Status)
   is
   begin
      if Count = 0 then
         TCB := null;
         Result := Queue_Empty;
         return;
      end if;

      TCB := Queue (Head);
      Queue (Head) := null;
      if Head = Queue_Index'Last then
         Head := Queue_Index'First;
      else
         Head := Queue_Index'Succ (Head);
      end if;
      Count := Count - 1;
      Result := Ok;
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
     (TCB    : Kernel.Tasks.Task_Access;
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
     (TCB    : Kernel.Tasks.Task_Access;
      Result : out Status)
   is
   begin
      if TCB = null then
         Result := Invalid_Task;
         return;
      end if;

      Current_TCB := TCB;
      Kernel.Tasks.Set_State (Current_TCB.all, Kernel.Tasks.Running);
      Result := Ok;
   end Set_Current;

   function Current return Kernel.Tasks.Task_Access is
   begin
      return Current_TCB;
   end Current;

   procedure Yield (Result : out Status) is
      Next : Kernel.Tasks.Task_Access;
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
         if Current_TCB /= null then
            Kernel.Tasks.Set_State (Current_TCB.all, Kernel.Tasks.Running);
            Result := Ok;
         end if;
         return;
      elsif Result /= Ok then
         return;
      end if;

      Current_TCB := Next;
      Kernel.Tasks.Set_State (Current_TCB.all, Kernel.Tasks.Running);
      Result := Ok;
   end Yield;

   procedure Block_Current
     (New_State : Kernel.Tasks.Task_State;
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

   procedure Wake
     (TCB    : Kernel.Tasks.Task_Access;
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
      end if;

      Kernel.Tasks.Set_State (TCB.all, Kernel.Tasks.Ready);
      Push (TCB, Result);
   end Wake;

   function Ready_Count return Natural is
   begin
      return Count;
   end Ready_Count;
end Kernel.Scheduler;
