with System;
with System.Storage_Elements;
with Ada.Unchecked_Conversion;
with Arch;
with Arch.Context;
with Arch.MMU;
with Board.UART;
with Kernel.CPUs;
with Kernel.ELF;
with Kernel.Memory;
with Kernel.Objects;
with Kernel.Physical_Memory;
with Kernel.Scheduler;

package body Kernel.Processes is
   use type Interfaces.Unsigned_64;
   use type Interfaces.Integer_64;
   use type System.Address;
   use type Arch.MMU.Status;
   use type Kernel.Capabilities.Status;
   use type Kernel.Capabilities.Object_Kind;
   use type Kernel.ELF.Status;
   use type Kernel.Physical_Memory.Status;
   use type Kernel.Scheduler.Status;
   use type Kernel.Tasks.Process_Access;
   use type Kernel.Tasks.Process_State;
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;

   function To_Thread_Access is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Kernel.Tasks.Thread_Access);

   --  128 process slots, plus a separate thread table for
   --  multi-threaded processes (Milestone 66). Each process has
   --  one or more threads; threads share the process cap table.
   Max_Process_Slots : constant := 128;
   Max_Thread_Slots  : constant := 256;
   type Process_Index is range 0 .. Max_Process_Slots - 1;
   type Thread_Index  is range 0 .. Max_Thread_Slots - 1;
   type Process_Slot_Array is array (Process_Index)
     of aliased Kernel.Tasks.Process_Control_Block;
   type Thread_Slot_Array is array (Thread_Index)
     of aliased Kernel.Tasks.Thread_Control_Block;
   type Slot_Used_Array is array (Process_Index) of Boolean;
   type Thread_Used_Array is array (Thread_Index) of Boolean;

   Processes : Process_Slot_Array;
   Threads   : Thread_Slot_Array;
   Used      : Slot_Used_Array := (others => False);
   Thread_Used : Thread_Used_Array := (others => False);

   --  Per-process live thread count. A process stays alive as long
   --  as any of its threads are alive.
   Process_Thread_Count : array (Process_Index) of Natural :=
     (others => 0);

   --  Sign-preserving narrowing for info snapshots (priority is
   --  signed; the wire word is raw bits).
   function To_U64 is new Ada.Unchecked_Conversion
     (Source => Interfaces.Integer_64, Target => U64);
   subtype I64 is Interfaces.Integer_64;

   --  Free list over unused slots. Invariant: a slot is on the
   --  list iff Used (slot) = False. Spawn PEEKS the head and
   --  pops only at the commit point (Used := True), so the many
   --  Load_Failed early returns need no undo; Discard_Slot
   --  pushes only for a committed slot.
   Free_None : constant := -1;
   type Free_Index is range Free_None .. Max_Process_Slots - 1;
   Free_Next : array (Process_Index) of Free_Index :=
     (others => Free_None);
   Free_Head : Free_Index := Free_None;

   --  Free list over thread slots. Any free slot may hold a
   --  secondary thread; initial threads are pinned to their process
   --  slot index and freed by Discard_Slot.
   Thread_Free_None : constant := -1;
   type Thread_Free_Index is range Thread_Free_None
     .. Max_Thread_Slots - 1;
   Thread_Free_Next : array (Thread_Index) of Thread_Free_Index :=
     (others => Thread_Free_None);
   Thread_Free_Head : Thread_Free_Index := Thread_Free_None;

   --  Unique thread ids for secondary threads (initial threads keep
   --  their historical slot+4 values). Starts above any plausible
   --  process slot id.
   Next_Thread_Id : Kernel.Tasks.Thread_Id := 1024;

   --  Per-CPU deferred kernel-stack free list.  A thread's own stack
   --  cannot be deallocated while it is still executing on it; the
   --  frame is recorded here and freed once the hart has switched
   --  away (drained at every trap entry and in the idle loop).
   Max_Deferred_Stacks : constant := Max_Thread_Slots;
   Deferred_Stacks     : array (Kernel.CPUs.CPU_Index,
                                0 .. Max_Deferred_Stacks - 1) of U64;
   Deferred_Count      : array (Kernel.CPUs.CPU_Index) of Natural range
      0 .. Max_Deferred_Stacks :=
     (others => 0);

   --  Pid generations (milestone 51): pid = Generation * 256 +
   --  slot base, where the base (slot + 4 — pids 1..3 are the
   --  kernel-started processes outside this table) is unchanged
   --  for the slot's first use, so boot pids keep their
   --  historical values. Each REUSE of a slot bumps its
   --  generation, so a pid printed by Proc:, recorded as a
   --  spawner, or badged onto a process cap can never name a
   --  later occupant of the same slot. The generation wraps at
   --  2**23 (pid stays inside 31-bit Natural; ABA needs 8
   --  million reuses of one slot — accepted, same class as Unix
   --  pid wrap). The array lives OUTSIDE the PCB:
   --  Initialize_Process overwrites the whole record.
   Generation_Wrap : constant U64 := 2**23;
   Pid_Slot_Range  : constant U64 := 256;
   Slot_Generation : array (Process_Index) of U64 :=
     (others => 0);

   Stack_Top : constant U64 := 16#7000_0000#;

   --  User stack pages per spawned process (fuzz overflowed the
   --  original single page with on-stack buffers; 16 KiB then
   --  proved tight once test blocks accumulated ~10 KiB of
   --  sibling declare-block locals plus deep RPC call chains —
   --  38b bumped to 8 pages; the VA below stays clear of the IPC
   --  buffer at 0x6FFF_0000). Milestone 53a bumped to 16 pages:
   --  the ZCX unwinder's _Unwind_FrameState + per-frame walk adds
   --  ~8 KiB on the first raise (fuzz overflowed 8 pages by
   --  0x50 bytes inside uw_frame_state_for). 12 pages (48 KiB),
   --  NOT 16: the stack descends from 0x7000_0000 and the IPC
   --  buffer page owns 0x6FFF_0000, so 16 pages would collide.
   Stack_Pages : constant := 12;

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
      for I in Process_Index loop
         if I = Process_Index'Last then
            Free_Next (I) := Free_None;
         else
            Free_Next (I) := Free_Index (I + 1);
         end if;
      end loop;
      Free_Head := Free_Index (Process_Index'First);

      Thread_Used := (others => False);
      for I in Thread_Index range Max_Process_Slots .. Max_Thread_Slots - 1 loop
         if I = Thread_Index (Max_Thread_Slots - 1) then
            Thread_Free_Next (I) := Thread_Free_None;
         else
            Thread_Free_Next (I) := Thread_Free_Index (I + 1);
         end if;
      end loop;
      Thread_Free_Head := Thread_Free_Index (Max_Process_Slots);
      Process_Thread_Count := (others => 0);
      Next_Thread_Id := 1024;
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
      Thread_Slot : constant Thread_Index := Thread_Index (Slot);
      Stack_Top  : constant U64 :=
        Kernel.Tasks.Kernel_Stack_Top (Threads (Thread_Slot));
      PMM_Result : Kernel.Physical_Memory.Status;
      Cap_Result : Kernel.Capabilities.Status;
   begin
      if Stack_Top /= 0 then
         Kernel.Physical_Memory.Deallocate_Frame
           (Frame  => Stack_Top - Kernel.Physical_Memory.Page_Size,
            Result => PMM_Result);
         Kernel.Tasks.Set_Kernel_Stack_Top (Threads (Thread_Slot), 0);
      end if;

      Kernel.Tasks.Set_State (Threads (Thread_Slot), Kernel.Tasks.Dead);
      Kernel.Tasks.Set_Queued (Threads (Thread_Slot), False);
      if Close_Caps then
         for Cap in Kernel.Capabilities.Handle loop
            Kernel.Tasks.Close_Cap
              (Threads (Thread_Slot)'Unchecked_Access, Cap, Cap_Result,
               Thread_Dying => True);
         end loop;
      else
         Kernel.Tasks.Reset_Process_Caps (Processes (Slot));
      end if;
      Kernel.Tasks.Set_Process_State
        (PCB       => Processes (Slot),
         New_State => Kernel.Tasks.Process_Dead);
      if Thread_Used (Thread_Slot) then
         Thread_Used (Thread_Slot) := False;
      end if;
      Process_Thread_Count (Slot) := 0;
      if Used (Slot) then
         Used (Slot) := False;
         Free_Next (Slot) := Free_Head;
         Free_Head := Free_Index (Slot);
      end if;
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
      Thread_Slot  : Thread_Index := Thread_Index'First;
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

      if Free_Head = Free_None then
         Result := No_Slot;
         return;
      end if;
      --  Peek only; the pop happens at the commit point below so
      --  the Load_Failed early returns leave the list untouched.
      Slot := Process_Index (Free_Head);

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

      --  User stacks are executable (User_RWX): GNAT finalization
      --  trampolines for nested FD procedures live on the stack.
      Arch.MMU.Map_Page
        (Root     => Root,
         Virtual  => Stack_Top - Arch.MMU.Page_Size,
         Physical => Stack_Frame,
         Flags    => Arch.MMU.User_RWX,
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
            Flags    => Arch.MMU.User_RWX,
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

      New_Process_Id := Kernel.Tasks.Process_Id
        (Slot_Generation (Slot) * Pid_Slot_Range +
         U64 (Natural (Slot) + 4));
      Slot_Generation (Slot) :=
        (Slot_Generation (Slot) + 1) mod Generation_Wrap;
      New_Thread_Id := Kernel.Tasks.Thread_Id (Natural (Slot) + 4);
      Thread_Slot := Thread_Index (Slot);
      Kernel.Tasks.Initialize_Process (Processes (Slot), New_Process_Id);
      Kernel.Tasks.Set_Spawner_Id
        (Processes (Slot),
         Kernel.Tasks.Process_Id_Of
           (Kernel.Tasks.Owning_Process (Parent.all).all));
      Kernel.Tasks.Set_Process_Address_Space_Root (Processes (Slot), Root);
      Kernel.Tasks.Install_Address_Space_Cap (Processes (Slot), Cap_Result);
      if Cap_Result /= Kernel.Capabilities.Ok then
         Result := Cap_Failed;
         Discard_Slot (Slot, Close_Caps => False);
         Destroy_Address_Space (Root);
         return;
      end if;

      Kernel.Tasks.Initialize_Thread
        (TCB     => Threads (Thread_Slot),
         Id      => New_Thread_Id,
         Process => Processes (Slot)'Unchecked_Access);
      Kernel.Tasks.Set_Kernel_Stack_Top
        (TCB       => Threads (Thread_Slot),
         Stack_Top => Kernel_Stack_Frame + Kernel.Physical_Memory.Page_Size);
      Kernel.Tasks.Set_IPC_Buffer
        (TCB      => Threads (Thread_Slot),
         Phys_PA  => IPC_Buffer_Frame);
      Kernel.Tasks.Set_IPC_Buffer_VA
        (TCB     => Threads (Thread_Slot),
         User_VA => Kernel.Tasks.IPC_Buffer_VA);
      Kernel.Tasks.Initialize_Context
        (TCB       => Threads (Thread_Slot),
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
        (TCB    => Threads (Thread_Slot)'Unchecked_Access,
         Result => Sched_Result);

      if Sched_Result /= Kernel.Scheduler.Ok then
         Kernel.Tasks.Close_Cap (Parent, Process_Cap, Cap_Result);
         Process_Cap := Kernel.Capabilities.Invalid_Handle;
         Result := Scheduler_Failed;
         Discard_Slot (Slot, Close_Caps => True);
         Destroy_Address_Space (Root);
         return;
      end if;

      Thread_Used (Thread_Slot) := True;
      Process_Thread_Count (Slot) := 1;
      Used (Slot) := True;
      Free_Head := Free_Next (Slot);
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

   --  Map a live process pointer back to its slot index.
   function Process_Slot_Of
     (Process : Kernel.Tasks.Process_Access) return Process_Index
   is
   begin
      if Process = null then
         return Process_Index'First;
      end if;
      for I in Process_Index loop
         if Processes (I)'Address = Process.all'Address then
            return I;
         end if;
      end loop;
      return Process_Index'First;
   end Process_Slot_Of;

   --  The initial thread of a process lives in the thread table at
   --  the same index as its process slot.
   function Initial_Thread_Slot
     (Slot : Process_Index) return Thread_Index
   is (Thread_Index (Natural (Slot)));

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
         --  Thread_Dying => True: this IS thread-lifetime teardown
         --  (Mark_Exited), so cap-close hooks must run their dying
         --  variants: notification unbind (31a) and receiver-side
         --  endpoint failure (34). Discard_Slot already passes
         --  True; this exit path was the one that didn't, which
         --  left Fail_Endpoint unreachable for a voluntarily
         --  exiting server (milestone-34 burn).
         Kernel.Tasks.Close_Cap
           (Thread, Cap, Cap_Result, Thread_Dying => True);
      end loop;
   end Cleanup_Cap_Refs;

   procedure Remove_As_Waiter (Waiter : Kernel.Tasks.Thread_Access);
   procedure Wake_Thread_Waiters (Target : Kernel.Tasks.Thread_Access);

   procedure Mark_Exited
     (Thread : Kernel.Tasks.Thread_Access;
      Code   : Kernel.Capabilities.U64) is
      Process : Kernel.Tasks.Process_Access;
      Slot    : Process_Index;
   begin
      if Thread = null then
         return;
      end if;

      Process := Kernel.Tasks.Owning_Process (Thread.all);
      if Process = null then
         return;
      end if;

      Slot := Process_Slot_Of (Process);
      Kernel.Tasks.Set_Exit_Code (Process.all, Code);
      Kernel.Tasks.Set_Process_State
        (PCB       => Process.all,
         New_State => Kernel.Tasks.Process_Dead);

      --  Kill every thread of this process. The caller remains
      --  current and will be removed by Scheduler.Exit_Current.
      for T in Thread_Index loop
         if Thread_Used (T)
           and then Kernel.Tasks.Owning_Process (Threads (T)) = Process
         then
            declare
               Top : constant U64 :=
                 Kernel.Tasks.Kernel_Stack_Top (Threads (T));
               PMM_Result : Kernel.Physical_Memory.Status;
            begin
               if Top /= 0 then
                  if Threads (T)'Address /= Thread.all'Address then
                     Kernel.Physical_Memory.Deallocate_Frame
                       (Frame  => Top - Kernel.Physical_Memory.Page_Size,
                        Result => PMM_Result);
                  else
                     Free_Kernel_Stack_Later (Top);
                  end if;
                  Kernel.Tasks.Set_Kernel_Stack_Top (Threads (T), 0);
               end if;
            end;

            Kernel.Tasks.Set_State (Threads (T), Kernel.Tasks.Dead);
            Kernel.Tasks.Set_Queued (Threads (T), False);
            Remove_As_Waiter (Threads (T)'Unchecked_Access);
            Wake_Thread_Waiters (Threads (T)'Unchecked_Access);

            if Threads (T)'Address /= Thread.all'Address then
               declare
                  Ignore : Kernel.Scheduler.Status;
               begin
                  Kernel.Scheduler.Remove_Thread
                    (Threads (T)'Unchecked_Access, Ignore);
               end;
            end if;

            Thread_Used (T) := False;
            --  Initial slots are tied to their process slots; only
            --  secondary slots go back to the thread free list.
            if T >= Thread_Index (Max_Process_Slots) then
               Thread_Free_Next (T) := Thread_Free_Head;
               Thread_Free_Head := Thread_Free_Index (T);
            end if;
         end if;
      end loop;

      Process_Thread_Count (Slot) := 0;
      Cleanup_Cap_Refs (Thread);
   end Mark_Exited;

   Thread_Cap_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => False,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => False,
      Receive  => False,
      Wait     => True,
      Ack      => False,
      Transfer => False,
      Manage   => True);

   function Priority_From_Bits
     (Bits : U64) return Kernel.Tasks.Thread_Priority
   is
      function To_I64 is new Ada.Unchecked_Conversion
        (Source => U64, Target => Interfaces.Integer_64);
      P       : constant Interfaces.Integer_64 := To_I64 (Bits);
      Clamped : constant Interfaces.Integer_64 :=
        Interfaces.Integer_64'Max
          (-128, Interfaces.Integer_64'Min (127, P));
   begin
      return Kernel.Tasks.Thread_Priority (Clamped);
   end Priority_From_Bits;

   procedure Thread_Create
     (Parent      : Kernel.Tasks.Thread_Access;
      Thread_Cap  : out Kernel.Capabilities.Handle;
      Result      : out Status)
   is
      use type Kernel.Capabilities.Object_Kind;

      Current       : constant Kernel.Tasks.Thread_Access := Parent;
      Process       : Kernel.Tasks.Process_Access;
      P_Slot        : Process_Index;
      T_Slot        : Thread_Index;
      Stack_Cap     : Kernel.Capabilities.Handle;
      IPC_Cap       : Kernel.Capabilities.Handle;
      Stack_Info    : Kernel.Capabilities.Cap_Entry;
      IPC_Info      : Kernel.Capabilities.Cap_Entry;
      Cap_Result    : Kernel.Capabilities.Status;
      MMU_Result    : Arch.MMU.Status;
      PMM_Result    : Kernel.Physical_Memory.Status;
      Sched_Result  : Kernel.Scheduler.Status;
      KStack_Frame  : U64 := 0;
      Stack_VA      : U64;
      Stack_Pages   : U64;
      Entry_PC      : U64;
      Arg           : U64;
      TLS_Base      : U64;
      IPC_VA        : U64;
      Priority_Bits : U64;
      New_Priority  : Kernel.Tasks.Thread_Priority;
      New_Thread_Id : Kernel.Tasks.Thread_Id;
      New_Cap       : Kernel.Capabilities.Handle;

      procedure Undo_Stack_Map (Mapped : U64)
      is
         Ignore : Arch.MMU.Status;
      begin
         for Page in U64 range 0 .. Mapped - 1 loop
            Arch.MMU.Unmap_Borrowed_Page
              (Root    => Kernel.Tasks.Address_Space_Root (Current.all),
               Virtual => Stack_VA - (Stack_Pages - Page) *
                 Arch.MMU.Page_Size,
               Result  => Ignore);
         end loop;
      end Undo_Stack_Map;

      function IPC_Word (Offset : U64) return U64 is
         Cell : U64
           with Address => System'To_Address
             (System.Storage_Elements.Integer_Address
               (Arch.Phys_To_Virt
                  (Kernel.Tasks.IPC_Buffer_PA (Current.all)) + Offset));
      begin
         return Cell;
      end IPC_Word;

   begin
      Thread_Cap := Kernel.Capabilities.Invalid_Handle;
      Result := Invalid_Parent;

      if Current = null then
         return;
      end if;

      Process := Kernel.Tasks.Owning_Process (Current.all);
      if Process = null then
         return;
      end if;
      P_Slot := Process_Slot_Of (Process);
      Result := No_Slot;

      if Kernel.Tasks.IPC_Buffer_PA (Current.all) = 0 then
         Result := Invalid_Program;
         return;
      end if;

      --  Parameter block lives in the caller's IPC buffer.
      Stack_VA      := IPC_Word (8);
      Stack_Pages   := IPC_Word (16);
      Entry_PC      := IPC_Word (24);
      Arg           := IPC_Word (32);
      TLS_Base      := IPC_Word (40);
      Priority_Bits := IPC_Word (48);
      Stack_Cap     := Kernel.Capabilities.Handle (IPC_Word (56));
      IPC_Cap       := Kernel.Capabilities.Handle (IPC_Word (64));

      New_Priority := Priority_From_Bits (Priority_Bits);

      --  Basic VA sanity: user region [0x4000_0000, 0x8000_0000).
      if Stack_VA mod Arch.MMU.Page_Size /= 0
        or else Stack_VA < 16#4000_0000#
        or else Stack_VA > 16#8000_0000#
        or else Stack_Pages * Arch.MMU.Page_Size >
          Stack_VA - 16#4000_0000#
      then
         Result := Invalid_Program;
         return;
      end if;

      IPC_VA := IPC_Word (72);
      if IPC_VA mod Arch.MMU.Page_Size /= 0
        or else IPC_VA < 16#4000_0000#
        or else IPC_VA > 16#8000_0000#
      then
         Result := Invalid_Program;
         return;
      end if;

      --  Validate stack cap.
      Kernel.Tasks.Lookup_Cap
        (TCB       => Current.all,
         Cap       => Stack_Cap,
         Result    => Cap_Result,
         Out_Entry => Stack_Info);
      if Cap_Result /= Kernel.Capabilities.Ok
        or else Stack_Info.Kind /= Kernel.Capabilities.Memory_Object
        or else not Stack_Info.Rights.Map
        or else not Stack_Info.Rights.Read
        or else not Stack_Info.Rights.Write
        or else Stack_Pages = 0
        or else Stack_Pages > Kernel.Memory.Page_Count (Stack_Info.Object)
      then
         Result := Invalid_Program;
         return;
      end if;

      --  Validate IPC buffer cap.
      Kernel.Tasks.Lookup_Cap
        (TCB       => Current.all,
         Cap       => IPC_Cap,
         Result    => Cap_Result,
         Out_Entry => IPC_Info);
      if Cap_Result /= Kernel.Capabilities.Ok
        or else IPC_Info.Kind /= Kernel.Capabilities.Memory_Object
        or else not IPC_Info.Rights.Map
        or else not IPC_Info.Rights.Read
        or else not IPC_Info.Rights.Write
        or else Kernel.Memory.Page_Count (IPC_Info.Object) < 1
      then
         Result := Invalid_Program;
         return;
      end if;

      --  Reserve a kernel stack for the new thread.
      Kernel.Physical_Memory.Allocate_Frame (PMM_Result, KStack_Frame);
      if PMM_Result /= Kernel.Physical_Memory.Ok then
         Result := Load_Failed;
         return;
      end if;

      --  Map the kernel stack into the process address space at the
      --  physmap VA, just like the initial thread in Spawn_Image, so
      --  the trap handler can push onto it before switching page tables.
      Arch.MMU.Map_Page
        (Root     => Kernel.Tasks.Address_Space_Root (Current.all),
         Virtual  => Arch.Phys_To_Virt (KStack_Frame),
         Physical => KStack_Frame,
         Flags    => Arch.MMU.Kernel_RW,
         Result   => MMU_Result);
      if MMU_Result /= Arch.MMU.Ok then
         Kernel.Physical_Memory.Deallocate_Frame
           (Frame  => KStack_Frame,
            Result => PMM_Result);
         Result := Load_Failed;
         return;
      end if;

      --  Reserve a secondary thread slot.
      if Thread_Free_Head = Thread_Free_None then
         Kernel.Physical_Memory.Deallocate_Frame
           (Frame  => KStack_Frame,
            Result => PMM_Result);
         return;
      end if;
      T_Slot := Thread_Index (Thread_Free_Head);
      Thread_Free_Head := Thread_Free_Next (T_Slot);
      Thread_Used (T_Slot) := True;

      --  Map the user stack (descending from Stack_VA).
      for Page in U64 range 0 .. Stack_Pages - 1 loop
         Arch.MMU.Map_Page
           (Root     => Kernel.Tasks.Address_Space_Root (Current.all),
            Virtual  => Stack_VA - (Stack_Pages - Page) *
              Arch.MMU.Page_Size,
            Physical => Kernel.Memory.Frame_At (Stack_Info.Object, Page),
            Flags    => Arch.MMU.User_RWX,
            Result   => MMU_Result);
         if MMU_Result /= Arch.MMU.Ok then
            Undo_Stack_Map (Page);
            Thread_Used (T_Slot) := False;
            Thread_Free_Next (T_Slot) := Thread_Free_Head;
            Thread_Free_Head := Thread_Free_Index (T_Slot);
            Kernel.Physical_Memory.Deallocate_Frame
              (Frame  => KStack_Frame,
               Result => PMM_Result);
            Result := Load_Failed;
            return;
         end if;
      end loop;

      Arch.MMU.Map_Page
        (Root     => Kernel.Tasks.Address_Space_Root (Current.all),
         Virtual  => IPC_VA,
         Physical => Kernel.Memory.Frame_At (IPC_Info.Object, 0),
         Flags    => Arch.MMU.User_RW,
         Result   => MMU_Result);
      if MMU_Result /= Arch.MMU.Ok then
         Undo_Stack_Map (Stack_Pages);
         Thread_Used (T_Slot) := False;
         Thread_Free_Next (T_Slot) := Thread_Free_Head;
         Thread_Free_Head := Thread_Free_Index (T_Slot);
         Kernel.Physical_Memory.Deallocate_Frame
           (Frame  => KStack_Frame,
            Result => PMM_Result);
         Result := Load_Failed;
         return;
      end if;

      --  Build the thread.
      New_Thread_Id := Next_Thread_Id;
      Next_Thread_Id :=
        Kernel.Tasks.Thread_Id (Natural (Next_Thread_Id) + 1);

      Kernel.Tasks.Initialize_Thread
        (TCB     => Threads (T_Slot),
         Id      => New_Thread_Id,
         Process => Process);
      Kernel.Tasks.Set_Kernel_Stack_Top
        (TCB       => Threads (T_Slot),
         Stack_Top => KStack_Frame + Kernel.Physical_Memory.Page_Size);
      Kernel.Tasks.Set_IPC_Buffer
        (TCB     => Threads (T_Slot),
         Phys_PA => Kernel.Memory.Frame_At (IPC_Info.Object, 0));
      Kernel.Tasks.Set_IPC_Buffer_VA
        (TCB     => Threads (T_Slot),
         User_VA => IPC_VA);
      Kernel.Tasks.Set_Priority
        (TCB          => Threads (T_Slot),
         New_Priority => New_Priority);
      Kernel.Tasks.Initialize_Context
        (TCB       => Threads (T_Slot),
         PC        => Entry_PC,
         Stack     => Stack_VA,
         User_Satp => Arch.MMU.Satp_Value
           (Kernel.Tasks.Process_Address_Space_Root (Process.all)),
         TLS_Base  => TLS_Base,
         Arg       => Arg);

      --  Hand back a thread cap.
      Kernel.Tasks.Insert_Cap
        (TCB    => Current.all,
         Kind   => Kernel.Capabilities.Thread_Object,
         Object => Threads (T_Slot)'Address,
         Rights => Thread_Cap_Rights,
         Badge  => U64 (New_Thread_Id),
         Result => Cap_Result,
         Cap    => New_Cap);
      if Cap_Result /= Kernel.Capabilities.Ok then
         Arch.MMU.Unmap_Borrowed_Page
           (Root    => Kernel.Tasks.Address_Space_Root (Current.all),
            Virtual => IPC_VA,
            Result  => MMU_Result);
         Undo_Stack_Map (Stack_Pages);
         Thread_Used (T_Slot) := False;
         Thread_Free_Next (T_Slot) := Thread_Free_Head;
         Thread_Free_Head := Thread_Free_Index (T_Slot);
         Kernel.Physical_Memory.Deallocate_Frame
           (Frame  => KStack_Frame,
            Result => PMM_Result);
         Result := Cap_Failed;
         return;
      end if;

      Kernel.Scheduler.Add_Task
        (TCB    => Threads (T_Slot)'Unchecked_Access,
         Result => Sched_Result);

      if Sched_Result /= Kernel.Scheduler.Ok then
         Kernel.Tasks.Close_Cap (Current, New_Cap, Cap_Result);
         Arch.MMU.Unmap_Borrowed_Page
           (Root    => Kernel.Tasks.Address_Space_Root (Current.all),
            Virtual => IPC_VA,
            Result  => MMU_Result);
         Undo_Stack_Map (Stack_Pages);
         Thread_Used (T_Slot) := False;
         Thread_Free_Next (T_Slot) := Thread_Free_Head;
         Thread_Free_Head := Thread_Free_Index (T_Slot);
         Kernel.Physical_Memory.Deallocate_Frame
           (Frame  => KStack_Frame,
            Result => PMM_Result);
         Result := Scheduler_Failed;
         return;
      end if;

      Process_Thread_Count (P_Slot) := Process_Thread_Count (P_Slot) + 1;
      Thread_Cap := New_Cap;
      Result := Ok;
   end Thread_Create;

   procedure Remove_As_Waiter (Waiter : Kernel.Tasks.Thread_Access) is
      Target : constant Kernel.Tasks.Thread_Access :=
        Kernel.Tasks.Waiting_For (Waiter.all);
      Prev   : Kernel.Tasks.Thread_Access := null;
      Cur    : Kernel.Tasks.Thread_Access;
   begin
      if Target = null then
         return;
      end if;

      Cur := Kernel.Tasks.Waiters_Head (Target.all);
      while Cur /= null loop
         if Cur = Waiter then
            if Prev = null then
               Kernel.Tasks.Set_Waiters_Head
                 (Target.all, Kernel.Tasks.Waiters_Next (Cur.all));
            else
               Kernel.Tasks.Set_Waiters_Next
                 (Prev.all, Kernel.Tasks.Waiters_Next (Cur.all));
            end if;
            exit;
         end if;
         Prev := Cur;
         Cur := Kernel.Tasks.Waiters_Next (Cur.all);
      end loop;

      Kernel.Tasks.Set_Waiting_For (Waiter.all, null);
      Kernel.Tasks.Set_Waiters_Next (Waiter.all, null);
   end Remove_As_Waiter;

   procedure Wake_Thread_Waiters (Target : Kernel.Tasks.Thread_Access) is
      Waiter : Kernel.Tasks.Thread_Access;
      Next   : Kernel.Tasks.Thread_Access;
      Ignore : Kernel.Scheduler.Status;
   begin
      Waiter := Kernel.Tasks.Waiters_Head (Target.all);
      while Waiter /= null loop
         Next := Kernel.Tasks.Waiters_Next (Waiter.all);
         Kernel.Tasks.Set_Waiting_For (Waiter.all, null);
         Kernel.Tasks.Set_Waiters_Next (Waiter.all, null);
         Kernel.Tasks.Set_Saved_Result (Waiter.all, 0);
         Kernel.Scheduler.Wake (Waiter, Ignore);
         Waiter := Next;
      end loop;
      Kernel.Tasks.Set_Waiters_Head (Target.all, null);
   end Wake_Thread_Waiters;

   procedure Thread_Exit
     (Thread : Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
      Process    : Kernel.Tasks.Process_Access;
      P_Slot     : Process_Index;
      T_Slot     : Thread_Index := Thread_Index'First;
      Found      : Boolean := False;
      Ignore     : Kernel.Scheduler.Status;
      Top        : U64;
   begin
      Result := Invalid_Parent;
      if Thread = null then
         return;
      end if;

      Process := Kernel.Tasks.Owning_Process (Thread.all);
      if Process = null then
         return;
      end if;
      P_Slot := Process_Slot_Of (Process);

      for T in Thread_Index loop
         if Thread_Used (T)
           and then Threads (T)'Address = Thread.all'Address
         then
            T_Slot := T;
            Found := True;
            exit;
         end if;
      end loop;

      if not Found then
         Result := Invalid_Program;
         return;
      end if;

      --  Last thread takes the process down.
      if Process_Thread_Count (P_Slot) = 1 then
         Kernel.Tasks.Set_Exit_Code (Process.all, 0);
         Kernel.Tasks.Set_Process_State
           (PCB       => Process.all,
            New_State => Kernel.Tasks.Process_Dead);
         Cleanup_Cap_Refs (Thread);
      end if;
      Process_Thread_Count (P_Slot) := Process_Thread_Count (P_Slot) - 1;

      --  The kernel stack is still in use for the current trap
      --  frame and the context switch below.  Record it for
      --  deferred deallocation once this hart has switched away.
      Top := Kernel.Tasks.Kernel_Stack_Top (Threads (T_Slot));
      if Top /= 0 then
         Free_Kernel_Stack_Later (Top);
         Kernel.Tasks.Set_Kernel_Stack_Top (Threads (T_Slot), 0);
      end if;

      Kernel.Tasks.Set_State (Threads (T_Slot), Kernel.Tasks.Dead);
      Kernel.Tasks.Set_Queued (Threads (T_Slot), False);
      Remove_As_Waiter (Threads (T_Slot)'Unchecked_Access);
      Wake_Thread_Waiters (Threads (T_Slot)'Unchecked_Access);
      Kernel.Scheduler.Remove_Thread
        (Threads (T_Slot)'Unchecked_Access, Ignore);
      Thread_Used (T_Slot) := False;
      if T_Slot >= Thread_Index (Max_Process_Slots) then
         Thread_Free_Next (T_Slot) := Thread_Free_Head;
         Thread_Free_Head := Thread_Free_Index (T_Slot);
      end if;
      Result := Ok;
   end Thread_Exit;

   procedure Thread_Wait
     (Caller     : Kernel.Tasks.Thread_Access;
      Thread_Cap : Kernel.Capabilities.Handle;
      Result     : out Status)
   is
      Cap_Entry    : Kernel.Capabilities.Cap_Entry;
      Cap_Result   : Kernel.Capabilities.Status;
      Target       : Kernel.Tasks.Thread_Access;
      Sched_Result : Kernel.Scheduler.Status;
      Wait_Right   : constant Kernel.Capabilities.Rights :=
        (Wait => True, others => False);
   begin
      Result := Invalid_Parent;
      if Caller = null then
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Caller.all,
         Cap       => Thread_Cap,
         Result    => Cap_Result,
         Out_Entry => Cap_Entry);
      if Cap_Result /= Kernel.Capabilities.Ok
        or else not Cap_Entry.Valid
        or else Cap_Entry.Kind /= Kernel.Capabilities.Thread_Object
        or else not Kernel.Capabilities.Has_Rights (Cap_Entry.Rights, Wait_Right)
      then
         Result := Invalid_Cap;
         return;
      end if;

      Target := To_Thread_Access (Cap_Entry.Object);

      --  Already exited: return immediately.
      if Kernel.Tasks.State (Target.all) = Kernel.Tasks.Dead then
         Result := Ok;
         return;
      end if;

      --  Waiting on yourself would deadlock.
      if Target = Caller then
         Result := Invalid_Cap;
         return;
      end if;

      --  Enqueue the caller on the target's waiter list and block.
      --  The whole sequence is under the big kernel lock, so the
      --  target cannot exit between the dead check and the enqueue.
      Kernel.Tasks.Set_Waiting_For (Caller.all, Target);
      Kernel.Tasks.Set_Waiters_Next
        (Caller.all, Kernel.Tasks.Waiters_Head (Target.all));
      Kernel.Tasks.Set_Waiters_Head (Target.all, Caller);

      --  Preset the resume result; the waking path copies 0 into the
      --  saved a0 before scheduling us again.
      Kernel.Scheduler.Block_Current
        (Kernel.Tasks.Blocked_Thread_Wait, Sched_Result);

      Result := Ok;
   end Thread_Wait;

   function Thread_Self
     (Thread : Kernel.Tasks.Thread_Access)
      return Kernel.Tasks.Thread_Id
   is
   begin
      if Thread = null then
         return 0;
      end if;
      return Kernel.Tasks.Id (Thread.all);
   end Thread_Self;

   procedure Free_Kernel_Stack_Later (Stack_Top : U64) is
      CPU : constant Kernel.CPUs.CPU_Index := Kernel.CPUs.Current;
   begin
      if Stack_Top = 0 then
         return;
      end if;

      if Deferred_Count (CPU) < Max_Deferred_Stacks then
         Deferred_Stacks (CPU, Deferred_Count (CPU)) := Stack_Top;
         Deferred_Count (CPU) := Deferred_Count (CPU) + 1;
      end if;
   end Free_Kernel_Stack_Later;

   procedure Drain_Deferred_Kernel_Stacks is
      CPU    : constant Kernel.CPUs.CPU_Index := Kernel.CPUs.Current;
      Top    : U64;
      Ignore : Kernel.Physical_Memory.Status;
   begin
      while Deferred_Count (CPU) > 0 loop
         Deferred_Count (CPU) := Deferred_Count (CPU) - 1;
         Top := Deferred_Stacks (CPU, Deferred_Count (CPU));
         if Top /= 0 then
            Kernel.Physical_Memory.Deallocate_Frame
              (Frame  => Top - Kernel.Physical_Memory.Page_Size,
               Result => Ignore);
         end if;
      end loop;
   end Drain_Deferred_Kernel_Stacks;

   procedure Reap_Process
     (Parent      : Kernel.Tasks.Thread_Access;
      Process_Cap : Kernel.Capabilities.Handle;
      Exit_Code   : out U64;
      Result      : out Status)
   is
      use type Kernel.Capabilities.Object_Kind;

      Cap_Result : Kernel.Capabilities.Status;
      Cap_Info   : Kernel.Capabilities.Cap_Entry;
      Found      : Boolean := False;
      Slot       : Process_Index := Process_Index'First;
   begin
      Exit_Code := 0;
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
        or else Kernel.Tasks.State
          (Threads (Initial_Thread_Slot (Slot))) /= Kernel.Tasks.Dead
      then
         Result := Not_Exited;
         return;
      end if;

      Exit_Code := Kernel.Tasks.Exit_Code (Processes (Slot));
      Kernel.Tasks.Close_Cap (Parent, Process_Cap, Cap_Result);
      if Cap_Result /= Kernel.Capabilities.Ok then
         Result := Cap_Failed;
         return;
      end if;

      Cleanup_Cap_Refs (Threads (Initial_Thread_Slot (Slot))'Unchecked_Access);
      Destroy_Address_Space
        (Kernel.Tasks.Process_Address_Space_Root (Processes (Slot)));
      Kernel.Tasks.Set_Process_Address_Space_Root (Processes (Slot), 0);
      Discard_Slot (Slot, Close_Caps => False);
      Result := Ok;
   end Reap_Process;

   procedure Fill_Info
     (PCB   : Kernel.Tasks.Process_Control_Block;
      TCB   : Kernel.Tasks.Thread_Control_Block;
      Words : out Process_Info_Words)
   is
      Flags : U64 := 0;
   begin
      if Kernel.Tasks.Is_Awaiting_Reply (TCB) then
         Flags := Flags or 1;
      end if;
      if Kernel.Tasks.Is_Reply_Wanted (TCB) then
         Flags := Flags or 2;
      end if;
      if Kernel.Tasks.Is_Boosted (TCB) then
         Flags := Flags or 4;
      end if;
      if Kernel.Tasks.Is_Queued (TCB) then
         Flags := Flags or 8;
      end if;
      Words :=
        (0 => U64 (Kernel.Tasks.Process_Id_Of (PCB)),
         1 => U64 (Kernel.Tasks.Spawner_Id (PCB)),
         2 => U64 (Kernel.Tasks.Process_State'Pos
                     (Kernel.Tasks.Lifecycle_State (PCB))),
         3 => U64 (Kernel.Tasks.Thread_State'Pos
                     (Kernel.Tasks.State (TCB))),
         4 => U64 (Kernel.Tasks.Process_Cap_Count (PCB)),
         5 => Flags,
         6 => U64 (System.Storage_Elements.To_Integer
                     (Kernel.Tasks.Recv_Endpoint (TCB))),
         7 => Kernel.Tasks.IPC_Badge (TCB),
         8 => To_U64 (I64 (Kernel.Tasks.Priority (TCB))));
   end Fill_Info;

   procedure Set_Thread_Priority
     (Process_Object : System.Address;
      New_Priority   : Kernel.Tasks.Thread_Priority;
      Old_Priority   : out Kernel.Tasks.Thread_Priority;
      Found          : out Boolean)
   is
   begin
      Old_Priority := 0;
      Found := False;
      for Slot in 0 .. Max_Process_Slots - 1 loop
         if Used (Process_Index (Slot))
           and then Processes (Process_Index (Slot))'Address
                      = Process_Object
         then
            Old_Priority :=
              Kernel.Tasks.Priority
                (Threads (Initial_Thread_Slot (Process_Index (Slot))));
            Kernel.Tasks.Set_Priority
              (Threads (Initial_Thread_Slot (Process_Index (Slot))),
               New_Priority);
            Found := True;
            return;
         end if;
      end loop;
   end Set_Thread_Priority;

   function Slot_Count return Natural is (Max_Process_Slots);

   procedure Read_Process_Info
     (Slot  : Natural;
      Words : out Process_Info_Words;
      Found : out Boolean)
   is
   begin
      Words := (others => 0);
      Found := False;
      if Slot < Max_Process_Slots
        and then Used (Process_Index (Slot))
      then
         Fill_Info
           (Processes (Process_Index (Slot)),
            Threads (Initial_Thread_Slot (Process_Index (Slot))), Words);
         Found := True;
      end if;
   end Read_Process_Info;

   procedure Read_Own_Process_Info
     (Thread : Kernel.Tasks.Thread_Access;
      Words  : out Process_Info_Words)
   is
   begin
      Words := (others => 0);
      if Thread = null
        or else Kernel.Tasks.Owning_Process (Thread.all) = null
      then
         return;
      end if;
      Fill_Info
        (Kernel.Tasks.Owning_Process (Thread.all).all,
         Thread.all, Words);
   end Read_Own_Process_Info;

   procedure Fill_Cap_Info
     (TCB       : Kernel.Tasks.Thread_Control_Block;
      Cap_Index : U64;
      Words     : out Cap_Info_Words;
      Found     : out Boolean)
   is
      use type Kernel.Capabilities.Status;
      Result : Kernel.Capabilities.Status;
      Ent    : Kernel.Capabilities.Cap_Entry;
   begin
      Words := (others => 0);
      Found := False;
      if Cap_Index = 0
        or else Cap_Index >= U64 (Kernel.Capabilities.Max_Caps)
      then
         return;
      end if;
      Kernel.Tasks.Lookup_Cap
        (TCB       => TCB,
         Cap       => Kernel.Capabilities.Handle (Cap_Index),
         Result    => Result,
         Out_Entry => Ent);
      if Result /= Kernel.Capabilities.Ok
        or else not Ent.Valid
      then
         return;
      end if;
      Words :=
        (0 => Cap_Index,
         1 => U64 (Kernel.Capabilities.Object_Kind'Pos (Ent.Kind)),
         2 => Kernel.Capabilities.To_Mask (Ent.Rights),
         3 => U64 (System.Storage_Elements.To_Integer (Ent.Object)),
         4 => Ent.Badge,
         5 => 1,
         others => 0);
      Found := True;
   end Fill_Cap_Info;

   procedure Read_Cap_Info
     (Slot      : Natural;
      Cap_Index : U64;
      Words     : out Cap_Info_Words;
      Found     : out Boolean)
   is
   begin
      Words := (others => 0);
      Found := False;
      if Slot < Max_Process_Slots
        and then Used (Process_Index (Slot))
      then
         Fill_Cap_Info
           (Threads (Initial_Thread_Slot (Process_Index (Slot))),
            Cap_Index, Words, Found);
      end if;
   end Read_Cap_Info;

   procedure Read_Own_Cap_Info
     (Thread    : Kernel.Tasks.Thread_Access;
      Cap_Index : U64;
      Words     : out Cap_Info_Words;
      Found     : out Boolean)
   is
   begin
      Words := (others => 0);
      Found := False;
      if Thread /= null then
         Fill_Cap_Info (Thread.all, Cap_Index, Words, Found);
      end if;
   end Read_Own_Cap_Info;

   procedure Read_Thread_Regs
     (Slot  : Natural;
      Words : out Thread_Reg_Words;
      Found : out Boolean;
      Busy  : out Boolean)
   is
      use type Kernel.Tasks.Thread_State;
      Frame : Arch.Context.Context_Word_Array;
      State : Kernel.Tasks.Thread_State;
   begin
      Words := (others => 0);
      Found := False;
      Busy  := False;
      if Slot >= Max_Process_Slots
        or else not Used (Process_Index (Slot))
      then
         return;
      end if;
      Found := True;
      State := Kernel.Tasks.State
        (Threads (Initial_Thread_Slot (Process_Index (Slot))));
      if State = Kernel.Tasks.Ready
        or else State = Kernel.Tasks.Running
        or else not Kernel.Tasks.Has_Context
          (Threads (Initial_Thread_Slot (Process_Index (Slot))))
      then
         --  Live registers are not in the saved frame.
         Busy := True;
         return;
      end if;
      Kernel.Tasks.Read_Context_Words
        (Threads (Initial_Thread_Slot (Process_Index (Slot))), Frame);
      for I in Frame'Range loop
         Words (I) := Frame (I);
      end loop;
      Words (33) := U64 (Kernel.Tasks.Thread_State'Pos (State));
      Words (34) :=
        U64 (Kernel.Tasks.Process_Id_Of (Processes (Process_Index (Slot))));
   end Read_Thread_Regs;

end Kernel.Processes;
