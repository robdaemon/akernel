with Interfaces;
with System;

package Arch.Context is
   subtype U64 is Interfaces.Unsigned_64;

   type Thread_Context is private;

   procedure Initialize (Context : out Thread_Context);

   procedure Initialize_User
     (Context : out Thread_Context;
      PC      : U64;
      Stack   : U64);

   function Valid (Context : Thread_Context) return Boolean;

   procedure Save_From_Trap_Frame
     (Context : in out Thread_Context;
      Frame   : System.Address);

   procedure Restore_To_Trap_Frame
     (Context : Thread_Context;
      Frame   : System.Address);

private
   Trap_Frame_Word_Count : constant := 34;
   Trap_Frame_PC_Index   : constant := Trap_Frame_Word_Count;

   type Trap_Frame_Word_Array is array
     (Natural range 0 .. Trap_Frame_PC_Index) of U64;

   type Thread_Context is record
      Trap_Frame : aliased Trap_Frame_Word_Array;
      Is_Valid   : Boolean;
   end record;
end Arch.Context;
