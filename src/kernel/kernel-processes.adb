with System;
with Arch.MMU;
with Kernel.ELF;
with Kernel.Physical_Memory;
with Kernel.Program_Loader;
with Kernel.Scheduler;

package body Kernel.Processes is
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type Arch.MMU.Status;
   use type Kernel.Capabilities.Status;
   use type Kernel.ELF.Status;
   use type Kernel.Physical_Memory.Status;
   use type Kernel.Program_Loader.Status;
   use type Kernel.Scheduler.Status;
   use type Kernel.Tasks.Process_State;
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;

   Max_Process_Slots : constant := 8;
   type Process_Index is range 0 .. Max_Process_Slots - 1;
   type Process_Slot_Array is array (Process_Index)
     of aliased Kernel.Tasks.Process_Control_Block;
   type Thread_Slot_Array is array (Process_Index)
     of aliased Kernel.Tasks.Thread_Control_Block;
   type Slot_Used_Array is array (Process_Index) of Boolean;

   Processes : Process_Slot_Array;
   Threads   : Thread_Slot_Array;
   Used      : Slot_Used_Array := (others => False);

   Stack_Top : constant U64 := 16#7000_0000#;

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

   IRQ_Rights : constant Kernel.Capabilities.Rights :=
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

   Process_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => True,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => False,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => False,
      Manage   => True);

   procedure Initialize is
   begin
      Used := (others => False);
   end Initialize;

   procedure Grant_Requested_Caps
     (Parent     : Kernel.Tasks.Thread_Access;
      PCB        : in out Kernel.Tasks.Process_Control_Block;
      Grant_Mask : U64;
      Result     : out Status)
   is
      use type Kernel.Capabilities.Object_Kind;

      Cap_Result : Kernel.Capabilities.Status;
      Cap_Info   : Kernel.Capabilities.Cap_Entry;
   begin
      Result := Ok;

      if (Grant_Mask and UART_MMIO_Grant_Bit) /= 0 then
         Kernel.Tasks.Lookup_Cap
           (TCB       => Parent.all,
            Cap       => 1,
            Result    => Cap_Result,
            Out_Entry => Cap_Info);

         if Cap_Result /= Kernel.Capabilities.Ok
           or else Cap_Info.Kind /= Kernel.Capabilities.MMIO_Object
           or else not Cap_Info.Rights.Map
         then
            Result := Cap_Failed;
            return;
         end if;

         Kernel.Tasks.Insert_Process_Cap_At
           (PCB    => PCB,
            Cap    => 1,
            Kind   => Cap_Info.Kind,
            Object => Cap_Info.Object,
            Rights => MMIO_Map_Rights,
            Badge  => Cap_Info.Badge,
            Result => Cap_Result);

         if Cap_Result /= Kernel.Capabilities.Ok then
            Result := Cap_Failed;
            return;
         end if;
      end if;

      if (Grant_Mask and UART_IRQ_Grant_Bit) /= 0 then
         Kernel.Tasks.Lookup_Cap
           (TCB       => Parent.all,
            Cap       => 2,
            Result    => Cap_Result,
            Out_Entry => Cap_Info);

         if Cap_Result /= Kernel.Capabilities.Ok
           or else Cap_Info.Kind /= Kernel.Capabilities.IRQ_Object
           or else not Cap_Info.Rights.Wait
           or else not Cap_Info.Rights.Ack
         then
            Result := Cap_Failed;
            return;
         end if;

         Kernel.Tasks.Insert_Process_Cap_At
           (PCB    => PCB,
            Cap    => 2,
            Kind   => Cap_Info.Kind,
            Object => Cap_Info.Object,
            Rights => IRQ_Rights,
            Badge  => Cap_Info.Badge,
            Result => Cap_Result);

         if Cap_Result /= Kernel.Capabilities.Ok then
            Result := Cap_Failed;
         end if;
      end if;
   end Grant_Requested_Caps;

   procedure Destroy_Address_Space (Root : U64) is
      Destroy_Result : Arch.MMU.Status;
   begin
      if Root /= 0 then
         Arch.MMU.Destroy_User_Address_Space (Root, Destroy_Result);
      end if;
   end Destroy_Address_Space;

   procedure Discard_Slot
     (Slot : Process_Index)
   is
   begin
      Kernel.Tasks.Set_State (Threads (Slot), Kernel.Tasks.Dead);
      Kernel.Tasks.Set_Queued (Threads (Slot), False);
      Kernel.Tasks.Reset_Process_Caps (Processes (Slot));
      Kernel.Tasks.Set_Process_State
        (PCB       => Processes (Slot),
         New_State => Kernel.Tasks.Process_Dead);
      Used (Slot) := False;
   end Discard_Slot;

   procedure Spawn_Image
     (Parent      : Kernel.Tasks.Thread_Access;
      Image       : Kernel.Program_Loader.Program_Image;
      Grant_Mask  : U64;
      Result      : out Status;
      Process_Cap : out Kernel.Capabilities.Handle)
   is
      ELF_Result   : Kernel.ELF.Status;
      PMM_Result   : Kernel.Physical_Memory.Status;
      MMU_Result   : Arch.MMU.Status;
      Cap_Result   : Kernel.Capabilities.Status;
      Sched_Result : Kernel.Scheduler.Status;
      Slot         : Process_Index := Process_Index'First;
      Found_Slot   : Boolean := False;
      New_Process_Id : Kernel.Tasks.Process_Id;
      New_Thread_Id  : Kernel.Tasks.Thread_Id;
      Root         : U64 := 0;
      Stack_Frame  : U64 := 0;
      Start_PC     : U64;
   begin
      Process_Cap := Kernel.Capabilities.Invalid_Handle;

      if Parent = null then
         Result := Invalid_Parent;
         return;
      end if;

      for Candidate in Process_Index loop
         if not Used (Candidate) then
            Slot := Candidate;
            Found_Slot := True;
            exit;
         end if;
      end loop;

      if not Found_Slot then
         Result := No_Slot;
         return;
      end if;

      Arch.MMU.New_User_Address_Space (MMU_Result, Root);
      if MMU_Result /= Arch.MMU.Ok then
         Result := Load_Failed;
         return;
      end if;

      Kernel.Physical_Memory.Allocate_Frame (PMM_Result, Stack_Frame);
      if PMM_Result /= Kernel.Physical_Memory.Ok then
         Result := Load_Failed;
         Destroy_Address_Space (Root);
         return;
      end if;

      Arch.MMU.Map_Page
        (Root     => Root,
         Virtual  => Stack_Top - Arch.MMU.Page_Size,
         Physical => Stack_Frame,
         Flags    => Arch.MMU.User_RW,
         Result   => MMU_Result);

      if MMU_Result /= Arch.MMU.Ok then
         Result := Load_Failed;
         Kernel.Physical_Memory.Deallocate_Frame (Stack_Frame, PMM_Result);
         Destroy_Address_Space (Root);
         return;
      end if;

      Kernel.ELF.Load_Into_Address_Space
        (Image_Base  => Image.Base,
         Image_Size  => Image.Size,
         Root        => Root,
         Result      => ELF_Result,
         Entry_Point => Start_PC);

      if ELF_Result /= Kernel.ELF.Ok then
         Result := Load_Failed;
         Destroy_Address_Space (Root);
         return;
      end if;

      New_Process_Id := Kernel.Tasks.Process_Id (Natural (Slot) + 4);
      New_Thread_Id := Kernel.Tasks.Thread_Id (Natural (Slot) + 4);
      Kernel.Tasks.Initialize_Process (Processes (Slot), New_Process_Id);
      Kernel.Tasks.Set_Process_Address_Space_Root (Processes (Slot), Root);
      Kernel.Tasks.Initialize_Thread
        (TCB     => Threads (Slot),
         Id      => New_Thread_Id,
         Process => Processes (Slot)'Unchecked_Access);
      Kernel.Tasks.Initialize_Context
        (TCB   => Threads (Slot),
         PC    => Start_PC,
         Stack => Stack_Top);

      Grant_Requested_Caps (Parent, Processes (Slot), Grant_Mask, Result);
      if Result /= Ok then
         Discard_Slot (Slot);
         Destroy_Address_Space (Root);
         return;
      end if;

      Kernel.Tasks.Set_Process_State
        (PCB       => Processes (Slot),
         New_State => Kernel.Tasks.Process_Alive);

      Kernel.Tasks.Insert_Cap
        (TCB    => Parent.all,
         Kind   => Kernel.Capabilities.Process_Object,
         Object => Processes (Slot)'Address,
         Rights => Process_Rights,
         Badge  => U64 (New_Process_Id),
         Result => Cap_Result,
         Cap    => Process_Cap);

      if Cap_Result /= Kernel.Capabilities.Ok then
         Result := Cap_Failed;
         Process_Cap := Kernel.Capabilities.Invalid_Handle;
         Discard_Slot (Slot);
         Destroy_Address_Space (Root);
         return;
      end if;

      Kernel.Scheduler.Add_Task
        (TCB    => Threads (Slot)'Unchecked_Access,
         Result => Sched_Result);

      if Sched_Result /= Kernel.Scheduler.Ok then
         Kernel.Tasks.Close_Cap (Parent.all, Process_Cap, Cap_Result);
         Process_Cap := Kernel.Capabilities.Invalid_Handle;
         Result := Scheduler_Failed;
         Discard_Slot (Slot);
         Destroy_Address_Space (Root);
         return;
      end if;

      Used (Slot) := True;
      Result := Ok;
   end Spawn_Image;

   procedure Spawn_Program
     (Parent      : Kernel.Tasks.Thread_Access;
      Program_Id  : U64;
      Grant_Mask  : U64;
      Result      : out Status;
      Process_Cap : out Kernel.Capabilities.Handle)
   is
      Loader_Result : Kernel.Program_Loader.Status;
      Manifest      : Kernel.Program_Loader.Program_Manifest;
   begin
      Kernel.Program_Loader.Find
        (Program_Id => Program_Id,
         Result     => Loader_Result,
         Manifest   => Manifest);

      if Loader_Result = Kernel.Program_Loader.Invalid_Program then
         Result := Invalid_Program;
         Process_Cap := Kernel.Capabilities.Invalid_Handle;
         return;
      elsif Loader_Result /= Kernel.Program_Loader.Ok then
         Result := Load_Failed;
         Process_Cap := Kernel.Capabilities.Invalid_Handle;
         return;
      end if;

      Spawn_Image (Parent, Manifest.Image, Grant_Mask, Result, Process_Cap);
   end Spawn_Program;

   procedure Spawn_Boot_Path
     (Parent      : Kernel.Tasks.Thread_Access;
      Path_Offset : U64;
      Path_Length : U64;
      Grant_Mask  : U64;
      Result      : out Status;
      Process_Cap : out Kernel.Capabilities.Handle)
   is
      Loader_Result : Kernel.Program_Loader.Status;
      Image         : Kernel.Program_Loader.Program_Image;
   begin
      Kernel.Program_Loader.Find_By_Manifest_Path
        (Path_Offset => Path_Offset,
         Path_Length => Path_Length,
         Result      => Loader_Result,
         Image       => Image);

      if Loader_Result = Kernel.Program_Loader.Invalid_Program then
         Result := Invalid_Program;
         Process_Cap := Kernel.Capabilities.Invalid_Handle;
         return;
      elsif Loader_Result /= Kernel.Program_Loader.Ok then
         Result := Load_Failed;
         Process_Cap := Kernel.Capabilities.Invalid_Handle;
         return;
      end if;

      Spawn_Image (Parent, Image, Grant_Mask, Result, Process_Cap);
   end Spawn_Boot_Path;

   procedure Reap_Process
     (Parent      : Kernel.Tasks.Thread_Access;
      Process_Cap : Kernel.Capabilities.Handle;
      Result      : out Status)
   is
      use type Kernel.Capabilities.Object_Kind;

      Cap_Result : Kernel.Capabilities.Status;
      Cap_Info   : Kernel.Capabilities.Cap_Entry;
      Found      : Boolean := False;
      Slot       : Process_Index := Process_Index'First;
   begin
      if Parent = null then
         Result := Invalid_Parent;
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Parent.all,
         Cap       => Process_Cap,
         Result    => Cap_Result,
         Out_Entry => Cap_Info);

      if Cap_Result /= Kernel.Capabilities.Ok
        or else Cap_Info.Kind /= Kernel.Capabilities.Process_Object
        or else not Cap_Info.Rights.Manage
      then
         Result := Cap_Failed;
         return;
      end if;

      for Candidate in Process_Index loop
         if Used (Candidate)
           and then Cap_Info.Object = Processes (Candidate)'Address
         then
            Slot := Candidate;
            Found := True;
            exit;
         end if;
      end loop;

      if not Found then
         Result := Invalid_Program;
         return;
      end if;

      if Kernel.Tasks.Lifecycle_State (Processes (Slot))
        /= Kernel.Tasks.Process_Dead
        or else Kernel.Tasks.State (Threads (Slot)) /= Kernel.Tasks.Dead
      then
         Result := Not_Exited;
         return;
      end if;

      Kernel.Tasks.Close_Cap (Parent.all, Process_Cap, Cap_Result);
      if Cap_Result /= Kernel.Capabilities.Ok then
         Result := Cap_Failed;
         return;
      end if;

      Destroy_Address_Space
        (Kernel.Tasks.Process_Address_Space_Root (Processes (Slot)));
      Kernel.Tasks.Set_Process_Address_Space_Root (Processes (Slot), 0);
      Discard_Slot (Slot);
      Result := Ok;
   end Reap_Process;
end Kernel.Processes;
