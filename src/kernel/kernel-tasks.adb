with Kernel.Objects;
with System.Storage_Elements;

package body Kernel.Tasks is
   use type Kernel.Capabilities.Status;
   use type Kernel.Capabilities.Object_Kind;
   use type Kernel.Capabilities.U64;

   Address_Space_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => True,
      Write    => False,
      Execute  => False,
      Map      => True,
      Send     => False,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => False,
      Manage   => True);

   function To_Address
     (Value : Kernel.Capabilities.U64) return System.Address
   is
   begin
      return System'To_Address
        (System.Storage_Elements.Integer_Address (Value));
   end To_Address;

   function To_U64 (Address : System.Address) return Kernel.Capabilities.U64 is
   begin
      return Kernel.Capabilities.U64
        (System.Storage_Elements.To_Integer (Address));
   end To_U64;

   procedure Initialize_Process
     (PCB : out Process_Control_Block;
      Id  : Process_Id)
   is
   begin
      PCB.Identifier := Id;
      PCB.Spawner := 0;
      PCB.Root := 0;
      PCB.Status := Process_Initializing;
      Kernel.Capabilities.Initialize (PCB.Caps);
   end Initialize_Process;

   procedure Initialize_Thread
     (TCB     : out Thread_Control_Block;
      Id      : Thread_Id;
      Process : not null Process_Access)
   is
   begin
      TCB.Identifier := Id;
      TCB.Status := Ready;
      TCB.Process := Process;
      TCB.Kernel_Stack_Top := 0;
      TCB.IPC_Buffer := 0;
      TCB.Awaiting_Reply := False;
      TCB.Reply_Wanted   := False;
      TCB.Queue_Next := null;
      TCB.Call_Badge := 0;
      Arch.Context.Initialize (TCB.Context);
      TCB.Queued := False;
      TCB.Boosted := False;
      TCB.Bound_Ntfn := System.Null_Address;
      TCB.Recv_EP := System.Null_Address;
      TCB.Debug_Len := 0;
   end Initialize_Thread;

   function Id (TCB : Thread_Control_Block) return Thread_Id is
   begin
      return TCB.Identifier;
   end Id;

   function Process_Id_Of (PCB : Process_Control_Block) return Process_Id is
   begin
      return PCB.Identifier;
   end Process_Id_Of;

   function Spawner_Id (PCB : Process_Control_Block) return Process_Id is
   begin
      return PCB.Spawner;
   end Spawner_Id;

   procedure Set_Spawner_Id
     (PCB     : in out Process_Control_Block;
      Spawner : Process_Id)
   is
   begin
      PCB.Spawner := Spawner;
   end Set_Spawner_Id;

   function Owning_Process
     (TCB : Thread_Control_Block) return Process_Access
   is
   begin
      return TCB.Process;
   end Owning_Process;

   function State (TCB : Thread_Control_Block) return Thread_State is
   begin
      return TCB.Status;
   end State;

   function Lifecycle_State
     (PCB : Process_Control_Block) return Process_State
   is
   begin
      return PCB.Status;
   end Lifecycle_State;

   procedure Set_Process_State
     (PCB       : in out Process_Control_Block;
      New_State : Process_State)
   is
   begin
      PCB.Status := New_State;
   end Set_Process_State;

   function Process_Address_Space_Root
     (PCB : Process_Control_Block) return Kernel.Capabilities.U64
   is
   begin
      return PCB.Root;
   end Process_Address_Space_Root;

   function Address_Space_Root (TCB : Thread_Control_Block)
      return Kernel.Capabilities.U64
   is
   begin
      if TCB.Process = null then
         return 0;
      end if;

      return Process_Address_Space_Root (TCB.Process.all);
   end Address_Space_Root;

   procedure Set_Address_Space_Root
     (TCB  : in out Thread_Control_Block;
      Root : Kernel.Capabilities.U64)
   is
   begin
      if TCB.Process /= null then
         TCB.Process.Root := Root;
      end if;
   end Set_Address_Space_Root;

   procedure Set_Process_Address_Space_Root
     (PCB  : in out Process_Control_Block;
      Root : Kernel.Capabilities.U64)
   is
   begin
      PCB.Root := Root;
   end Set_Process_Address_Space_Root;

   procedure Install_Address_Space_Cap
     (PCB    : in out Process_Control_Block;
      Result : out Kernel.Capabilities.Status)
   is
   begin
      if PCB.Root = 0 then
         Result := Kernel.Capabilities.Invalid_Object;
         return;
      end if;

      Kernel.Capabilities.Insert_At
        (Table  => PCB.Caps,
         Cap    => Address_Space_Cap_Handle,
         Kind   => Kernel.Capabilities.Address_Space_Object,
         Object => To_Address (PCB.Root),
         Rights => Address_Space_Rights,
         Badge  => Kernel.Capabilities.U64 (PCB.Identifier),
         Result => Result);
   end Install_Address_Space_Cap;

   function Has_Address_Space_Map_Authority
     (TCB : Thread_Control_Block;
      Cap : Kernel.Capabilities.Handle) return Boolean
   is
      Result         : Kernel.Capabilities.Status;
      Cap_Entry_Info : Kernel.Capabilities.Cap_Entry;
   begin
      if TCB.Process = null then
         return False;
      end if;

      Kernel.Capabilities.Lookup
        (Table     => TCB.Process.Caps,
         Cap       => Cap,
         Result    => Result,
         Out_Entry => Cap_Entry_Info);

      return Result = Kernel.Capabilities.Ok
        and then Cap_Entry_Info.Kind =
          Kernel.Capabilities.Address_Space_Object
        and then Cap_Entry_Info.Rights.Map
        and then To_U64 (Cap_Entry_Info.Object) = TCB.Process.Root;
   end Has_Address_Space_Map_Authority;

   procedure Save_Trap_Context
     (TCB   : in out Thread_Control_Block;
      Frame : System.Address)
   is
   begin
      Arch.Context.Save_From_Trap_Frame (TCB.Context, Frame);
   end Save_Trap_Context;

   procedure Restore_Trap_Context
     (TCB   : Thread_Control_Block;
      Frame : System.Address)
   is
   begin
      Arch.Context.Restore_To_Trap_Frame (TCB.Context, Frame);
   end Restore_Trap_Context;

   procedure Set_Kernel_Stack_Top
     (TCB       : in out Thread_Control_Block;
      Stack_Top : Kernel.Capabilities.U64)
   is
   begin
      TCB.Kernel_Stack_Top := Stack_Top;
   end Set_Kernel_Stack_Top;

   function Kernel_Stack_Top
     (TCB : Thread_Control_Block) return Kernel.Capabilities.U64
   is
   begin
      return TCB.Kernel_Stack_Top;
   end Kernel_Stack_Top;

   procedure Set_IPC_Buffer
     (TCB     : in out Thread_Control_Block;
      Phys_PA : Kernel.Capabilities.U64)
   is
   begin
      TCB.IPC_Buffer := Phys_PA;
   end Set_IPC_Buffer;

   function IPC_Buffer_PA
     (TCB : Thread_Control_Block) return Kernel.Capabilities.U64
   is
   begin
      return TCB.IPC_Buffer;
   end IPC_Buffer_PA;

   procedure Initialize_Context
     (TCB       : in out Thread_Control_Block;
      PC        : Kernel.Capabilities.U64;
      Stack     : Kernel.Capabilities.U64;
      User_Satp : Kernel.Capabilities.U64)
   is
   begin
      Arch.Context.Initialize_User
        (Context   => TCB.Context,
         PC        => PC,
         Stack     => Stack,
         User_Satp => User_Satp);
   end Initialize_Context;

   function Has_Context (TCB : Thread_Control_Block) return Boolean is
   begin
      return Arch.Context.Valid (TCB.Context);
   end Has_Context;

   procedure Read_Context_Words
     (TCB   : Thread_Control_Block;
      Words : out Arch.Context.Context_Word_Array) is
   begin
      Arch.Context.Read_Words (TCB.Context, Words);
   end Read_Context_Words;

   function Is_Queued (TCB : Thread_Control_Block) return Boolean is
   begin
      return TCB.Queued;
   end Is_Queued;

   procedure Set_Queued
     (TCB    : in out Thread_Control_Block;
      Queued : Boolean)
   is
   begin
      TCB.Queued := Queued;
   end Set_Queued;

   function Is_Boosted (TCB : Thread_Control_Block) return Boolean is
   begin
      return TCB.Boosted;
   end Is_Boosted;

   procedure Set_Boosted
     (TCB     : in out Thread_Control_Block;
      Boosted : Boolean)
   is
   begin
      TCB.Boosted := Boosted;
   end Set_Boosted;

   procedure Set_State
     (TCB       : in out Thread_Control_Block;
      New_State : Thread_State)
   is
   begin
      TCB.Status := New_State;
   end Set_State;
   procedure Set_Awaiting_Reply
     (TCB      : in out Thread_Control_Block;
      Awaiting : Boolean)
   is
   begin
      TCB.Awaiting_Reply := Awaiting;
   end Set_Awaiting_Reply;

   function Is_Awaiting_Reply (TCB : Thread_Control_Block) return Boolean is
   begin
      return TCB.Awaiting_Reply;
   end Is_Awaiting_Reply;

   procedure Set_Reply_Wanted
     (TCB    : in out Thread_Control_Block;
      Wanted : Boolean)
   is
   begin
      TCB.Reply_Wanted := Wanted;
   end Set_Reply_Wanted;

   function Is_Reply_Wanted (TCB : Thread_Control_Block) return Boolean is
   begin
      return TCB.Reply_Wanted;
   end Is_Reply_Wanted;

   procedure Set_Endpoint_Queue_Next
     (TCB  : in out Thread_Control_Block;
      Next : Thread_Access)
   is
   begin
      TCB.Queue_Next := Next;
   end Set_Endpoint_Queue_Next;

   function Endpoint_Queue_Next
     (TCB : Thread_Control_Block) return Thread_Access
   is
   begin
      return TCB.Queue_Next;
   end Endpoint_Queue_Next;

   procedure Set_IPC_Badge
     (TCB   : in out Thread_Control_Block;
      Badge : Kernel.Capabilities.U64)
   is
   begin
      TCB.Call_Badge := Badge;
   end Set_IPC_Badge;

   function IPC_Badge
     (TCB : Thread_Control_Block) return Kernel.Capabilities.U64
   is
   begin
      return TCB.Call_Badge;
   end IPC_Badge;

   procedure Set_Bound_Ntfn
     (TCB   : in out Thread_Control_Block;
      Ntfn  : System.Address)
   is
   begin
      TCB.Bound_Ntfn := Ntfn;
   end Set_Bound_Ntfn;

   function Bound_Ntfn (TCB : Thread_Control_Block) return System.Address
   is
   begin
      return TCB.Bound_Ntfn;
   end Bound_Ntfn;

   procedure Set_Recv_Endpoint
     (TCB      : in out Thread_Control_Block;
      Endpoint : System.Address)
   is
   begin
      TCB.Recv_EP := Endpoint;
   end Set_Recv_Endpoint;

   function Recv_Endpoint
     (TCB : Thread_Control_Block) return System.Address
   is
   begin
      return TCB.Recv_EP;
   end Recv_Endpoint;

   procedure Append_Debug_Char
     (TCB   : in out Thread_Control_Block;
      Char  : Character;
      Flush : out Boolean)
   is
   begin
      if TCB.Debug_Len >= Debug_Line_Max then
         Flush := True;
         return;
      end if;

      TCB.Debug_Len := TCB.Debug_Len + 1;
      TCB.Debug_Line (TCB.Debug_Len) := Char;
      Flush := Char = Character'Val (10) or else TCB.Debug_Len = Debug_Line_Max;
   end Append_Debug_Char;

   procedure Take_Debug_Line
     (TCB  : in out Thread_Control_Block;
      Line : out String;
      Len  : out Natural)
   is
   begin
      Len := TCB.Debug_Len;
      if Len > Line'Length then
         Len := Line'Length;
      end if;
      Line (Line'First .. Line'First + Len - 1) :=
        TCB.Debug_Line (1 .. Len);
      TCB.Debug_Len := 0;
   end Take_Debug_Line;

   procedure Set_Saved_Result
     (TCB   : in out Thread_Control_Block;
      Value : Kernel.Capabilities.U64)
   is
   begin
      Arch.Context.Set_Saved_Result (TCB.Context, Value);
   end Set_Saved_Result;

   procedure Insert_Process_Cap
     (PCB    : in out Process_Control_Block;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status;
      Cap    : out Kernel.Capabilities.Handle)
   is
   begin
      Kernel.Capabilities.Insert
        (Table  => PCB.Caps,
         Kind   => Kind,
         Object => Object,
         Rights => Rights,
         Badge  => Badge,
         Result => Result,
         Cap    => Cap);

      if Result = Kernel.Capabilities.Ok then
         Kernel.Objects.Retain_Cap
           ((Valid  => True,
             Kind   => Kind,
             Object => Object,
             Rights => Rights,
             Badge  => Badge));
      end if;
   end Insert_Process_Cap;

   procedure Insert_Cap
     (TCB    : in out Thread_Control_Block;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status;
      Cap    : out Kernel.Capabilities.Handle)
   is
   begin
      if TCB.Process = null then
         Result := Kernel.Capabilities.Invalid_Object;
         Cap := Kernel.Capabilities.Invalid_Handle;
         return;
      end if;

      Insert_Process_Cap
        (PCB    => TCB.Process.all,
         Kind   => Kind,
         Object => Object,
         Rights => Rights,
         Badge  => Badge,
         Result => Result,
         Cap    => Cap);
   end Insert_Cap;

   procedure Insert_Process_Cap_At
     (PCB    : in out Process_Control_Block;
      Cap    : Kernel.Capabilities.Handle;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status)
   is
   begin
      Kernel.Capabilities.Insert_At
        (Table  => PCB.Caps,
         Cap    => Cap,
         Kind   => Kind,
         Object => Object,
         Rights => Rights,
         Badge  => Badge,
         Result => Result);

      if Result = Kernel.Capabilities.Ok then
         Kernel.Objects.Retain_Cap
           ((Valid  => True,
             Kind   => Kind,
             Object => Object,
             Rights => Rights,
             Badge  => Badge));
      end if;
   end Insert_Process_Cap_At;

   procedure Insert_Cap_At
     (TCB    : in out Thread_Control_Block;
      Cap    : Kernel.Capabilities.Handle;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status)
   is
   begin
      if TCB.Process = null then
         Result := Kernel.Capabilities.Invalid_Object;
         return;
      end if;

      Insert_Process_Cap_At
        (PCB    => TCB.Process.all,
         Cap    => Cap,
         Kind   => Kind,
         Object => Object,
         Rights => Rights,
         Badge  => Badge,
         Result => Result);
   end Insert_Cap_At;

   procedure Lookup_Process_Cap
     (PCB       : Process_Control_Block;
      Cap       : Kernel.Capabilities.Handle;
      Result    : out Kernel.Capabilities.Status;
      Out_Entry : out Kernel.Capabilities.Cap_Entry)
   is
   begin
      Kernel.Capabilities.Lookup
        (Table     => PCB.Caps,
         Cap       => Cap,
         Result    => Result,
         Out_Entry => Out_Entry);
   end Lookup_Process_Cap;

   procedure Lookup_Cap
     (TCB       : Thread_Control_Block;
      Cap       : Kernel.Capabilities.Handle;
      Result    : out Kernel.Capabilities.Status;
      Out_Entry : out Kernel.Capabilities.Cap_Entry)
   is
   begin
      if TCB.Process = null then
         Result := Kernel.Capabilities.Invalid_Object;
         Out_Entry := Kernel.Capabilities.Null_Cap;
         return;
      end if;

      Lookup_Process_Cap
        (PCB       => TCB.Process.all,
         Cap       => Cap,
         Result    => Result,
         Out_Entry => Out_Entry);
   end Lookup_Cap;

   procedure Close_Cap
     (Thread       : not null Thread_Access;
      Cap          : Kernel.Capabilities.Handle;
      Result       : out Kernel.Capabilities.Status;
      Thread_Dying : Boolean := False)
   is
      Cap_Info : Kernel.Capabilities.Cap_Entry;
   begin
      if Thread.Process = null then
         Result := Kernel.Capabilities.Invalid_Object;
         return;
      end if;

      Lookup_Process_Cap
        (PCB       => Thread.Process.all,
         Cap       => Cap,
         Result    => Result,
         Out_Entry => Cap_Info);
      if Result /= Kernel.Capabilities.Ok then
         return;
      end if;

      Kernel.Objects.Cleanup_Thread_Cap_Object
        (Thread, Cap_Info, Thread_Dying => Thread_Dying);
      Kernel.Capabilities.Close
        (Table  => Thread.Process.Caps,
         Cap    => Cap,
         Result => Result);
   end Close_Cap;

   procedure Forget_Cap
     (Thread : not null Thread_Access;
      Cap    : Kernel.Capabilities.Handle;
      Result : out Kernel.Capabilities.Status)
   is
   begin
      if Thread.Process = null then
         Result := Kernel.Capabilities.Invalid_Object;
         return;
      end if;

      Kernel.Capabilities.Close
        (Table  => Thread.Process.Caps,
         Cap    => Cap,
         Result => Result);
   end Forget_Cap;

   procedure Reset_Process_Caps (PCB : in out Process_Control_Block) is
   begin
      Kernel.Capabilities.Reset (PCB.Caps);
   end Reset_Process_Caps;

   function Process_Cap_Count (PCB : Process_Control_Block) return Natural is
   begin
      return Kernel.Capabilities.Used_Count (PCB.Caps);
   end Process_Cap_Count;
end Kernel.Tasks;
