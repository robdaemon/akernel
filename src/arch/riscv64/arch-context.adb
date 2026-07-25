package body Arch.Context is
   procedure Trap_Frame_Save_Context
     (Frame   : System.Address;
      Context : System.Address)
     with Import, Convention => C, External_Name => "trap_frame_save_context";

   procedure Trap_Frame_Load_Context
     (Frame   : System.Address;
      Context : System.Address)
     with Import, Convention => C, External_Name => "trap_frame_load_context";

   procedure Initialize (Context : out Thread_Context) is
   begin
      Context.Trap_Frame := (others => 0);
      Context.Is_Valid := False;
   end Initialize;

   procedure Initialize_User
     (Context : out Thread_Context;
      PC      : U64;
      Stack   : U64)
   is
   begin
      Context.Trap_Frame := (others => 0);
      Context.Trap_Frame (1) := Stack; -- x2/sp
      Context.Trap_Frame (Trap_Frame_PC_Index) := PC;
      Context.Is_Valid := True;
   end Initialize_User;

   function Valid (Context : Thread_Context) return Boolean is
   begin
      return Context.Is_Valid;
   end Valid;

   procedure Save_From_Trap_Frame
     (Context : in out Thread_Context;
      Frame   : System.Address)
   is
   begin
      Trap_Frame_Save_Context (Frame, Context.Trap_Frame'Address);
      Context.Is_Valid := True;
   end Save_From_Trap_Frame;

   procedure Restore_To_Trap_Frame
     (Context : Thread_Context;
      Frame   : System.Address)
   is
   begin
      Trap_Frame_Load_Context (Frame, Context.Trap_Frame'Address);
   end Restore_To_Trap_Frame;
end Arch.Context;
