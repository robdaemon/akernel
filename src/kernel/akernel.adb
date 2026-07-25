with Interfaces;
with System;
with System.Storage_Elements;
with Arch.MMU;
with Arch.Traps;
with Arch.User_Mode;
with Board.Device_Tree;
with Board.Interrupts;
with Board.UART;
with Kernel.Boot_Resources;
with Kernel.Capabilities;
with Kernel.Device_Tree;
with Kernel.ELF;
with Kernel.Initrd;
with Kernel.IPC;
with Kernel.Interrupts;
with Kernel.Physical_Memory;
with Kernel.Processes;
with Kernel.Scheduler;
with Kernel.Tasks;

procedure Akernel is
   use type Interfaces.Unsigned_64;
   use type Kernel.Capabilities.Status;
   use type Kernel.Device_Tree.Status;
   use type Arch.MMU.Status;
   use type Kernel.ELF.Status;
   use type Kernel.Initrd.Status;
   use type Kernel.IPC.Status;
   use type Kernel.Physical_Memory.Status;
   use type Kernel.Scheduler.Status;
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;

   Bootstrap_Process : aliased Kernel.Tasks.Process_Control_Block;
   Driver_Process    : aliased Kernel.Tasks.Process_Control_Block;
   Init_Process      : aliased Kernel.Tasks.Process_Control_Block;
   Bootstrap_Task    : aliased Kernel.Tasks.Thread_Control_Block;
   Driver_Task       : aliased Kernel.Tasks.Thread_Control_Block;
   Init_Task         : aliased Kernel.Tasks.Thread_Control_Block;
   Result           : Kernel.Capabilities.Status;
   IPC_Result       : Kernel.IPC.Status;
   IRQ_Result       : Kernel.Interrupts.Status;
   Initrd_Result    : Kernel.Initrd.Status;
   ELF_Result       : Kernel.ELF.Status;
   Scheduler_Result : Kernel.Scheduler.Status;
   DTB_Result       : Kernel.Device_Tree.Status :=
     Kernel.Device_Tree.Memory_Not_Found;
   PMM_Result       : Kernel.Physical_Memory.Status :=
     Kernel.Physical_Memory.Not_Initialized;
   MMU_Result       : Arch.MMU.Status := Arch.MMU.Allocation_Failed;
   Memory_Base      : Interfaces.Unsigned_64 := 0;
   Memory_Size      : Interfaces.Unsigned_64 := 0;
   First_Frame             : Interfaces.Unsigned_64 := 0;
   User_Stack_Frame        : Interfaces.Unsigned_64 := 0;
   Init_Kernel_Stack_Frame : Interfaces.Unsigned_64 := 0;
   Root_Table              : Interfaces.Unsigned_64 := 0;
   User_Root_Table  : Interfaces.Unsigned_64 := 0;
   User_Stack_Top   : constant Interfaces.Unsigned_64 := 16#7000_0000#;
   Init_Image_Base  : Interfaces.Unsigned_64 := 0;
   Init_Image_Size  : Interfaces.Unsigned_64 := 0;
   Init_Entry       : Interfaces.Unsigned_64 := 0;
   User_Alias_Delta : constant Interfaces.Unsigned_64 :=
     Kernel.ELF.User_Alias_Delta;
   Kernel_End       : Interfaces.Unsigned_8
     with Import, Convention => C, External_Name => "_end";
   User_Init        : Interfaces.Unsigned_8
     with Import, Convention => C, External_Name => "user_init";
   Console_Cap      : Kernel.Capabilities.Handle;
   Sender_Cap       : Kernel.Capabilities.Handle;
   Receiver_Cap     : Kernel.Capabilities.Handle;
   Test_Endpoint    : aliased Kernel.IPC.Endpoint;
   Sent_Message     : Kernel.IPC.Message := Kernel.IPC.Empty_Message;
   Got_Message      : Kernel.IPC.Message;

   Console_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => True,
      Write    => True,
      Execute  => False,
      Map      => False,
      Send     => False,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => True,
      Manage   => False);

   Endpoint_Send_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => False,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => True,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => True,
      Manage   => False);

   Endpoint_Receive_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => False,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => False,
      Receive  => True,
      Wait     => False,
      Ack      => False,
      Transfer => False,
      Manage   => False);

   MMIO_Map_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => True,
      Write    => True,
      Execute  => False,
      Map      => True,
      Send     => False,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => False,
      Manage   => False);

   IRQ_Wait_Ack_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => False,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => False,
      Receive  => False,
      Wait     => True,
      Ack      => True,
      Transfer => False,
      Manage   => False);

   procedure PMM_Self_Test is
      Before  : Interfaces.Unsigned_64;
      After   : Interfaces.Unsigned_64;
      Frame_A : Interfaces.Unsigned_64;
      Frame_B : Interfaces.Unsigned_64;
      Frame_C : Interfaces.Unsigned_64;
      Status  : Kernel.Physical_Memory.Status;
      Passed  : Boolean := False;
   begin
      if not Kernel.Physical_Memory.Initialized then
         return;
      end if;

      Before := Kernel.Physical_Memory.Free_Frame_Count;
      Kernel.Physical_Memory.Allocate_Frame (Status, Frame_A);
      if Status /= Kernel.Physical_Memory.Ok then
         return;
      end if;

      Kernel.Physical_Memory.Allocate_Frame (Status, Frame_B);
      if Status /= Kernel.Physical_Memory.Ok then
         Kernel.Physical_Memory.Deallocate_Frame (Frame_A, Status);
         return;
      end if;

      Kernel.Physical_Memory.Deallocate_Frame (Frame_A, Status);
      if Status = Kernel.Physical_Memory.Ok then
         Kernel.Physical_Memory.Allocate_Frame (Status, Frame_C);
         if Status = Kernel.Physical_Memory.Ok and then Frame_C = Frame_A then
            Kernel.Physical_Memory.Deallocate_Frame (Frame_C, Status);
            if Status = Kernel.Physical_Memory.Ok then
               Kernel.Physical_Memory.Deallocate_Frame (Frame_B, Status);
               if Status = Kernel.Physical_Memory.Ok then
                  Kernel.Physical_Memory.Deallocate_Frame (Frame_C, Status);
                  After := Kernel.Physical_Memory.Free_Frame_Count;
                  Passed := Status = Kernel.Physical_Memory.Invalid_Range
                    and then After = Before;
               end if;
            end if;
         end if;
      end if;

      if Passed then
         Board.UART.Put_Line ("pmm selftest online");
      else
         Board.UART.Put_Line ("pmm selftest failed");
      end if;
   end PMM_Self_Test;
begin
   Board.UART.Put_Line ("Hello world!");

   Kernel.Device_Tree.Discover_Memory
     (DTB    => Board.Device_Tree.Boot_DTB_Physical_Address,
      Result => DTB_Result,
      Base   => Memory_Base,
      Size   => Memory_Size);

   if DTB_Result = Kernel.Device_Tree.Ok then
      Kernel.Physical_Memory.Initialize
        (First_Free => Interfaces.Unsigned_64
           (System.Storage_Elements.To_Integer (Kernel_End'Address)),
         Last_Byte  => Memory_Base + Memory_Size,
         Result     => PMM_Result);
   end if;

   if PMM_Result = Kernel.Physical_Memory.Ok then
      Kernel.Physical_Memory.Allocate_Frame (PMM_Result, First_Frame);
   end if;

   if PMM_Result = Kernel.Physical_Memory.Ok then
      Arch.MMU.New_Address_Space (MMU_Result, Root_Table);
   end if;

   if MMU_Result = Arch.MMU.Ok then
      Arch.MMU.Map_Page
        (Root     => Root_Table,
         Virtual  => First_Frame,
         Physical => First_Frame,
         Flags    => Arch.MMU.Kernel_RW,
         Result   => MMU_Result);
   end if;

   if PMM_Result = Kernel.Physical_Memory.Ok
     and then MMU_Result = Arch.MMU.Ok
   then
      Kernel.Physical_Memory.Allocate_Frame (PMM_Result, User_Stack_Frame);
   end if;

   if PMM_Result = Kernel.Physical_Memory.Ok
     and then MMU_Result = Arch.MMU.Ok
   then
      Kernel.Physical_Memory.Allocate_Frame
        (PMM_Result, Init_Kernel_Stack_Frame);
   end if;

   if PMM_Result = Kernel.Physical_Memory.Ok
     and then MMU_Result = Arch.MMU.Ok
   then
      Board.UART.Put_Line ("memory manager online");
      Board.UART.Put ("ram MiB: ");
      Board.UART.Put_Decimal (Natural (Memory_Size / (1024 * 1024)));
      Board.UART.Put_Line ("");
      PMM_Self_Test;
   end if;

   Kernel.Tasks.Initialize_Process (Bootstrap_Process, 1);
   Kernel.Tasks.Set_Process_State
     (PCB       => Bootstrap_Process,
      New_State => Kernel.Tasks.Process_Alive);
   Kernel.Tasks.Initialize_Thread
     (TCB     => Bootstrap_Task,
      Id      => 1,
      Process => Bootstrap_Process'Unchecked_Access);
   Kernel.Tasks.Insert_Cap
     (TCB    => Bootstrap_Task,
      Kind   => Kernel.Capabilities.MMIO_Object,
      Object => System'To_Address (16#1000_0000#),
      Rights => Console_Rights,
      Badge  => 0,
      Result => Result,
      Cap    => Console_Cap);

   if Result = Kernel.Capabilities.Ok then
      Board.UART.Put_Line ("cap table online");
   end if;

   Kernel.Tasks.Initialize_Process (Driver_Process, 2);
   Kernel.Tasks.Set_Process_State
     (PCB       => Driver_Process,
      New_State => Kernel.Tasks.Process_Alive);
   Kernel.Tasks.Initialize_Thread
     (TCB     => Driver_Task,
      Id      => 2,
      Process => Driver_Process'Unchecked_Access);
   Kernel.IPC.Initialize (Test_Endpoint);

   Kernel.Tasks.Insert_Cap
     (TCB    => Bootstrap_Task,
      Kind   => Kernel.Capabilities.Endpoint_Object,
      Object => Test_Endpoint'Address,
      Rights => Endpoint_Send_Rights,
      Badge  => 42,
      Result => Result,
      Cap    => Sender_Cap);

   Kernel.Tasks.Insert_Cap
     (TCB    => Driver_Task,
      Kind   => Kernel.Capabilities.Endpoint_Object,
      Object => Test_Endpoint'Address,
      Rights => Endpoint_Receive_Rights,
      Badge  => 0,
      Result => Result,
      Cap    => Receiver_Cap);

   Kernel.Scheduler.Initialize;
   Kernel.Scheduler.Set_Current
     (TCB    => Bootstrap_Task'Unchecked_Access,
      Result => Scheduler_Result);

   Sent_Message.Label := 1;
   Sent_Message.Word_Count := 1;
   Sent_Message.Words (0) := 16#1234#;

   Kernel.IPC.Receive
     (Receiver     => Driver_Task'Unchecked_Access,
      Endpoint_Cap => Receiver_Cap,
      Result       => IPC_Result,
      Payload      => Got_Message);

   if IPC_Result = Kernel.IPC.Would_Block
     and then Kernel.Tasks.State (Driver_Task) = Kernel.Tasks.Blocked_Receive
   then
      Kernel.IPC.Send
        (Sender       => Bootstrap_Task'Unchecked_Access,
         Endpoint_Cap => Sender_Cap,
         Payload      => Sent_Message,
         Result       => IPC_Result);
   end if;

   if IPC_Result = Kernel.IPC.Ok then
      Kernel.IPC.Receive
        (Receiver     => Driver_Task'Unchecked_Access,
         Endpoint_Cap => Receiver_Cap,
         Result       => IPC_Result,
         Payload      => Got_Message);
   end if;

   if IPC_Result = Kernel.IPC.Ok
     and then Got_Message.Badge = 42
     and then Got_Message.Words (0) = 16#1234#
   then
      Board.UART.Put_Line ("ipc online");
   end if;

   if Scheduler_Result = Kernel.Scheduler.Ok then
      Kernel.Scheduler.Yield (Scheduler_Result);
   end if;

   if Scheduler_Result = Kernel.Scheduler.Ok
     and then Kernel.Scheduler.Current = Driver_Task'Unchecked_Access
     and then Kernel.Tasks.State (Driver_Task) = Kernel.Tasks.Running
   then
      Board.UART.Put_Line ("scheduler online");
   end if;

   Kernel.Initrd.Find
     (Name   => "System/Init",
      Result => Initrd_Result,
      Base   => Init_Image_Base,
      Size   => Init_Image_Size);

   if Initrd_Result = Kernel.Initrd.Ok then
      Arch.MMU.New_User_Address_Space
        (Result => MMU_Result,
         Root   => User_Root_Table);
   end if;

   if Initrd_Result = Kernel.Initrd.Ok
     and then MMU_Result = Arch.MMU.Ok
   then
      Arch.MMU.Map_Page
        (Root     => User_Root_Table,
         Virtual  => User_Stack_Top - Arch.MMU.Page_Size,
         Physical => User_Stack_Frame,
         Flags    => Arch.MMU.User_RW,
         Result   => MMU_Result);
   end if;

   if Initrd_Result = Kernel.Initrd.Ok
     and then MMU_Result = Arch.MMU.Ok
   then
      Kernel.ELF.Load_Into_Address_Space
        (Image_Base  => Init_Image_Base,
         Image_Size  => Init_Image_Size,
         Root        => User_Root_Table,
         Result      => ELF_Result,
         Entry_Point => Init_Entry);
   end if;

   Kernel.Tasks.Initialize_Process (Init_Process, 3);
   Kernel.Tasks.Set_Process_Address_Space_Root
     (PCB  => Init_Process,
      Root => User_Root_Table);
   Kernel.Tasks.Install_Address_Space_Cap
     (PCB    => Init_Process,
      Result => Result);
   Kernel.Tasks.Set_Process_State
     (PCB       => Init_Process,
      New_State => Kernel.Tasks.Process_Alive);
   Kernel.Tasks.Initialize_Thread
     (TCB     => Init_Task,
      Id      => 3,
      Process => Init_Process'Unchecked_Access);
   if Init_Kernel_Stack_Frame /= 0 then
      Kernel.Tasks.Set_Kernel_Stack_Top
        (TCB       => Init_Task,
         Stack_Top => Init_Kernel_Stack_Frame
           + Kernel.Physical_Memory.Page_Size);
   end if;

   Kernel.Tasks.Insert_Cap_At
     (TCB    => Init_Task,
      Cap    => 1,
      Kind   => Kernel.Capabilities.MMIO_Object,
      Object => Kernel.Boot_Resources.UART_MMIO_Object'Address,
      Rights => MMIO_Map_Rights,
      Badge  => 0,
      Result => Result);

   Kernel.Tasks.Insert_Cap_At
     (TCB    => Init_Task,
      Cap    => 2,
      Kind   => Kernel.Capabilities.IRQ_Object,
      Object => Kernel.Boot_Resources.UART_IRQ_Object'Address,
      Rights => IRQ_Wait_Ack_Rights,
      Badge  => 0,
      Result => Result);

   Kernel.Interrupts.Initialize;
   Kernel.Processes.Initialize;
   Kernel.Interrupts.Register
     (Kernel.Boot_Resources.UART_IRQ_Object'Access, IRQ_Result);

   Kernel.Scheduler.Initialize;
   Kernel.Scheduler.Set_Current
     (TCB    => Init_Task'Unchecked_Access,
      Result => Scheduler_Result);

   Board.Interrupts.Initialize;
   Arch.Traps.Initialize;

   if Initrd_Result = Kernel.Initrd.Ok
     and then ELF_Result = Kernel.ELF.Ok
   then
      Board.UART.Put_Line ("entering initrd init");
      if Kernel.Tasks.Kernel_Stack_Top (Init_Task) /= 0 then
         Arch.Traps.Set_Kernel_Trap_Stack
           (Kernel.Tasks.Kernel_Stack_Top (Init_Task));
      end if;
      Arch.MMU.Activate (User_Root_Table);
      Arch.User_Mode.Enter_User_Mode
        (Entry_Point => Init_Entry,
         Stack       => User_Stack_Top);
   else
      if Initrd_Result = Kernel.Initrd.Bad_Header then
         Board.UART.Put_Line ("initrd bad header");
      elsif Initrd_Result = Kernel.Initrd.Bad_CPIO then
         Board.UART.Put_Line ("initrd bad cpio");
      elsif Initrd_Result = Kernel.Initrd.Not_Found then
         Board.UART.Put_Line ("initrd init not found");
      elsif ELF_Result /= Kernel.ELF.Ok then
         Board.UART.Put_Line ("elf load failed");
      end if;
      Board.UART.Put_Line ("entering fallback user mode");
      Arch.User_Mode.Enter_User_Mode
        (Entry_Point => Interfaces.Unsigned_64
           (System.Storage_Elements.To_Integer (User_Init'Address))
           - User_Alias_Delta,
         Stack => User_Stack_Frame + Kernel.Physical_Memory.Page_Size
           - User_Alias_Delta);
   end if;
end Akernel;
