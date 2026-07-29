with Interfaces;
with System;

package Arch.Context is
   subtype U64 is Interfaces.Unsigned_64;

   type Thread_Context is private;

   procedure Initialize (Context : out Thread_Context);

   procedure Initialize_User
     (Context   : out Thread_Context;
      PC        : U64;
      Stack     : U64;
      User_Satp : U64);

   function Valid (Context : Thread_Context) return Boolean;

   --  Overwrite the saved a0 (x10) in a blocked thread's context.
   --  Used by IPC wakers to deliver a syscall result status; the
   --  value surfaces when the thread is rescheduled and its context
   --  is restored into its kernel-stack trap frame.
   procedure Set_Saved_Result (Context : in out Thread_Context; Value : U64);

   procedure Save_From_Trap_Frame
     (Context : in out Thread_Context;
      Frame   : System.Address);

   procedure Restore_To_Trap_Frame
     (Context : Thread_Context;
      Frame   : System.Address);

private
   --  Frame words 0..30 hold x1..x31, word 31 sepc, word 32 satp,
   --  word 33 pad.  Matches the trampoline frame in startup.s.
   Trap_Frame_Word_Count : constant := 34;
   Trap_Frame_PC_Index   : constant := 31;
   Trap_Frame_Satp_Index : constant := 32;
   Trap_Frame_Last_Index : constant := Trap_Frame_Word_Count - 1;
   Trap_Frame_A0_Index   : constant := 9;  --  x10

   type Trap_Frame_Word_Array is array
     (Natural range 0 .. Trap_Frame_Last_Index) of U64;

   type Thread_Context is record
      Trap_Frame : aliased Trap_Frame_Word_Array;
      Is_Valid   : Boolean;
   end record;
end Arch.Context;
