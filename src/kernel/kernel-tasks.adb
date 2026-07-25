package body Kernel.Tasks is
   procedure Initialize
     (TCB : out Task_Control_Block;
      Id  : Task_Id)
   is
   begin
      TCB.Identifier := Id;
      TCB.Status := Ready;
      TCB.Root := 0;
      TCB.Context.Registers := (others => 0);
      TCB.Context.PC := 0;
      TCB.Context.Valid := False;
      Kernel.Capabilities.Initialize (TCB.Caps);
   end Initialize;

   function Id (TCB : Task_Control_Block) return Task_Id is
   begin
      return TCB.Identifier;
   end Id;

   function State (TCB : Task_Control_Block) return Task_State is
   begin
      return TCB.Status;
   end State;

   function Address_Space_Root (TCB : Task_Control_Block)
      return Kernel.Capabilities.U64
   is
   begin
      return TCB.Root;
   end Address_Space_Root;

   procedure Set_Address_Space_Root
     (TCB  : in out Task_Control_Block;
      Root : Kernel.Capabilities.U64)
   is
   begin
      TCB.Root := Root;
   end Set_Address_Space_Root;

   function Context_Address (TCB : in out Task_Control_Block)
      return System.Address
   is
   begin
      return TCB.Context'Address;
   end Context_Address;

   procedure Initialize_Context
     (TCB   : in out Task_Control_Block;
      PC    : Kernel.Capabilities.U64;
      Stack : Kernel.Capabilities.U64)
   is
   begin
      TCB.Context.Registers := (others => 0);
      TCB.Context.Registers (1) := Stack; -- x2/sp
      TCB.Context.PC := PC;
      TCB.Context.Valid := True;
   end Initialize_Context;

   function Has_Context (TCB : Task_Control_Block) return Boolean is
   begin
      return TCB.Context.Valid;
   end Has_Context;

   procedure Set_State
     (TCB       : in out Task_Control_Block;
      New_State : Task_State)
   is
   begin
      TCB.Status := New_State;
   end Set_State;

   procedure Insert_Cap
     (TCB    : in out Task_Control_Block;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status;
      Cap    : out Kernel.Capabilities.Handle)
   is
   begin
      Kernel.Capabilities.Insert
        (Table  => TCB.Caps,
         Kind   => Kind,
         Object => Object,
         Rights => Rights,
         Badge  => Badge,
         Result => Result,
         Cap    => Cap);
   end Insert_Cap;

   procedure Insert_Cap_At
     (TCB    : in out Task_Control_Block;
      Cap    : Kernel.Capabilities.Handle;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status)
   is
   begin
      Kernel.Capabilities.Insert_At
        (Table  => TCB.Caps,
         Cap    => Cap,
         Kind   => Kind,
         Object => Object,
         Rights => Rights,
         Badge  => Badge,
         Result => Result);
   end Insert_Cap_At;

   procedure Lookup_Cap
     (TCB       : Task_Control_Block;
      Cap       : Kernel.Capabilities.Handle;
      Result    : out Kernel.Capabilities.Status;
      Out_Entry : out Kernel.Capabilities.Cap_Entry)
   is
   begin
      Kernel.Capabilities.Lookup
        (Table     => TCB.Caps,
         Cap       => Cap,
         Result    => Result,
         Out_Entry => Out_Entry);
   end Lookup_Cap;
end Kernel.Tasks;
