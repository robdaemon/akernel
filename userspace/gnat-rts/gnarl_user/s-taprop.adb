------------------------------------------------------------------------------
--                                                                          --
--                  GNAT RUN-TIME LIBRARY (GNARL) COMPONENTS                --
--                                                                          --
--     S Y S T E M . T A S K _ P R I M I T I V E S .O P E R A T I O N S     --
--                                                                          --
--                                  B o d y                                 --
--                                                                          --
--                      Akernel Ravenscar port (M67b)                       --
--                                                                          --
------------------------------------------------------------------------------

--  Minimal System.Task_Primitives.Operations body that maps GNARL onto the
--  Akernel syscall layer through System.OS_Interface.

pragma Restrictions (No_Elaboration_Code);

with Ada.Unchecked_Conversion;
with Interfaces;
with System.Storage_Elements;
with System.Tasking.Debug;

package body System.Task_Primitives.Operations is

   use System.OS_Interface;
   use System.Tasking;

   use type Interfaces.Unsigned_64;

   function To_Address is new
     Ada.Unchecked_Conversion (ST.Task_Id, System.Address);

   function To_Task_Id is new
     Ada.Unchecked_Conversion (System.Address, ST.Task_Id);

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize (Environment_Task : ST.Task_Id) is
   begin
      System.OS_Interface.Initialize
        (Environment_Thread => Environment_Task.Common.LL.Thread,
         Main_Priority      => Environment_Task.Common.Base_Priority);

      --  Set the ATCB association for the environment task.
      System.OS_Interface.Set_ATCB
        (Environment_Task.Common.LL.Thread,
         To_Address (Environment_Task));
   end Initialize;

   ---------------
   -- Self --
   ---------------

   function Self return ST.Task_Id is
   begin
      return To_Task_Id (System.OS_Interface.Get_ATCB);
   end Self;

   ----------------
   -- Create_Task --
   ----------------

   procedure Create_Task
     (T          : ST.Task_Id;
      Wrapper    : System.Address;
      Stack_Size : System.Parameters.Size_Type;
      Priority   : ST.Extended_Priority;
      Base_CPU   : System.Multiprocessors.CPU_Range;
      Succeeded  : out Boolean)
   is
   begin
      System.OS_Interface.Thread_Create
        (Id            => T.Common.LL.Thread,
         Code          => Wrapper,
         Arg           => To_Address (T),
         Priority      => Integer (Priority),
         Base_CPU      => Base_CPU,
         Stack_Address => T.Common.Compiler_Data.Pri_Stack_Info.Start_Address,
         Stack_Size    =>
           System.Storage_Elements.Storage_Offset (Stack_Size));

      Succeeded := T.Common.LL.Thread.Cap /= 0;
   end Create_Task;

   ----------------
   -- Enter_Task --
   ----------------

   procedure Enter_Task (Self_ID : ST.Task_Id) is
   begin
      Self_ID.Common.LL.Lwp := OSI.Lwp_Self;
      System.Tasking.Debug.Add_Task_Id (Self_ID);
      OSI.Set_ATCB (Self_ID.Common.LL.Thread, To_Address (Self_ID));
      OSI.Set_Priority (Self_ID.Common.Base_Priority);
   end Enter_Task;

   --------------------
   -- Initialize_TCB --
   --------------------

   procedure Initialize_TCB (Self_ID : ST.Task_Id; Succeeded : out Boolean) is
      pragma Unreferenced (Self_ID);
   begin
      Succeeded := True;
   end Initialize_TCB;

   ------------------
   -- Set_Priority --
   ------------------

   procedure Set_Priority (T : ST.Task_Id; Prio : ST.Extended_Priority) is
   begin
      OSI.Set_Priority (Integer (Prio));
      pragma Unreferenced (T);
   end Set_Priority;

   ------------------
   -- Get_Priority --
   ------------------

   function Get_Priority (T : ST.Task_Id) return ST.Extended_Priority is
   begin
      return ST.Extended_Priority (OSI.Get_Priority (T.Common.LL.Thread));
   end Get_Priority;

   ------------------
   -- Get_Affinity --
   ------------------

   function Get_Affinity
     (T : ST.Task_Id) return System.Multiprocessors.CPU_Range
   is
   begin
      return OSI.Get_Affinity (T.Common.LL.Thread);
   end Get_Affinity;

   --------------
   -- Get_CPU --
   --------------

   function Get_CPU (T : ST.Task_Id) return System.Multiprocessors.CPU is
   begin
      return OSI.Get_CPU (T.Common.LL.Thread);
   end Get_CPU;

   ------------------
   -- Get_Thread_Id --
   ------------------

   function Get_Thread_Id (T : ST.Task_Id) return OSI.Thread_Id is
   begin
      return T.Common.LL.Thread;
   end Get_Thread_Id;

   -------------------
   -- Monotonic_Clock --
   -------------------

   function Monotonic_Clock return Time is
   begin
      return Time (OSI.Clock);
   end Monotonic_Clock;

   -----------
   -- Sleep --
   -----------

   procedure Sleep
     (Self_ID : ST.Task_Id;
      Reason  : System.Tasking.Task_States)
   is
      pragma Unreferenced (Self_ID);
   begin
      --  For task termination we exit the underlying kernel thread.
      --  Other sleeps are not expected in this minimal runtime.
      if Reason = Terminated then
         OSI.Sleep;
      else
         OSI.Delay_Until (OSI.Time (Interfaces.Unsigned_64 (OSI.Clock) + 1));
      end if;
   end Sleep;

   ----------------
   -- Delay_Until --
   ----------------

   procedure Delay_Until (Abs_Time : Time) is
   begin
      OSI.Delay_Until (OSI.Time (Abs_Time));
   end Delay_Until;

   -------------
   -- Wakeup --
   -------------

   procedure Wakeup
     (T      : ST.Task_Id;
      Reason : System.Tasking.Task_States)
   is
      pragma Unreferenced (Reason);
   begin
      OSI.Wakeup (T.Common.LL.Thread);
   end Wakeup;

   -------------------
   -- Is_Task_Context --
   -------------------

   function Is_Task_Context return Boolean is
   begin
      return True;
   end Is_Task_Context;

end System.Task_Primitives.Operations;
