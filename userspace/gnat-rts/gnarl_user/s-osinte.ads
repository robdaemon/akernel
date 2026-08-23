------------------------------------------------------------------------------
--                                                                          --
--                  GNAT RUN-TIME LIBRARY (GNARL) COMPONENTS                --
--                                                                          --
--                    S Y S T E M . O S _ I N T E R F A C E                 --
--                                                                          --
--                                   S p e c                                --
--                                                                          --
--                      Akernel Ravenscar port (M67b)                       --
--                                                                          --
------------------------------------------------------------------------------

--  Minimal System.OS_Interface for the Akernel userspace Ravenscar runtime.
--  This version sits directly on top of the Akernel syscall layer rather
--  than System.BB.

pragma Restrictions (No_Elaboration_Code);

with Interfaces;
with System.Multiprocessors;
with System.Storage_Elements;

package System.OS_Interface is
   pragma Preelaborate;

   ----------------
   -- Interrupts --
   ----------------

   subtype Interrupt_Range is Integer range 0 .. 0;
   subtype Interrupt_ID is Integer range 0 .. 0;
   subtype Any_Interrupt_ID is Integer range -1 .. 0;

   No_Interrupt : constant Any_Interrupt_ID := -1;

   type Interrupt_Handler is access procedure (Id : Interrupt_ID);

   procedure Attach_Handler
     (Handler : Interrupt_Handler;
      Id      : Interrupt_ID;
      PO_Prio : Interrupt_Priority);

   procedure Power_Down;

   ----------
   -- Time --
   ----------

   subtype Time is Interfaces.Unsigned_64;
   subtype Time_Span is Interfaces.Integer_64;

   Ticks_Per_Second : constant := 10_000_000;

   function Clock return Time;
   procedure Delay_Until (T : Time);

   -------------
   -- Threads --
   -------------

   type Thread_Descriptor;
   type Thread_Id is access all Thread_Descriptor;

   Null_Thread_Id : constant Thread_Id := null;

   type Thread_Descriptor is record
      Cap : Interfaces.Unsigned_64;
   end record;

   Lwp_Self : constant System.Address := System.Null_Address;

   procedure Initialize
     (Environment_Thread : Thread_Id;
      Main_Priority      : System.Any_Priority);

   procedure Initialize_Slave
     (Idle_Thread   : Thread_Id;
      Idle_Priority : Integer;
      Stack_Address : System.Address;
      Stack_Size    : System.Storage_Elements.Storage_Offset);

   procedure Thread_Create
     (Id            : Thread_Id;
      Code          : System.Address;
      Arg           : System.Address;
      Priority      : Integer;
      Base_CPU      : System.Multiprocessors.CPU_Range;
      Stack_Address : System.Address;
      Stack_Size    : System.Storage_Elements.Storage_Offset);

   function Thread_Self return Thread_Id;

   procedure Set_ATCB (Id : Thread_Id; ATCB : System.Address);
   function Get_ATCB return System.Address;

   procedure Set_Priority (Priority : Integer);
   function Get_Priority (Id : Thread_Id) return Integer;

   procedure Sleep;
   procedure Wakeup (Id : Thread_Id);

   function Get_Affinity (Id : Thread_Id) return Multiprocessors.CPU_Range;
   function Get_CPU (Id : Thread_Id) return Multiprocessors.CPU;

   function Current_Priority
     (CPU_Id : Multiprocessors.CPU) return System.Any_Priority;

   function Current_CPU return Multiprocessors.CPU;

end System.OS_Interface;
