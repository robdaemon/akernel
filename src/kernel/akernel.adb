with Interfaces;
with System;
with System.Storage_Elements;
with Arch.MMU;
with Arch.IOMMU;
with Arch.SBI;
with Arch.Traps;
with Arch.User_Mode;
with Board.Device_Tree;
with Board.Interrupts;
with Board.Memory_Map;
with Board.PLIC;
with Board.UART;
with Kernel.Boot_Files;
with Kernel.Bootinfo;
with Kernel.Capabilities;
with Kernel.CPUs;
with Kernel.Device_Tree;
with Kernel.ELF;
with Kernel.Initrd;
with Kernel.IPC;
with Kernel.Interrupts;
with Kernel.Objects;
with Kernel.Physical_Memory;
with Kernel.Processes;
with Kernel.Scheduler;
with Kernel.Tasks;

procedure Akernel is
   use type Interfaces.Unsigned_64;
   use type Kernel.Capabilities.Status;
   use type Kernel.Boot_Files.Status;
   use type Kernel.Bootinfo.Status;
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
   Initrd_Result    : Kernel.Initrd.Status;
   ELF_Result       : Kernel.ELF.Status;
   Scheduler_Result : Kernel.Scheduler.Status;
   DTB_Result       : Kernel.Device_Tree.Status :=
     Kernel.Device_Tree.Memory_Not_Found;
   Dev_Result       : Kernel.Device_Tree.Status :=
     Kernel.Device_Tree.Device_Not_Found;
   PMM_Result       : Kernel.Physical_Memory.Status :=
     Kernel.Physical_Memory.Not_Initialized;
   MMU_Result       : Arch.MMU.Status := Arch.MMU.Allocation_Failed;
   Memory_Base      : Interfaces.Unsigned_64 := 0;
   Memory_Size      : Interfaces.Unsigned_64 := 0;
   Dev_Base         : Interfaces.Unsigned_64 := 0;
   Dev_Size         : Interfaces.Unsigned_64 := 0;
   Dev_IRQ          : Interfaces.Unsigned_64 := 0;
   UART_Base        : Interfaces.Unsigned_64 := Board.Memory_Map.UART0_Base;
   UART_IRQ         : Interfaces.Unsigned_64 :=
     Interfaces.Unsigned_64 (Board.PLIC.UART0_Source);
   PLIC_Base        : Interfaces.Unsigned_64 := Board.Memory_Map.PLIC_Base;
   Devices_Found    : Natural := 0;

   --  SMP topology: boot hart raw id (a0 at entry), cpu nodes from
   --  the DTB, and the dense CPU-index table handed to Kernel.CPUs.
   Boot_Hart_Raw_Id : Interfaces.Unsigned_64
     with Import, Convention => C, External_Name => "boot_hart_id";
   Secondary_Boot_Sym : Interfaces.Unsigned_8
     with Import, Convention => C, External_Name => "secondary_boot";
   Cpu_Ids        : Kernel.Device_Tree.Cpu_Id_List := (others => 0);
   Cpu_Count      : Natural := 0;
   Hart_Raw       : Kernel.CPUs.Raw_Id_Array := (others => 0);
   Hart_Count     : Natural := 1;
   Hart_Start_RC  : Interfaces.Unsigned_64 := 0;
   User_Stack_Frame        : Interfaces.Unsigned_64 := 0;
   Init_Kernel_Stack_Frame : Interfaces.Unsigned_64 := 0;
   Init_IPC_Buffer_Frame   : Interfaces.Unsigned_64 := 0;
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
   Test_Endpoint    : aliased Kernel.IPC.Endpoint;

   Selftest_Object   : System.Address;
   Exhausted_Objects : array (1 .. 100) of System.Address;
   Exhausted_Count   : Natural;

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

   --  Image caps handed to init: spawn consumes them (Read+Execute);
   --  Transfer lets init re-grant images to delegate spawners.
   Boot_File_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => True,
      Write    => False,
      Execute  => True,
      Map      => False,
      Send     => False,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => True,
      Manage   => False);

   --  Authority token for the device-plumbing syscalls (io_map,
   --  irq_create): init holds the only Kernel_Object cap, listed in
   --  bootinfo as "device_resource". The object itself is a pinned
   --  dummy; only the kind + Manage right are checked.
   Device_Resource_Object : aliased Kernel.Objects.Object_Header :=
     (Count => Kernel.Objects.Pinned_Refcount);

   --  Admin authority token for the introspection-dump syscalls
   --  (cap_info / thread_regs, milestone 39): init holds the only
   --  Admin_Object cap, listed in bootinfo as "admin". Empty
   --  pinned object; only kind + Manage are checked. Transfer is
   --  set so init (and a future Elevate-style daemon) can
   --  delegate by mint.
   Admin_Resource_Object : aliased Kernel.Objects.Object_Header :=
     (Count => Kernel.Objects.Pinned_Refcount);

   Admin_Resource_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => False,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => False,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => True,
      Manage   => True);

   Device_Resource_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => False,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => False,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => False,
      Manage   => True);

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

   procedure Objects_Self_Test is
      Passed : Boolean := True;
   begin
      --  Dynamic lifecycle: create (refcount 0), retain to 2, release
      --  to 1 (not destroyed), release to 0 (destroyed, slot freed).
      Kernel.IPC.Create_Endpoint (IPC_Result, Selftest_Object);
      if IPC_Result /= Kernel.IPC.Ok then
         Passed := False;
      else
         Kernel.IPC.Retain (Selftest_Object);
         Kernel.IPC.Retain (Selftest_Object);
         if Kernel.IPC.Release (Selftest_Object) then
            Passed := False;
         end if;
         if not Kernel.IPC.Release (Selftest_Object) then
            Passed := False;
         end if;
      end if;

      --  Pool growth and reuse: create 100 endpoints (forces several
      --  slab frame allocations), discard all, create 100 again
      --  (free-list reuse), discard.
      for Pass in 1 .. 2 loop
         Exhausted_Count := 0;
         loop
            Kernel.IPC.Create_Endpoint (IPC_Result, Selftest_Object);
            exit when IPC_Result /= Kernel.IPC.Ok
              or else Exhausted_Count = 100;
            Exhausted_Count := Exhausted_Count + 1;
            Exhausted_Objects (Exhausted_Count) := Selftest_Object;
         end loop;

         if IPC_Result /= Kernel.IPC.Ok or else Exhausted_Count /= 100 then
            Passed := False;
         end if;

         for Index in 1 .. Exhausted_Count loop
            Kernel.IPC.Discard (Exhausted_Objects (Index));
         end loop;
      end loop;

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

   --  Device enumeration: UART and PLIC come from the DTB when the
   --  nodes are present; board defaults stand otherwise.
   if DTB_Result = Kernel.Device_Tree.Ok then
      Kernel.Device_Tree.Find_Device
        (DTB        => Board.Device_Tree.Boot_DTB_Physical_Address,
         Compatible => "ns16550a",
         Base       => Dev_Base,
         Size       => Dev_Size,
         IRQ_Source => Dev_IRQ,
         Result     => Dev_Result);

      if Dev_Result = Kernel.Device_Tree.Ok
        and then Dev_IRQ <= Interfaces.Unsigned_64 (Board.PLIC.Source_Id'Last)
      then
         UART_Base := Dev_Base;
         UART_IRQ := Dev_IRQ;
         Devices_Found := Devices_Found + 1;
      end if;

      Kernel.Device_Tree.Find_Device
        (DTB        => Board.Device_Tree.Boot_DTB_Physical_Address,
         Compatible => "riscv,plic0",
         Base       => Dev_Base,
         Size       => Dev_Size,
         IRQ_Source => Dev_IRQ,
         Result     => Dev_Result);

      if Dev_Result = Kernel.Device_Tree.Ok then
         PLIC_Base := Dev_Base;
         Devices_Found := Devices_Found + 1;
      end if;
   end if;

   --  SMP topology from the DTB: boot hart at CPU index 0, every
   --  other hart the firmware described after it, clamped to
   --  Kernel.CPUs.Max_CPUs.  Falls back to uniprocessor.
   Hart_Raw (Kernel.CPUs.CPU_Index'First) := Boot_Hart_Raw_Id;
   if DTB_Result = Kernel.Device_Tree.Ok then
      Kernel.Device_Tree.Enumerate_Cpus
        (DTB    => Board.Device_Tree.Boot_DTB_Physical_Address,
         Ids    => Cpu_Ids,
         Count  => Cpu_Count,
         Result => Dev_Result);

      if Dev_Result = Kernel.Device_Tree.Ok then
         for I in 0 .. Cpu_Count - 1 loop
            exit when Hart_Count >= Kernel.CPUs.Max_CPUs;
            if Cpu_Ids (I) /= Boot_Hart_Raw_Id then
               Hart_Raw (Kernel.CPUs.CPU_Index (Hart_Count)) :=
                 Cpu_Ids (I);
               Hart_Count := Hart_Count + 1;
            end if;
         end loop;
      end if;
   end if;
   Kernel.CPUs.Configure (Hart_Raw, Hart_Count);

   --  Boot hart idle stacks: the boot main/trap stacks (linker
   --  symbols link at kernel VAs; convert to physical addresses).
   --  The idle path leaves a blocked thread's kernel stack for
   --  these.
   declare
      Boot_Stack_Top : Interfaces.Unsigned_8
        with Import, External_Name => "__stack_top";
      Boot_Trap_Top  : Interfaces.Unsigned_8
        with Import, External_Name => "__trap_stack_top";
   begin
      Kernel.CPUs.Set_Stacks
        (CPU      => Kernel.CPUs.CPU_Index'First,
         Trap_Top => Arch.Kernel_Virt_To_Phys
           (Kernel.CPUs.U64 (System.Storage_Elements.To_Integer
             (Boot_Trap_Top'Address))),
         Main_Top => Arch.Kernel_Virt_To_Phys
           (Kernel.CPUs.U64 (System.Storage_Elements.To_Integer
             (Boot_Stack_Top'Address))));
   end;

   if Hart_Count > 1 then
      Board.UART.Put ("smp: ");
      Board.UART.Put_Decimal (Hart_Count);
      Board.UART.Put_Line (" harts");
   end if;

   Board.UART.Set_Base (UART_Base);
   Board.PLIC.Set_Base (PLIC_Base);

   if Devices_Found = 2 then
      Board.UART.Put_Line ("dtb devices online");
   else
      Board.UART.Put_Line ("dtb devices incomplete; board defaults");
   end if;

   if DTB_Result = Kernel.Device_Tree.Ok then
      Kernel.Physical_Memory.Initialize
        (First_Free => First_Free,
         Last_Byte  => Memory_Base + Memory_Size,
         Result     => PMM_Result);

      --  Keep the initrd image and the DTB out of the allocator:
      --  both live above the kernel image in RAM and would
      --  otherwise be handed out as ordinary frames.
      if PMM_Result = Kernel.Physical_Memory.Ok then
         Kernel.Physical_Memory.Reserve
           (Base   => 16#8400_0000#,
            Length => Kernel.Initrd.Image_Length,
            Result => PMM_Result);
      end if;

      if PMM_Result = Kernel.Physical_Memory.Ok then
         --  Boot_DTB_Physical_Address returns a physmap VA despite
         --  its name; the reservation needs the true PA.
         Kernel.Physical_Memory.Reserve
           (Base   => Board.Device_Tree.Boot_DTB_Physical_Address
              - Arch.Physmap_Base,
            Length => Kernel.Device_Tree.Total_Size
              (Board.Device_Tree.Boot_DTB_Physical_Address),
            Result => PMM_Result);
      end if;
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
      Kernel.Physical_Memory.Allocate_Frame
        (PMM_Result, Init_IPC_Buffer_Frame);
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
   --  Cap-table smoke test on the bootstrap thread: any static
   --  object works; the device-resource authority header is one.
   --  The UART's runtime MMIO/IRQ objects are minted per-instance
   --  by init's device manager (io_map / irq_create) instead.
   Kernel.Tasks.Insert_Cap
     (TCB    => Bootstrap_Task,
      Kind   => Kernel.Capabilities.Kernel_Object,
      Object => Device_Resource_Object'Address,
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
   Board.UART.Put_Line ("ipc online");

   Kernel.Scheduler.Initialize;
   Kernel.Scheduler.Set_Current
     (TCB    => Bootstrap_Task'Unchecked_Access,
      Result => Scheduler_Result);

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

   --  Boot-file image caps: enumerate every initrd file into the
   --  static Boot_File_Object table before caps are minted below.
   if Initrd_Result = Kernel.Initrd.Ok then
      declare
         Files_Result : Kernel.Boot_Files.Status;
         Files_Count  : Natural;
      begin
         Kernel.Boot_Files.Enumerate
           (Result => Files_Result,
            Count  => Files_Count);
         if Files_Result /= Kernel.Boot_Files.Ok then
            Board.UART.Put_Line ("boot file enumeration failed");
         elsif DTB_Result = Kernel.Device_Tree.Ok then
            --  Expose the DTB itself as boot file "dtb" so init can
            --  enumerate devices without kernel-side policy.
            --  Boot_DTB_Physical_Address is already a physmap VA.
            Kernel.Boot_Files.Add_DTB
              (Base   => Board.Device_Tree.Boot_DTB_Physical_Address,
               Length => Kernel.Device_Tree.Total_Size
                 (Board.Device_Tree.Boot_DTB_Physical_Address),
               Result => Files_Result);
            if Files_Result /= Kernel.Boot_Files.Ok then
               Board.UART.Put_Line ("dtb boot file failed");
            end if;
         end if;
      end;
   end if;

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
      --  Spawned processes get 4 stack pages; init deserves the
      --  same (Start_Display's fs staging overflowed the single
      --  page: store fault at stack_base - 8).
      for I in 2 .. 4 loop
         exit when MMU_Result /= Arch.MMU.Ok;
         declare
            Extra_Frame : Interfaces.Unsigned_64 := 0;
         begin
            Kernel.Physical_Memory.Allocate_Frame
              (PMM_Result, Extra_Frame);
            if PMM_Result = Kernel.Physical_Memory.Ok then
               Arch.MMU.Map_Page
                 (Root     => User_Root_Table,
                  Virtual  => User_Stack_Top
                              - Interfaces.Unsigned_64 (I)
                                * Arch.MMU.Page_Size,
                  Physical => Extra_Frame,
                  Flags    => Arch.MMU.User_RW,
                  Result   => MMU_Result);
            else
               MMU_Result := Arch.MMU.Allocation_Failed;
            end if;
         end;
      end loop;
   end if;

   --  Init's IPC buffer page (docs/IPC.md): fixed user VA, zeroed to
   --  avoid leaking stale frame contents to userspace.
   if Initrd_Result = Kernel.Initrd.Ok
     and then MMU_Result = Arch.MMU.Ok
     and then Init_IPC_Buffer_Frame /= 0
   then
      Arch.MMU.Map_Page
        (Root     => User_Root_Table,
         Virtual  => Kernel.Tasks.IPC_Buffer_VA,
         Physical => Init_IPC_Buffer_Frame,
         Flags    => Arch.MMU.User_RW,
         Result   => MMU_Result);
   end if;

   if Initrd_Result = Kernel.Initrd.Ok
     and then MMU_Result = Arch.MMU.Ok
     and then Init_IPC_Buffer_Frame /= 0
   then
      declare
         type Page_Words is array (1 .. 512) of Interfaces.Unsigned_64;
         Buffer_Page : Page_Words
           with Address => System'To_Address
             (System.Storage_Elements.Integer_Address
               (Arch.Phys_To_Virt (Init_IPC_Buffer_Frame)));
      begin
         Buffer_Page := (others => 0);
      end;
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
        (Image       => (Kind => Kernel.ELF.Physmap_Bytes,
                         Base => Init_Image_Base),
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

   if Init_IPC_Buffer_Frame /= 0 then
      Kernel.Tasks.Set_IPC_Buffer
        (TCB      => Init_Task,
         Phys_PA => Init_IPC_Buffer_Frame);
   end if;

   --  Bootinfo page + boot-file image caps (docs/IPC.md): init's
   --  namespace is one cap per initrd file at handles 1..N, listed
   --  by name in the read-only bootinfo page, so init hardcodes no
   --  handle numbers.
   if User_Root_Table /= 0 then
      declare
         Bootinfo_Result : Kernel.Bootinfo.Status;
         Bootinfo_Broken : Boolean := False;

         procedure Add_Bootinfo
           (Handle : Kernel.Capabilities.U64;
            Kind   : Kernel.Capabilities.Object_Kind;
            Rights : Kernel.Capabilities.Rights;
            Name   : String)
         is
         begin
            if not Bootinfo_Broken then
               Kernel.Bootinfo.Add
                 (Handle      => Handle,
                  Kind        =>
                    Kernel.Capabilities.U64
                      (Kernel.Capabilities.Object_Kind'Pos (Kind)),
                  Rights_Mask => Kernel.Capabilities.To_Mask (Rights),
                  Name        => Name,
                  Result      => Bootinfo_Result);
               Bootinfo_Broken := Bootinfo_Result /= Kernel.Bootinfo.Ok;
            end if;
         end Add_Bootinfo;
      begin
         Kernel.Bootinfo.Install
           (Root   => User_Root_Table,
            Result => Bootinfo_Result);

         if Bootinfo_Result = Kernel.Bootinfo.Ok then
            for Index in 1 .. Kernel.Boot_Files.File_Count loop
               Kernel.Tasks.Insert_Cap_At
                 (TCB    => Init_Task,
                  Cap    => Kernel.Capabilities.Handle (Index),
                  Kind   => Kernel.Capabilities.Boot_File_Object,
                  Object => Kernel.Boot_Files.File_Object (Index),
                  Rights => Boot_File_Rights,
                  Badge  => 0,
                  Result => Result);
               exit when Result /= Kernel.Capabilities.Ok;
               Add_Bootinfo (Kernel.Capabilities.U64 (Index),
                             Kernel.Capabilities.Boot_File_Object,
                             Boot_File_Rights,
                             Kernel.Boot_Files.File_Name (Index));
            end loop;

            --  Device-plumbing authority (io_map / irq_create) at
            --  the first handle past the boot files.
            if Result = Kernel.Capabilities.Ok then
               Kernel.Tasks.Insert_Cap_At
                 (TCB    => Init_Task,
                  Cap    => Kernel.Capabilities.Handle
                    (Kernel.Boot_Files.File_Count + 1),
                  Kind   => Kernel.Capabilities.Kernel_Object,
                  Object => Device_Resource_Object'Address,
                  Rights => Device_Resource_Rights,
                  Badge  => 0,
                  Result => Result);
               Add_Bootinfo
                 (Kernel.Capabilities.U64
                    (Kernel.Boot_Files.File_Count + 1),
                  Kernel.Capabilities.Kernel_Object,
                  Device_Resource_Rights,
                  "device_resource");
            end if;

            --  Admin introspection authority (cap_info /
            --  thread_regs) at the next handle.
            if Result = Kernel.Capabilities.Ok then
               Kernel.Tasks.Insert_Cap_At
                 (TCB    => Init_Task,
                  Cap    => Kernel.Capabilities.Handle
                    (Kernel.Boot_Files.File_Count + 2),
                  Kind   => Kernel.Capabilities.Admin_Object,
                  Object => Admin_Resource_Object'Address,
                  Rights => Admin_Resource_Rights,
                  Badge  => 0,
                  Result => Result);
               Add_Bootinfo
                 (Kernel.Capabilities.U64
                    (Kernel.Boot_Files.File_Count + 2),
                  Kernel.Capabilities.Admin_Object,
                  Admin_Resource_Rights,
                  "admin");
            end if;

            if not Bootinfo_Broken
              and then Result = Kernel.Capabilities.Ok
            then
               Board.UART.Put_Line ("bootinfo online");
            else
               Board.UART.Put_Line ("bootinfo incomplete");
            end if;
         else
            Board.UART.Put_Line ("bootinfo install failed");
         end if;
      end;
   end if;

   Kernel.Interrupts.Initialize;
   Kernel.Processes.Initialize;

   Kernel.Scheduler.Initialize;
   Kernel.Scheduler.Set_Current
     (TCB    => Init_Task'Unchecked_Access,
      Result => Scheduler_Result);

   Board.Interrupts.Initialize (Board.PLIC.Source_Id (UART_IRQ));
   Arch.Traps.Initialize;

   --  IOMMU: probes the DTB for riscv,iommu (qemu
   --  -machine iommu-sys=on); when present, PCI DMA is translated
   --  and restricted to explicitly authorized frames from here on.
   if DTB_Result = Kernel.Device_Tree.Ok then
      Arch.IOMMU.Initialize (Board.Device_Tree.Boot_DTB_Physical_Address);
   end if;

   if Initrd_Result = Kernel.Initrd.Ok
     and then ELF_Result = Kernel.ELF.Ok
   then
      Board.UART.Put_Line ("entering initrd init");

      --  Start secondary harts: PMM-allocated per-hart kernel stacks
      --  (contiguous bump runs) recorded in each hart's boot info
      --  block, then SBI HSM hart_start at secondary_boot.  A hart
      --  that fails to start is simply skipped; the system stays up
      --  with the harts that made it.
      for H in 1 .. Hart_Count - 1 loop
         declare
            Idx : constant Kernel.CPUs.CPU_Index :=
              Kernel.CPUs.CPU_Index (H);
            Trap_Base : Interfaces.Unsigned_64 := 0;
            Main_Base : Interfaces.Unsigned_64 := 0;
         begin
            Kernel.Physical_Memory.Allocate_Contiguous
              (Pages       => Kernel.CPUs.Trap_Stack_Pages,
               Result      => PMM_Result,
               First_Frame => Trap_Base);
            if PMM_Result = Kernel.Physical_Memory.Ok then
               Kernel.Physical_Memory.Allocate_Contiguous
                 (Pages       => Kernel.CPUs.Main_Stack_Pages,
                  Result      => PMM_Result,
                  First_Frame => Main_Base);
            end if;

            if PMM_Result = Kernel.Physical_Memory.Ok then
               Kernel.CPUs.Set_Stacks
                 (CPU      => Idx,
                  Trap_Top => Trap_Base
                    + Interfaces.Unsigned_64 (Kernel.CPUs.Trap_Stack_Pages)
                      * Kernel.Physical_Memory.Page_Size,
                  Main_Top => Main_Base
                    + Interfaces.Unsigned_64 (Kernel.CPUs.Main_Stack_Pages)
                      * Kernel.Physical_Memory.Page_Size);
               Hart_Start_RC := Arch.SBI.Hart_Start
                 (Raw_Hart_Id => Kernel.CPUs.Raw_Id (Idx),
                  Entry_PA    => Arch.Kernel_Virt_To_Phys
                    (Interfaces.Unsigned_64
                      (System.Storage_Elements.To_Integer
                        (Secondary_Boot_Sym'Address))),
                  Opaque      => Kernel.CPUs.Info_Block_PA (Idx));
               if Hart_Start_RC /= 0 then
                  Board.UART.Put ("hart ");
                  Board.UART.Put_Decimal (H);
                  Board.UART.Put_Line (" start failed");
               end if;
            else
               Board.UART.Put ("hart ");
               Board.UART.Put_Decimal (H);
               Board.UART.Put_Line (" stack allocation failed");
            end if;
         end;
      end loop;

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
