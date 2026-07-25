with Kernel.Capabilities;
with System;

package Kernel.Tasks is
   type Task_Id is new Natural;

   type Task_State is
     (Ready,
      Running,
      Blocked_Send,
      Blocked_Receive,
      Blocked_IRQ,
      Dead);

   type Task_Control_Block is private;
   type Task_Access is access all Task_Control_Block;

   procedure Initialize
     (TCB : out Task_Control_Block;
      Id  : Task_Id);

   function Id (TCB : Task_Control_Block) return Task_Id;

   function State (TCB : Task_Control_Block) return Task_State;

   function Address_Space_Root (TCB : Task_Control_Block)
      return Kernel.Capabilities.U64;

   procedure Set_Address_Space_Root
     (TCB  : in out Task_Control_Block;
      Root : Kernel.Capabilities.U64);

   function Context_Address (TCB : in out Task_Control_Block)
      return System.Address;

   procedure Initialize_Context
     (TCB   : in out Task_Control_Block;
      PC    : Kernel.Capabilities.U64;
      Stack : Kernel.Capabilities.U64);

   function Has_Context (TCB : Task_Control_Block) return Boolean;

   procedure Set_State
     (TCB       : in out Task_Control_Block;
      New_State : Task_State);

   procedure Insert_Cap
     (TCB    : in out Task_Control_Block;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status;
      Cap    : out Kernel.Capabilities.Handle);

   procedure Insert_Cap_At
     (TCB    : in out Task_Control_Block;
      Cap    : Kernel.Capabilities.Handle;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status);

   procedure Lookup_Cap
     (TCB       : Task_Control_Block;
      Cap       : Kernel.Capabilities.Handle;
      Result    : out Kernel.Capabilities.Status;
      Out_Entry : out Kernel.Capabilities.Cap_Entry);

private
   type Register_Array is array (Natural range 0 .. 30)
     of Kernel.Capabilities.U64;

   type Task_Context is record
      Registers : Register_Array;
      PC        : Kernel.Capabilities.U64;
      Valid     : Boolean;
   end record;

   type Task_Control_Block is record
      Identifier : Task_Id;
      Status     : Task_State;
      Root       : Kernel.Capabilities.U64;
      Context    : aliased Task_Context;
      Caps       : Kernel.Capabilities.Cap_Table;
   end record;
end Kernel.Tasks;
