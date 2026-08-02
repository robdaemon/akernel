with System;
with System.Storage_Elements;
with Ada.Unchecked_Conversion;
with Arch;
with Arch.MMU;
with Kernel.ELF;
with Kernel.Memory;
with Kernel.Objects;
with Kernel.Physical_Memory;
with Kernel.Scheduler;

package body Kernel.Processes is
   use type Interfaces.Unsigned_64;
   use type System.Address;
   use type Arch.MMU.Status;
   use type Kernel.Capabilities.Status;
   use type Kernel.ELF.Status;
   use type Kernel.Physical_Memory.Status;
   use type Kernel.Scheduler.Status;
   use type Kernel.Tasks.Process_Access;
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

   --  User stack pages per spawned process (fuzz overflowed the
   --  original single page with on-stack buffers).
   Stack_Pages : constant := 4;

   --  ELF image handed to the loader: a byte source (physmap range
   --  or memory-object frames) + size.
   type Program_Image is record
      Bytes : Kernel.ELF.Source;
      Size  : U64;
   end record;

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

   --  Mint the parent's grant-list entries (in the parent's IPC
   --  buffer page) into the child's cap table at handles 1..N.
   --  Rights are monotonically decreasing: the requested mask must
   --  be a subset of the parent entry's rights.
   procedure Grant_List_Caps
     (Parent      : Kernel.Tasks.Thread_Access;
      PCB         : in out Kernel.Tasks.Process_Control_Block;
      Grant_Count : U64;
      Result      : out Status)
   is
      use type Kernel.Capabilities.Object_Kind;
      use System.Storage_Elements;

      type Grant_Entry is record
         Source_Handle : U64;
         Rights_Mask   : U64;
         Badge         : U64;
      end record;

      type Grant_Array is array (0 .. Max_Grants - 1) of Grant_Entry;

      Parent_Buffer_PA : U64;
      Cap_Result       : Kernel.Capabilities.Status;
      Cap_Info         : Kernel.Capabilities.Cap_Entry;
      Requested        : Kernel.Capabilities.Rights;
   begin
      Result := Ok;

      if Grant_Count = 0 then
         return;
      end if;

      if Grant_Count > U64 (Max_Grants) or else Parent = null then
         Result := Cap_Failed;
         return;
      end if;

      Parent_Buffer_PA := Kernel.Tasks.IPC_Buffer_PA (Parent.all);
      if Parent_Buffer_PA = 0 then
         Result := Cap_Failed;
         return;
      end if;

      declare
         Grants : Grant_Array
           with Address => System'To_Address
             (Integer_Address (Arch.Phys_To_Virt (Parent_Buffer_PA))
              + Integer_Address (Grant_List_Offset));
      begin
         for Index in 0 .. Natural (Grant_Count) - 1 loop
            if Grants (Index).Source_Handle >
              U64 (Kernel.Capabilities.Handle'Last)
            then
               Result := Cap_Failed;
               return;
            end if;

            Kernel.Tasks.Lookup_Cap
              (TCB       => Parent.all,
               Cap       => Kernel.Capabilities.Handle
                 (Grants (Index).Source_Handle),
               Result    => Cap_Result,
               Out_Entry => Cap_Info);

            if Cap_Result /= Kernel.Capabilities.Ok
              or else Cap_Info.Kind = Kernel.Capabilities.Reply_Object
              or else (Grants (Index).Rights_Mask
                       and not Kernel.Capabilities.Valid_Rights_Mask) /= 0
            then
               Result := Cap_Failed;
               return;
            end if;

            Requested := Kernel.Capabilities.To_Rights
              (Grants (Index).Rights_Mask);

            if not Kernel.Capabilities.Has_Rights
              (Cap_Info.Rights, Requested)
            then
               Result := Cap_Failed;
               return;
            end if;

            Kernel.Tasks.Insert_Process_Cap_At
              (PCB    => PCB,
               Cap    => Kernel.Capabilities.Handle (Index + 1),
               Kind   => Cap_Info.Kind,
               Object => Cap_Info.Object,
               Rights => Requested,
               Badge  => Grants (Index).Badge,
               Result => Cap_Result);

            if Cap_Result /= Kernel.Capabilities.Ok then
               Result := Cap_Failed;
               return;
            end if;
         end loop;
      end;
   end Grant_List_Caps;

   procedure Destroy_Address_Space (Root : U64) is
      Destroy_Result : Arch.MMU.Status;
   begin
      if Root /= 0 then
         Arch.MMU.Destroy_User_Address_Space (Root, Destroy_Result);
      end if;
   end Destroy_Address_Space;

   --  Close_Caps must be True only once the slot's thread is
   --  initialized (grant minting and later): caps are then closed
   --  through the dispatcher so cleanup hooks/refcount releases run.
   --  Earlier failures use a raw table reset (only the pinned
   --  address-space cap can be present).
   procedure Discard_Slot
     (Slot       : Process_Index;
      Close_Caps : Boolean)
   is
      Stack_Top  : constant U64 :=
        Kernel.Tasks.Kernel_Stack_Top (Threads (Slot));
      PMM_Result : Kernel.Physical_Memory.Status;
      Cap_Result : Kernel.Capabilities.Status;
   begin
      if Stack_Top /= 0 then
         Kernel.Physical_Memory.Deallocate_Frame
           (Frame  => Stack_Top - Kernel.Physical_Memory.Page_Size,
            Result => PMM_Result);
         Kernel.Tasks.Set_Kernel_Stack_Top (Threads (Slot), 0);
      end if;

      Kernel.Tasks.Set_State (Threads (Slot), Kernel.Tasks.Dead);
      Kernel.Tasks.Set_Queued (Threads (Slot), False);
      if Close_Caps then
         for Cap in Kernel.Capabilities.Handle loop
            Kernel.Tasks.Close_Cap
              (Threads (Slot)'Unchecked_Access, Cap, Cap_Result);
         end loop;
      else
         Kernel.Tasks.Reset_Process_Caps (Processes (Slot));
      end if;
      Kernel.Tasks.Set_Process_State
        (PCB       => Processes (Slot),
         New_State => Kernel.Tasks.Process_Dead);
      Used (Slot) := False;
   end Discard_Slot;

   procedure Spawn_Image
     (Parent      : Kernel.Tasks.Thread_Access;
      Image       : Program_Image;
      Grant_Count : U64;
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
      Root               : U64 := 0;
      Stack_Frame        : U64 := 0;
      Kernel_Stack_Frame : U64 := 0;
      IPC_Buffer_Frame   : U64 := 0;
      Start_PC           : U64;
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

      for I in 2 .. Stack_Pages loop
         Kernel.Physical_Memory.Allocate_Frame (PMM_Result, Stack_Frame);
         if PMM_Result /= Kernel.Physical_Memory.Ok then
            Result := Load_Failed;
            Destroy_Address_Space (Root);
            return;
         end if;

         Arch.MMU.Map_Page
           (Root     => Root,
            Virtual  => Stack_Top - U64 (I) * Arch.MMU.Page_Size,
            Physical => Stack_Frame,
            Flags    => Arch.MMU.User_RW,
            Result   => MMU_Result);

         if MMU_Result /= Arch.MMU.Ok then
            Result := Load_Failed;
            Kernel.Physical_Memory.Deallocate_Frame
              (Stack_Frame, PMM_Result);
            Destroy_Address_Space (Root);
            return;
         end if;
      end loop;

      --  Per-thread IPC buffer page (docs/IPC.md): fixed user VA,
      --  kernel-allocated, zeroed to avoid cross-process data leaks,
      --  freed by user-address-space teardown. Physical address is
      --  recorded in the TCB below.
      Kernel.Physical_Memory.Allocate_Frame (PMM_Result, IPC_Buffer_Frame);
      if PMM_Result /= Kernel.Physical_Memory.Ok then
         Result := Load_Failed;
         Destroy_Address_Space (Root);
         return;
      end if;

      Arch.MMU.Map_Page
        (Root     => Root,
         Virtual  => Kernel.Tasks.IPC_Buffer_VA,
         Physical => IPC_Buffer_Frame,
         Flags    => Arch.MMU.User_RW,
         Result   => MMU_Result);

      if MMU_Result /= Arch.MMU.Ok then
         Result := Load_Failed;
         Kernel.Physical_Memory.Deallocate_Frame
           (IPC_Buffer_Frame, PMM_Result);
         Destroy_Address_Space (Root);
         return;
      end if;

      declare
         type Page_Words is array (1 .. 512) of U64;
         Buffer_Page : Page_Words
           with Address => System'To_Address
             (System.Storage_Elements.Integer_Address
               (Arch.Phys_To_Virt (IPC_Buffer_Frame)));
      begin
         Buffer_Page := (others => 0);
      end;

      Kernel.Physical_Memory.Allocate_Frame
        (PMM_Result, Kernel_Stack_Frame);
      if PMM_Result /= Kernel.Physical_Memory.Ok then
         Result := Load_Failed;
         Destroy_Address_Space (Root);
         return;
      end if;

      --  The trap trampoline builds its frame on this stack before
      --  switching satp, so the kernel stack must be visible in the
      --  owning user address space (supervisor, global).  It is
      --  mapped at its physmap VA, matching the sscratch invariant
      --  (physmap VA of the kernel stack top).
      Arch.MMU.Map_Page
        (Root     => Root,
         Virtual  => Arch.Phys_To_Virt (Kernel_Stack_Frame),
         Physical => Kernel_Stack_Frame,
         Flags    => Arch.MMU.Kernel_RW,
         Result   => MMU_Result);

      if MMU_Result /= Arch.MMU.Ok then
         Result := Load_Failed;
         Kernel.Physical_Memory.Deallocate_Frame
           (Kernel_Stack_Frame, PMM_Result);
         Destroy_Address_Space (Root);
         return;
      end if;

      Kernel.ELF.Load_Into_Address_Space
        (Image       => Image.Bytes,
         Image_Size  => Image.Size,
         Root        => Root,
         Result      => ELF_Result,
         Entry_Point => Start_PC);

      if ELF_Result /= Kernel.ELF.Ok then
         Result := Load_Failed;
         Kernel.Physical_Memory.Deallocate_Frame
           (Kernel_Stack_Frame, PMM_Result);
         Destroy_Address_Space (Root);
         return;
      end if;

      New_Process_Id := Kernel.Tasks.Process_Id (Natural (Slot) + 4);
      New_Thread_Id := Kernel.Tasks.Thread_Id (Natural (Slot) + 4);
      Kernel.Tasks.Initialize_Process (Processes (Slot), New_Process_Id);
      Kernel.Tasks.Set_Process_Address_Space_Root (Processes (Slot), Root);
      Kernel.Tasks.Install_Address_Space_Cap (Processes (Slot), Cap_Result);
      if Cap_Result /= Kernel.Capabilities.Ok then
         Result := Cap_Failed;
         Discard_Slot (Slot, Close_Caps => False);
         Destroy_Address_Space (Root);
         return;
      end if;

      Kernel.Tasks.Initialize_Thread
        (TCB     => Threads (Slot),
         Id      => New_Thread_Id,
         Process => Processes (Slot)'Unchecked_Access);
      Kernel.Tasks.Set_Kernel_Stack_Top
        (TCB       => Threads (Slot),
         Stack_Top => Kernel_Stack_Frame + Kernel.Physical_Memory.Page_Size);
      Kernel.Tasks.Set_IPC_Buffer
        (TCB      => Threads (Slot),
         Phys_PA => IPC_Buffer_Frame);
      Kernel.Tasks.Initialize_Context
        (TCB       => Threads (Slot),
         PC        => Start_PC,
         Stack     => Stack_Top,
         User_Satp => Arch.MMU.Satp_Value (Root));

      Grant_List_Caps (Parent, Processes (Slot), Grant_Count, Result);
      if Result /= Ok then
         Discard_Slot (Slot, Close_Caps => True);
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
         Discard_Slot (Slot, Close_Caps => True);
         Destroy_Address_Space (Root);
         return;
      end if;

      Kernel.Scheduler.Add_Task
        (TCB    => Threads (Slot)'Unchecked_Access,
         Result => Sched_Result);

      if Sched_Result /= Kernel.Scheduler.Ok then
         Kernel.Tasks.Close_Cap (Parent, Process_Cap, Cap_Result);
         Process_Cap := Kernel.Capabilities.Invalid_Handle;
         Result := Scheduler_Failed;
         Discard_Slot (Slot, Close_Caps => True);
         Destroy_Address_Space (Root);
         return;
      end if;

      Used (Slot) := True;
      Result := Ok;
   end Spawn_Image;

   --  Spawn ABI v2 (docs/IPC.md): the image is a Boot_File_Object
   --  cap held by the parent, not a manifest path slice. The cap
   --  must carry Read + Execute rights; the kernel never sees a
   --  path.
   procedure Spawn_Boot_Image
     (Parent      : Kernel.Tasks.Thread_Access;
      Image_Cap   : Kernel.Capabilities.Handle;
      Grant_Count : U64;
      Result      : out Status;
      Process_Cap : out Kernel.Capabilities.Handle)
   is
      use type Kernel.Capabilities.Object_Kind;

      type Boot_File_Access is access all Kernel.Objects.Boot_File;

      function To_Boot_File is new Ada.Unchecked_Conversion
        (Source => System.Address,
         Target => Boot_File_Access);

      Cap_Result : Kernel.Capabilities.Status;
      Cap_Info   : Kernel.Capabilities.Cap_Entry;
      File       : Boot_File_Access;
      MO_Pages   : U64;
      Image      : Program_Image;
   begin
      Process_Cap := Kernel.Capabilities.Invalid_Handle;

      if Parent = null then
         Result := Invalid_Parent;
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Parent.all,
         Cap       => Image_Cap,
         Result    => Cap_Result,
         Out_Entry => Cap_Info);

      if Cap_Result /= Kernel.Capabilities.Ok
        or else not Cap_Info.Rights.Read
        or else (Cap_Info.Kind /= Kernel.Capabilities.Boot_File_Object
                 and then Cap_Info.Kind
                   /= Kernel.Capabilities.Memory_Object)
      then
         Result := Invalid_Program;
         return;
      end if;

      --  Boot files must additionally carry Execute; a memory object
      --  only needs Read (spawn v2: image staged by a file server).
      if Cap_Info.Kind = Kernel.Capabilities.Boot_File_Object then
         if not Cap_Info.Rights.Execute then
            Result := Invalid_Program;
            return;
         end if;

         File := To_Boot_File (Cap_Info.Object);
         if File = null or else File.Length = 0 then
            Result := Invalid_Program;
            return;
         end if;

         Image :=
           (Bytes => (Kind => Kernel.ELF.Physmap_Bytes, Base => File.Base),
            Size  => File.Length);
      else
         MO_Pages := Kernel.Memory.Page_Count (Cap_Info.Object);
         if MO_Pages = 0 then
            Result := Invalid_Program;
            return;
         end if;

         Image :=
           (Bytes => (Kind   => Kernel.ELF.Object_Frames,
                      Object => Cap_Info.Object),
            Size  => MO_Pages * Arch.MMU.Page_Size);
      end if;

      Spawn_Image (Parent, Image, Grant_Count, Result, Process_Cap);
   end Spawn_Boot_Image;

   --  Runs cleanup hooks and closes every cap in the owning process's
   --  table. Runs at exit and again at reap; closing each cap makes
   --  the second pass a no-op so refcounted objects are released
   --  exactly once.
   procedure Cleanup_Cap_Refs (Thread : Kernel.Tasks.Thread_Access) is
      Process    : Kernel.Tasks.Process_Access;
      Cap_Result : Kernel.Capabilities.Status;
   begin
      if Thread = null then
         return;
      end if;

      Process := Kernel.Tasks.Owning_Process (Thread.all);
      if Process = null then
         return;
      end if;

      for Cap in Kernel.Capabilities.Handle'Succ
        (Kernel.Capabilities.Invalid_Handle) ..
          Kernel.Capabilities.Handle'Last
      loop
         Kernel.Tasks.Close_Cap (Thread, Cap, Cap_Result);
      end loop;
   end Cleanup_Cap_Refs;

   procedure Mark_Exited (Thread : Kernel.Tasks.Thread_Access) is
      Process : Kernel.Tasks.Process_Access;
   begin
      if Thread = null then
         return;
      end if;

      Cleanup_Cap_Refs (Thread);
      Process := Kernel.Tasks.Owning_Process (Thread.all);
      if Process /= null then
         Kernel.Tasks.Set_Process_State
           (PCB       => Process.all,
            New_State => Kernel.Tasks.Process_Dead);
      end if;
   end Mark_Exited;

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

      Kernel.Tasks.Close_Cap (Parent, Process_Cap, Cap_Result);
      if Cap_Result /= Kernel.Capabilities.Ok then
         Result := Cap_Failed;
         return;
      end if;

      Cleanup_Cap_Refs (Threads (Slot)'Unchecked_Access);
      Destroy_Address_Space
        (Kernel.Tasks.Process_Address_Space_Root (Processes (Slot)));
      Kernel.Tasks.Set_Process_Address_Space_Root (Processes (Slot), 0);
      Discard_Slot (Slot, Close_Caps => False);
      Result := Ok;
   end Reap_Process;
end Kernel.Processes;
