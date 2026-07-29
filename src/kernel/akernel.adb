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
   User_Stack_Frame        : Interfaces.Unsigned_64 := 0;
   Init_Kernel_Stack_Frame : Interfaces.Unsigned_64 := 0;
   User_Root_Table  : Interfaces.Unsigned_64 := 0;
   User_Stack_Top   : constant Interfaces.Unsigned_64 := 16#7000_0000#;
   Init_Image_Base  : Interfaces.Unsigned_64 := 0;
   Init_Image_Size  : Interfaces.Unsigned_64 := 0;
   Init_Entry       : Interfaces.Unsigned_64 := 0;

   Kernel_End       : Interfaces.Unsigned_8
     with Import, Convention => C, External_Name => "_end";
   First_Free       : constant Interfaces.Unsigned_64 :=
     Arch.Kernel_Virt_To_Phys (Interfaces.Unsigned_64
       (System.Storage_Elements.To_Integer (Kernel_End'Address)));
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

   Stress_Frame_Count : constant := 32;
   type Stress_Frame_Array is
     array (0 .. Stress_Frame_Count - 1) of Interfaces.Unsigned_64;

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

      --  Interleaved stress: allocate batch, free every other frame,
      --  reallocate the holes, then free all; free count must track
      --  exactly through each phase.
      if Passed then
         declare
            Stress_Before : constant Interfaces.Unsigned_64 :=
              Kernel.Physical_Memory.Free_Frame_Count;
            Frames : Stress_Frame_Array := (others => 0);
            Ok_Alloc : Boolean := True;
         begin
            for I in Frames'Range loop
               Kernel.Physical_Memory.Allocate_Frame (Status, Frames (I));
               if Status /= Kernel.Physical_Memory.Ok then
                  Ok_Alloc := False;
                  for J in Frames'First .. I - 1 loop
                     Kernel.Physical_Memory.Deallocate_Frame
                       (Frames (J), Status);
                  end loop;
                  exit;
               end if;
            end loop;

            Passed := Ok_Alloc
              and then Kernel.Physical_Memory.Free_Frame_Count
                = Stress_Before - Stress_Frame_Count;

            --  Free every other frame; holes go to free list except
            --  the topmost bump frame, which shrinks the bump pointer.
            if Passed then
               for I in Frames'Range loop
                  if I mod 2 = 1 then
                     Kernel.Physical_Memory.Deallocate_Frame
                       (Frames (I), Status);
                     Passed := Status = Kernel.Physical_Memory.Ok;
                     exit when not Passed;
                     Frames (I) := 0;
                  end if;
               end loop;

               Passed := Passed
                 and then Kernel.Physical_Memory.Free_Frame_Count
                   = Stress_Before - Stress_Frame_Count / 2;
            end if;

            --  Reallocate the holes; free-list reuse must satisfy them.
            if Passed then
               for I in Frames'Range loop
                  if Frames (I) = 0 then
                     Kernel.Physical_Memory.Allocate_Frame
                       (Status, Frames (I));
                     Passed := Status = Kernel.Physical_Memory.Ok
                       and then Frames (I) /= 0;
                     exit when not Passed;
                  end if;
               end loop;

               Passed := Passed
                 and then Kernel.Physical_Memory.Free_Frame_Count
                   = Stress_Before - Stress_Frame_Count;
            end if;

            --  Free everything; free count must return to baseline.
            if Ok_Alloc then
               for I in Frames'Range loop
                  if Frames (I) /= 0 then
                     Kernel.Physical_Memory.Deallocate_Frame
                       (Frames (I), Status);
                     Passed := Passed
                       and then Status = Kernel.Physical_Memory.Ok;
                  end if;
               end loop;

               Passed := Passed
                 and then Kernel.Physical_Memory.Free_Frame_Count
                   = Stress_Before;
            end if;
         end;
      end if;

      if Passed then
         Board.UART.Put_Line ("pmm selftest online");
      else
         Board.UART.Put_Line ("pmm selftest failed");
      end if;
   end PMM_Self_Test;

   Selftest_Endpoint : aliased Kernel.IPC.Endpoint;

   procedure Objects_Self_Test is
      Passed : Boolean := True;
   begin
      --  Dynamic lifecycle: init refcount 1, retain to 2, release to 1
      --  (not destroyed), release to 0 (destroyed).
      Kernel.IPC.Initialize (Selftest_Endpoint, Pinned => False);
      Kernel.IPC.Retain (Selftest_Endpoint'Address);
      if Kernel.IPC.Release (Selftest_Endpoint'Address) then
         Passed := False;
      end if;
      if not Kernel.IPC.Release (Selftest_Endpoint'Address) then
         Passed := False;
      end if;

      --  Pinned objects never release.
      if Kernel.IPC.Release (Test_Endpoint'Address) then
         Passed := False;
      end if;

      if Passed then
         Board.UART.Put_Line ("objects selftest online");
      else
         Board.UART.Put_Line ("objects selftest failed");
      end if;
   end Objects_Self_Test;
begin
   Board.UART.Put_Line ("Hello world!");

   Kernel.Device_Tree.Discover_Memory
     (DTB    => Board.Device_Tree.Boot_DTB_Physical_Address,
      Result => DTB_Result,
      Base   => Memory_Base,
      Size   => Memory_Size);

   if DTB_Result = Kernel.Device_Tree.Ok then
      Kernel.Physical_Memory.Initialize
        (First_Free => First_Free,
         Last_Byte  => Memory_Base + Memory_Size,
         Result     => PMM_Result);
   end if;

   if PMM_Result = Kernel.Physical_Memory.Ok then
      Arch.MMU.Enter_Kernel_Address_Space
        (Ram_Last => Memory_Base + Memory_Size,
         Result   => MMU_Result);
   end if;

   if PMM_Result = Kernel.Physical_Memory.Ok
     and then MMU_Result = Arch.MMU.Ok
   then
      Board.UART.Put_Line ("kernel address space online");
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
   Kernel.IPC.Initialize (Test_Endpoint, Pinned => True);
   Objects_Self_Test;

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

   --  Init kernel trap stack must be visible in its own user address
   --  space: the trap trampoline builds frames on it before switching
   --  satp to the kernel root.  Mapped at its physmap VA, matching
   --  the sscratch invariant (physmap VA of the kernel stack top).
   if Initrd_Result = Kernel.Initrd.Ok
     and then MMU_Result = Arch.MMU.Ok
   then
      Arch.MMU.Map_Page
        (Root     => User_Root_Table,
         Virtual  => Arch.Phys_To_Virt (Init_Kernel_Stack_Frame),
         Physical => Init_Kernel_Stack_Frame,
         Flags    => Arch.MMU.Kernel_RW,
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
           (Arch.Phys_To_Virt (Kernel.Tasks.Kernel_Stack_Top (Init_Task)));
      end if;
      Arch.User_Mode.Enter_User_Mode
        (Entry_Point => Init_Entry,
         Stack       => User_Stack_Top,
         User_Satp   => Arch.MMU.Satp_Value (User_Root_Table));
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
      Board.UART.Put_Line ("fatal: no initrd init; halting");
      loop
         null;
      end loop;
   end if;
end Akernel;
