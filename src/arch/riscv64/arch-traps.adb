with System;
with System.Storage_Elements;
with Ada.Unchecked_Conversion;
with Arch.MMU;
with Arch.SBI;
with Board.Interrupts;
with Board.PLIC;
with Board.UART;
with Kernel.Boot_Files;
with Kernel.Capabilities;
with Kernel.CPUs;
with Kernel.Interrupts;
with Kernel.IPC;
with Kernel.Lock;
with Kernel.Memory;
with Kernel.Objects;
with Kernel.Physical_Memory;
with Kernel.Notifications;
with Kernel.Processes;
with Kernel.Scheduler;
with Kernel.Tasks;

package body Arch.Traps is
   use type Arch.MMU.Status;
   use type Kernel.CPUs.CPU_Index;
   use type Kernel.IPC.Status;
   use type Kernel.Processes.Status;
   use type Kernel.Notifications.Status;
   use type Kernel.Objects.IRQ_Line_Access;
   use type Kernel.Scheduler.Status;
   use type Kernel.Tasks.Thread_Access;
   use type System.Address;

   Timer_Ticks_Per_Second : constant U64 := 10_000_000;
   Timer_Interval        : constant U64 := Timer_Ticks_Per_Second / 10;
   Interrupt_Bit         : constant U64 := 16#8000_0000_0000_0000#;
   Sstatus_SPP           : constant U64 := 16#100#;  --  trap from S-mode
   User_Ecall            : constant U64 := 8;
   Supervisor_Timer      : constant U64 := 5;
   Supervisor_External   : constant U64 := 9;
   Supervisor_Software   : constant U64 := 1;
   Sip_Software_Pending  : constant U64 := 16#002#;
   Sip_External_Pending  : constant U64 := 16#200#;

   Sys_Yield             : constant U64 := 0;
   Sys_Debug_Putchar     : constant U64 := 1;
   Sys_Map_MMIO          : constant U64 := 2;
   Sys_IRQ_Wait          : constant U64 := 3;
   Sys_IRQ_Ack           : constant U64 := 4;
   Sys_Boot_File_Size    : constant U64 := 6;
   Sys_Boot_Read_Byte    : constant U64 := 7;
   Sys_Spawn             : constant U64 := 8;
   Sys_Exit              : constant U64 := 9;
   Sys_Reap_Process      : constant U64 := 10;
   Sys_EP_Create         : constant U64 := 11;
   Sys_IPC_Call          : constant U64 := 12;
   Sys_IPC_Recv          : constant U64 := 13;
   Sys_IPC_Reply         : constant U64 := 14;
   Sys_Mem_Alloc         : constant U64 := 15;
   Sys_Mem_Map           : constant U64 := 16;
   Sys_Mem_Unmap         : constant U64 := 17;
   Sys_Ntfn_Create       : constant U64 := 18;
   Sys_Ntfn_Wait         : constant U64 := 19;
   Sys_Ntfn_Signal       : constant U64 := 20;
   Sys_Ntfn_Bind_Thread  : constant U64 := 21;
   Sys_IRQ_Bind_Ntfn     : constant U64 := 22;

   --  Which right a notification syscall requires on its cap.
   type Ntfn_Right is (Ntfn_Wait_Right, Ntfn_Signal_Right, Ntfn_Manage_Right);

   Tick_Count : U64 := 0;

   function Trap_Frame_Get_A0 (Frame : System.Address) return U64
     with Import, Convention => C, External_Name => "trap_frame_get_a0";

   function Trap_Frame_Get_A1 (Frame : System.Address) return U64
     with Import, Convention => C, External_Name => "trap_frame_get_a1";

   function Trap_Frame_Get_A2 (Frame : System.Address) return U64
     with Import, Convention => C, External_Name => "trap_frame_get_a2";

   function Trap_Frame_Get_A3 (Frame : System.Address) return U64
     with Import, Convention => C, External_Name => "trap_frame_get_a3";

   function Trap_Frame_Get_A4 (Frame : System.Address) return U64
     with Import, Convention => C, External_Name => "trap_frame_get_a4";

   function Trap_Frame_Get_A5 (Frame : System.Address) return U64
     with Import, Convention => C, External_Name => "trap_frame_get_a5";

   function Trap_Frame_Get_A7 (Frame : System.Address) return U64
     with Import, Convention => C, External_Name => "trap_frame_get_a7";

   procedure Trap_Frame_Set_A0 (Frame : System.Address; Value : U64)
     with Import, Convention => C, External_Name => "trap_frame_set_a0";

   procedure Trap_Frame_Set_A1 (Frame : System.Address; Value : U64)
     with Import, Convention => C, External_Name => "trap_frame_set_a1";

   procedure Raw_Set_Trap_Stack (Stack_Top : U64)
     with Import, Convention => C, External_Name => "riscv_set_trap_stack";

   procedure Raw_Enter_Via_Frame
     with Import, Convention => C, External_Name => "riscv_enter_via_frame";

   procedure Advance_SEPC (Frame : System.Address)
     with Import, Convention => C, External_Name => "trap_frame_advance_sepc";

   function Trap_Frame_For_Stack (Stack_Top : U64) return System.Address
     with Import, Convention => C, External_Name => "trap_frame_for_stack";

   type U64_Access is access all U64;
   function To_U64_Access is new Ada.Unchecked_Conversion
     (Source => System.Address, Target => U64_Access);

   --  Hart slot: the word at kernel stack top - 8, just above the
   --  trap frame.  riscv_current_hart reads it through sscratch, so
   --  every stack kernel code runs on must carry this hart's index.
   procedure Write_Hart_Slot (Stack_Top : U64) is
   begin
      To_U64_Access
        (System'To_Address
          (System.Storage_Elements.Integer_Address (Stack_Top - 8))).all
        := U64 (Kernel.CPUs.Current);
   end Write_Hart_Slot;

   procedure Set_Kernel_Trap_Stack (Stack_Top : U64) is
   begin
      --  Keep the hart-slot invariant: sscratch may only point at
      --  stacks whose slot names this hart (this is the single place
      --  sscratch changes in kernel code).
      Write_Hart_Slot (Stack_Top);
      Raw_Set_Trap_Stack (Stack_Top);
   end Set_Kernel_Trap_Stack;

   function Hex_Digit (Nibble : U64) return Character is
      Hex : constant String := "0123456789abcdef";
   begin
      return Hex (Natural (Nibble) + 1);
   end Hex_Digit;

   procedure Put_Hex_Unsafe (Value : U64) is
      Shift : Natural := 60;
   begin
      Board.UART.Put_Unsafe ("0x");
      loop
         Board.UART.Put_Unsafe
           ((1 => Hex_Digit
              (Interfaces.Shift_Right (Value, Shift) and 16#f#)));
         exit when Shift = 0;
         Shift := Shift - 4;
      end loop;
   end Put_Hex_Unsafe;

   procedure Halt is
   begin
      loop
         null;
      end loop;
   end Halt;

   type MMIO_Region_Access is access all Kernel.Objects.MMIO_Region;

   function To_MMIO_Region is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => MMIO_Region_Access);

   function To_IRQ_Line is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Kernel.Objects.IRQ_Line_Access);

   function Is_Page_Aligned (Value : U64) return Boolean is
   begin
      return Value mod Arch.MMU.Page_Size = 0;
   end Is_Page_Aligned;

   procedure Decode_Handle
     (Value : U64;
      Cap   : out Kernel.Capabilities.Handle;
      Valid : out Boolean)
   is
   begin
      if Value > U64 (Kernel.Capabilities.Handle'Last) then
         Cap := Kernel.Capabilities.Invalid_Handle;
         Valid := False;
      else
         Cap := Kernel.Capabilities.Handle (Value);
         Valid := True;
      end if;
   end Decode_Handle;

   procedure Save_Current_Context (Frame : System.Address) is
      Current : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
   begin
      if Current /= null then
         Kernel.Tasks.Save_Trap_Context
           (TCB   => Current.all,
            Frame => Frame);
      end if;
   end Save_Current_Context;

   procedure Restore_Scheduled_Context
     (Frame  : System.Address;
      Result : Kernel.Scheduler.Status)
   is
      Current : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
   begin
      if Result = Kernel.Scheduler.Ok and then Current /= null then
         declare
            Top : constant U64 := Kernel.Tasks.Kernel_Stack_Top (Current.all);
         begin
            if Top /= 0 then
               --  Restore context into the newly current thread's own
               --  kernel stack frame (reached through the physmap);
               --  the exit trampoline finds it via sscratch and
               --  installs the frame's satp slot.
               Kernel.Tasks.Restore_Trap_Context
                 (TCB   => Current.all,
                  Frame => Trap_Frame_For_Stack (Arch.Phys_To_Virt (Top)));
               Set_Kernel_Trap_Stack (Arch.Phys_To_Virt (Top));
            end if;
         end;
      elsif Result /= Kernel.Scheduler.Ok then
         Trap_Frame_Set_A0 (Frame, U64'Last);
      end if;
   end Restore_Scheduled_Context;

   --  Idle-time interrupt handling.  Kernel mode runs with
   --  sstatus.SIE clear, so pending interrupts never trap while a
   --  hart sleeps in the idle wfi; the idle loop polls them instead:
   --  external (UART RX via PLIC, boot hart only: its context is the
   --  only one with sources enabled) and software (IPI).  This is
   --  also what lets a fully-blocked system (all threads waiting on
   --  notifications/endpoints) notice device interrupts at all.
   procedure Poll_Pending_Interrupts is
      Pending : constant U64 := Arch.SBI.Pending;
   begin
      if (Pending and Sip_External_Pending) /= 0
        and then Kernel.CPUs.Current = Kernel.CPUs.CPU_Index'First
      then
         Board.Interrupts.Handle_External_Interrupt;
      end if;

      if (Pending and Sip_Software_Pending) /= 0 then
         Arch.SBI.Clear_Software_Pending;
      end if;
   end Poll_Pending_Interrupts;

   --  Idle loop on the per-hart main stack (see Kernel.CPUs stack
   --  accessors).  Entered with the kernel lock held and no
   --  runnable thread; schedules threads out of the ready queue or
   --  sleeps in wfi.  Never returns: it either loops or enters a
   --  thread through the trap-return path.
   procedure Idle_Loop with No_Return;

   procedure Raw_Jump_To_Idle
     (Main_Stack_Top : U64;
      Trap_Stack_Top : U64;
      Idle_Entry     : System.Address)
     with Import, Convention => C,
          External_Name => "riscv_jump_to_idle", No_Return;

   procedure Idle_Loop is
      Result : Kernel.Scheduler.Status;
   begin
      loop
         Kernel.Scheduler.Yield (Result);
         if Result = Kernel.Scheduler.Ok
           and then Kernel.Scheduler.Current /= null
         then
            declare
               Current : constant Kernel.Tasks.Thread_Access :=
                 Kernel.Scheduler.Current;
               Top     : constant U64 :=
                 Kernel.Tasks.Kernel_Stack_Top (Current.all);
            begin
               if Top /= 0 then
                  --  No trap frame of our own exists: restore the
                  --  thread's saved context into its kernel stack,
                  --  point sscratch at it, and take the trap-return
                  --  path into user mode.
                  Kernel.Tasks.Restore_Trap_Context
                    (TCB   => Current.all,
                     Frame => Trap_Frame_For_Stack
                       (Arch.Phys_To_Virt (Top)));
                  Set_Kernel_Trap_Stack (Arch.Phys_To_Virt (Top));
                  Kernel.Lock.Release;
                  Raw_Enter_Via_Frame;   --  does not return
               end if;
            end;
         end if;

         --  Idle: no runnable thread anywhere.  Poll interrupts and
         --  re-arm the tick while still holding the kernel lock
         --  (both clear their pending bits), then drop the lock so
         --  other harts can enter the kernel, and sleep.  A waker
         --  pushes to the ready queue and IPIs this hart; the
         --  pending SSIP makes the wfi return immediately even if
         --  the push lands in the release/wfi window.  Safe to
         --  sleep here: this is the per-hart main stack, never a
         --  resumable thread's kernel stack.
         Poll_Pending_Interrupts;
         Arch.SBI.Set_Timer (Arch.SBI.Time + Timer_Interval);
         Kernel.Lock.Release;
         Arch.SBI.Wait_For_Interrupt;
         Kernel.Lock.Acquire;
      end loop;
   end Idle_Loop;

   procedure Schedule_Saved_Context
     (Frame  : System.Address;
      Result : out Kernel.Scheduler.Status)
   is
   begin
      Kernel.Scheduler.Yield (Result);
      if Result /= Kernel.Scheduler.Queue_Empty
        and then (Result /= Kernel.Scheduler.Ok
                  or else Kernel.Scheduler.Current /= null)
      then
         Restore_Scheduled_Context (Frame, Result);
         return;
      end if;

      --  No runnable thread: abandon this kernel stack.  It belongs
      --  to the thread that just blocked or exited, and another
      --  hart may resume that thread while this hart sleeps; the
      --  thread's next trap would then clobber this hart's live
      --  frames.  Switch to the per-hart main/trap stacks and idle
      --  there.  Does not return.
      declare
         Self : constant Kernel.CPUs.CPU_Index := Kernel.CPUs.Current;
      begin
         Raw_Jump_To_Idle
           (Main_Stack_Top => Kernel.CPUs.Idle_Main_Stack_Top (Self),
            Trap_Stack_Top => Kernel.CPUs.Idle_Trap_Stack_Top (Self),
            Idle_Entry     => Idle_Loop'Address);
      end;
   end Schedule_Saved_Context;

   --  Preemptive scheduling tick: only when the timer interrupted a
   --  running user thread (SPP clear). Kernel threads and the idle
   --  wfi path (SPP set) stay cooperative; syscall handlers run with
   --  interrupts off, so the kernel itself is never preempted.
   procedure Handle_Preemption (Frame : System.Address) is
      Current : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Result  : Kernel.Scheduler.Status;
   begin
      if Current = null
        or else (Arch.SBI.Sstatus and Sstatus_SPP) /= 0
      then
         return;
      end if;

      Save_Current_Context (Frame);
      Schedule_Saved_Context (Frame, Result);
   end Handle_Preemption;

   procedure Handle_Map_MMIO (Frame : System.Address) is
      use type Kernel.Capabilities.Object_Kind;
      use type Kernel.Capabilities.Status;

      Address_Space_Cap : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Cap_Handle        : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handles_Valid     : Boolean;
      VA                : constant U64 := Trap_Frame_Get_A2 (Frame);
      Offset            : constant U64 := Trap_Frame_Get_A3 (Frame);
      Length            : constant U64 := Trap_Frame_Get_A4 (Frame);
      Flags             : constant U64 := Trap_Frame_Get_A5 (Frame);
      Current    : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Cap_Result : Kernel.Capabilities.Status;
      Cap_Info   : Kernel.Capabilities.Cap_Entry;
      Region     : MMIO_Region_Access;
      Map_Result : Arch.MMU.Status;
      Page_Count : U64;
   begin
      Decode_Handle
        (Trap_Frame_Get_A0 (Frame), Address_Space_Cap, Handles_Valid);
      if not Handles_Valid then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Decode_Handle (Trap_Frame_Get_A1 (Frame), Cap_Handle, Handles_Valid);
      if not Handles_Valid then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      if Current = null
        or else not Kernel.Tasks.Has_Address_Space_Map_Authority
          (Current.all, Address_Space_Cap)
      then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Current.all,
         Cap       => Cap_Handle,
         Result    => Cap_Result,
         Out_Entry => Cap_Info);

      if Cap_Result /= Kernel.Capabilities.Ok
        or else Cap_Info.Kind /= Kernel.Capabilities.MMIO_Object
        or else not Cap_Info.Rights.Map
        or else ((Flags and 1) /= 0 and then not Cap_Info.Rights.Read)
        or else ((Flags and 2) /= 0 and then not Cap_Info.Rights.Write)
        or else (Flags and not 3) /= 0
      then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Region := To_MMIO_Region (Cap_Info.Object);
      if Region = null
        or else VA < 16#4000_0000#
        or else VA + Length > 16#8000_0000#
        or else Length = 0
        or else Offset + Length > Region.Length
        or else not Is_Page_Aligned (VA)
        or else not Is_Page_Aligned (Offset)
        or else not Is_Page_Aligned (Length)
        or else Length /= Arch.MMU.Page_Size
      then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Page_Count := Length / Arch.MMU.Page_Size;
      for Page in U64 range 0 .. Page_Count - 1 loop
         Arch.MMU.Map_Page
           (Root     => Kernel.Tasks.Address_Space_Root (Current.all),
            Virtual  => VA + Page * Arch.MMU.Page_Size,
            Physical => Region.Physical_Base + Offset
              + Page * Arch.MMU.Page_Size,
            Flags    => Arch.MMU.User_RW,
            Result   => Map_Result);

         if Map_Result /= Arch.MMU.Ok then
            Trap_Frame_Set_A0 (Frame, 1);
            return;
         end if;
      end loop;

      Trap_Frame_Set_A0 (Frame, 0);
   end Handle_Map_MMIO;

   procedure Handle_IRQ_Wait (Frame : System.Address) is
      use type Kernel.Capabilities.Object_Kind;
      use type Kernel.Capabilities.Status;
      use type Kernel.Interrupts.Status;

      Cap_Handle  : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handle_Valid : Boolean;
      Current     : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Cap_Result : Kernel.Capabilities.Status;
      Cap_Info         : Kernel.Capabilities.Cap_Entry;
      Line             : Kernel.Objects.IRQ_Line_Access;
      IRQ_Result       : Kernel.Interrupts.Status;
      Scheduler_Result : Kernel.Scheduler.Status;
   begin
      Decode_Handle (Trap_Frame_Get_A0 (Frame), Cap_Handle, Handle_Valid);
      if not Handle_Valid or else Current = null then
         Trap_Frame_Set_A0 (Frame, 1);
         Advance_SEPC (Frame);
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Current.all,
         Cap       => Cap_Handle,
         Result    => Cap_Result,
         Out_Entry => Cap_Info);

      if Cap_Result /= Kernel.Capabilities.Ok
        or else Cap_Info.Kind /= Kernel.Capabilities.IRQ_Object
        or else not Cap_Info.Rights.Wait
      then
         Trap_Frame_Set_A0 (Frame, 1);
         Advance_SEPC (Frame);
         return;
      end if;

      Line := To_IRQ_Line (Cap_Info.Object);
      if Line = null then
         Trap_Frame_Set_A0 (Frame, 1);
         Advance_SEPC (Frame);
         return;
      end if;

      Kernel.Interrupts.Wait (Line, Current, IRQ_Result);

      if IRQ_Result = Kernel.Interrupts.Ok then
         Trap_Frame_Set_A0 (Frame, 0);
      elsif IRQ_Result = Kernel.Interrupts.Would_Block then
         Advance_SEPC (Frame);
         Trap_Frame_Set_A0 (Frame, 0);
         Save_Current_Context (Frame);
         Kernel.Tasks.Set_State (Current.all, Kernel.Tasks.Blocked_IRQ);
         Schedule_Saved_Context (Frame, Scheduler_Result);
         return;
      else
         Trap_Frame_Set_A0 (Frame, 1);
      end if;

      Advance_SEPC (Frame);
   end Handle_IRQ_Wait;

   procedure Handle_IRQ_Ack (Frame : System.Address) is
      use type Kernel.Capabilities.Object_Kind;
      use type Kernel.Capabilities.Status;
      use type Kernel.Interrupts.Status;

      Cap_Handle      : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handle_Valid    : Boolean;
      Current         : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Cap_Result      : Kernel.Capabilities.Status;
      Cap_Info        : Kernel.Capabilities.Cap_Entry;
      Line            : Kernel.Objects.IRQ_Line_Access;
      IRQ_Result      : Kernel.Interrupts.Status;
      Complete_Source : U64;
   begin
      Decode_Handle (Trap_Frame_Get_A0 (Frame), Cap_Handle, Handle_Valid);
      if not Handle_Valid or else Current = null then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Current.all,
         Cap       => Cap_Handle,
         Result    => Cap_Result,
         Out_Entry => Cap_Info);

      if Cap_Result /= Kernel.Capabilities.Ok
        or else Cap_Info.Kind /= Kernel.Capabilities.IRQ_Object
        or else not Cap_Info.Rights.Ack
      then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Line := To_IRQ_Line (Cap_Info.Object);
      if Line = null then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Kernel.Interrupts.Ack (Line, IRQ_Result, Complete_Source);
      if IRQ_Result = Kernel.Interrupts.Ok then
         Board.PLIC.Complete (Board.PLIC.Source_Id (Complete_Source));
         Trap_Frame_Set_A0 (Frame, 0);
      elsif IRQ_Result = Kernel.Interrupts.Would_Block then
         Trap_Frame_Set_A0 (Frame, 2);
      else
         Trap_Frame_Set_A0 (Frame, 1);
      end if;
   end Handle_IRQ_Ack;

   function Process_Status_Code
     (Result : Kernel.Processes.Status) return U64
   is
   begin
      return Kernel.Processes.Status'Pos (Result);
   end Process_Status_Code;

   --  Spawn ABI v2: a0 = Boot_File_Object image cap (Read+Execute),
   --  a1 = grant count; grant entries in the caller's IPC buffer.
   procedure Handle_Spawn (Frame : System.Address) is
      Image_Cap   : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handle_Valid : Boolean;
      Grant_Count : constant U64 := Trap_Frame_Get_A1 (Frame);
      Current     : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Result      : Kernel.Processes.Status;
      Process_Cap : Kernel.Capabilities.Handle;
   begin
      Decode_Handle (Trap_Frame_Get_A0 (Frame), Image_Cap, Handle_Valid);
      if not Handle_Valid then
         Trap_Frame_Set_A0 (Frame, 1);
         Trap_Frame_Set_A1 (Frame, 0);
         return;
      end if;

      Kernel.Processes.Spawn_Boot_Image
        (Parent      => Current,
         Image_Cap   => Image_Cap,
         Grant_Count => Grant_Count,
         Result      => Result,
         Process_Cap => Process_Cap);

      Trap_Frame_Set_A0 (Frame, Process_Status_Code (Result));
      if Result = Kernel.Processes.Ok then
         Trap_Frame_Set_A1 (Frame, U64 (Process_Cap));
      else
         Trap_Frame_Set_A1 (Frame, 0);
      end if;
   end Handle_Spawn;

   --  Boot byte API (cap-based): a0 = Boot_File_Object cap with the
   --  Read right. Used by init to parse the manifest; the kernel
   --  never parses a path.
   procedure Lookup_Boot_File_Cap
     (Frame    : System.Address;
      Current  : Kernel.Tasks.Thread_Access;
      Cap_Info : out Kernel.Capabilities.Cap_Entry;
      Valid    : out Boolean)
   is
      use type Kernel.Capabilities.Status;

      Cap_Handle   : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handle_Valid : Boolean;
      Cap_Result   : Kernel.Capabilities.Status;
   begin
      Valid := False;
      Cap_Info := Kernel.Capabilities.Null_Cap;

      Decode_Handle (Trap_Frame_Get_A0 (Frame), Cap_Handle, Handle_Valid);
      if not Handle_Valid or else Current = null then
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Current.all,
         Cap       => Cap_Handle,
         Result    => Cap_Result,
         Out_Entry => Cap_Info);

      Valid := Cap_Result = Kernel.Capabilities.Ok;
   end Lookup_Boot_File_Cap;

   procedure Handle_Boot_File_Size (Frame : System.Address) is
      use type Kernel.Boot_Files.Status;

      Current  : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Cap_Info : Kernel.Capabilities.Cap_Entry;
      Valid    : Boolean;
      Result   : Kernel.Boot_Files.Status;
      Length   : U64;
   begin
      Lookup_Boot_File_Cap (Frame, Current, Cap_Info, Valid);
      if not Valid then
         Trap_Frame_Set_A0 (Frame, U64'Last);
         return;
      end if;

      Kernel.Boot_Files.Size
        (Cap     => Cap_Info,
         Result  => Result,
         Length  => Length);

      if Result = Kernel.Boot_Files.Ok then
         Trap_Frame_Set_A0 (Frame, Length);
      else
         Trap_Frame_Set_A0 (Frame, U64'Last);
      end if;
   end Handle_Boot_File_Size;

   procedure Handle_Boot_Read_Byte (Frame : System.Address) is
      use type Kernel.Boot_Files.Status;

      Offset   : constant U64 := Trap_Frame_Get_A1 (Frame);
      Current  : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Cap_Info : Kernel.Capabilities.Cap_Entry;
      Valid    : Boolean;
      Result   : Kernel.Boot_Files.Status;
      Value    : U64;
   begin
      Lookup_Boot_File_Cap (Frame, Current, Cap_Info, Valid);
      if not Valid then
         Trap_Frame_Set_A0 (Frame, U64'Last);
         return;
      end if;

      Kernel.Boot_Files.Read_Byte
        (Cap     => Cap_Info,
         Offset  => Offset,
         Result  => Result,
         Value   => Value);

      if Result = Kernel.Boot_Files.Ok then
         Trap_Frame_Set_A0 (Frame, Value);
      elsif Result = Kernel.Boot_Files.Out_Of_Range then
         Trap_Frame_Set_A0 (Frame, 256);
      else
         Trap_Frame_Set_A0 (Frame, U64'Last);
      end if;
   end Handle_Boot_Read_Byte;

   procedure Handle_Reap_Process (Frame : System.Address) is
      Process_Cap  : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handle_Valid : Boolean;
      Current      : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Result      : Kernel.Processes.Status;
   begin
      Decode_Handle (Trap_Frame_Get_A0 (Frame), Process_Cap, Handle_Valid);
      if not Handle_Valid then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Kernel.Processes.Reap_Process
        (Parent      => Current,
         Process_Cap => Process_Cap,
         Result      => Result);

      if Result = Kernel.Processes.Ok then
         Trap_Frame_Set_A0 (Frame, 0);
      elsif Result = Kernel.Processes.Not_Exited then
         Trap_Frame_Set_A0 (Frame, 2);
      else
         Trap_Frame_Set_A0 (Frame, 1);
      end if;
   end Handle_Reap_Process;

   --  Line-atomic debug output: bytes accumulate in the calling
   --  thread's TCB buffer and only hit the UART on newline, a full
   --  buffer, or thread exit, so concurrent threads' debug lines
   --  never interleave.
   procedure Flush_Debug_Line (Current : Kernel.Tasks.Thread_Access) is
      Line : String (1 .. Kernel.Tasks.Debug_Line_Max);
      Len  : Natural;
   begin
      Kernel.Tasks.Take_Debug_Line (Current.all, Line, Len);
      if Len > 0 then
         Board.UART.Put (Line (1 .. Len));
      end if;
   end Flush_Debug_Line;

   procedure Handle_Debug_Putchar (Frame : System.Address) is
      Current : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Char    : constant Character := Character'Val
        (Natural (Trap_Frame_Get_A0 (Frame) and 16#ff#));
      Flush   : Boolean;
   begin
      if Current = null then
         Board.UART.Put ((1 => Char));
      else
         Kernel.Tasks.Append_Debug_Char (Current.all, Char, Flush);
         if Flush then
            Flush_Debug_Line (Current);
         end if;
      end if;
      Trap_Frame_Set_A0 (Frame, 0);
   end Handle_Debug_Putchar;

   procedure Handle_Ntfn_Create (Frame : System.Address) is
      use type Kernel.Capabilities.Status;

      Current : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Ntfn_Result : Kernel.Notifications.Status;
      Cap_Result  : Kernel.Capabilities.Status;
      Object      : System.Address;
      New_Cap     : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
   begin
      if Current = null then
         Trap_Frame_Set_A0 (Frame, U64'Last);
         return;
      end if;

      Kernel.Notifications.Create (Ntfn_Result, Object);
      if Ntfn_Result /= Kernel.Notifications.Ok then
         Trap_Frame_Set_A0 (Frame, U64'Last);
         return;
      end if;

      Kernel.Tasks.Insert_Cap
        (TCB    => Current.all,
         Kind   => Kernel.Capabilities.Notification_Object,
         Object => Object,
         Rights => Kernel.Notifications.Notification_Full_Rights,
         Badge  => 0,
         Result => Cap_Result,
         Cap    => New_Cap);

      if Cap_Result /= Kernel.Capabilities.Ok then
         Kernel.Notifications.Discard (Object);
         Trap_Frame_Set_A0 (Frame, U64'Last);
         return;
      end if;

      Trap_Frame_Set_A0 (Frame, U64 (New_Cap));
   end Handle_Ntfn_Create;

   --  Shared cap lookup for the notification syscalls: resolves the
   --  a0 handle to a Notification_Object cap with the required
   --  right.
   procedure Lookup_Ntfn_Cap
     (Frame   : System.Address;
      Current : Kernel.Tasks.Thread_Access;
      Right   : Ntfn_Right;
      Object  : out System.Address;
      Valid   : out Boolean)
   is
      use type Kernel.Capabilities.Object_Kind;
      use type Kernel.Capabilities.Status;

      Cap_Handle   : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handle_Valid : Boolean;
      Cap_Result   : Kernel.Capabilities.Status;
      Cap_Info     : Kernel.Capabilities.Cap_Entry;
   begin
      Object := System.Null_Address;
      Valid := False;

      Decode_Handle (Trap_Frame_Get_A0 (Frame), Cap_Handle, Handle_Valid);
      if not Handle_Valid or else Current = null then
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Current.all,
         Cap       => Cap_Handle,
         Result    => Cap_Result,
         Out_Entry => Cap_Info);

      if Cap_Result /= Kernel.Capabilities.Ok
        or else Cap_Info.Kind /= Kernel.Capabilities.Notification_Object
      then
         return;
      end if;

      case Right is
         when Ntfn_Wait_Right =>
            if not Cap_Info.Rights.Wait then
               return;
            end if;
         when Ntfn_Signal_Right =>
            if not Cap_Info.Rights.Write then
               return;
            end if;
         when Ntfn_Manage_Right =>
            if not Cap_Info.Rights.Manage then
               return;
            end if;
      end case;

      Object := Cap_Info.Object;
      Valid := True;
   end Lookup_Ntfn_Cap;

   procedure Handle_Ntfn_Wait (Frame : System.Address) is
      Current : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Object  : System.Address;
      Valid   : Boolean;
      Bits    : U64;
      Scheduler_Result : Kernel.Scheduler.Status;
   begin
      Lookup_Ntfn_Cap (Frame, Current, Ntfn_Wait_Right, Object, Valid);
      if not Valid then
         Trap_Frame_Set_A0 (Frame, U64'Last);
         Advance_SEPC (Frame);
         return;
      end if;

      Bits := Kernel.Notifications.Take (Object);
      if Bits /= 0 then
         Trap_Frame_Set_A0 (Frame, Bits);
         Advance_SEPC (Frame);
         return;
      end if;

      --  Block: Signal writes the consumed bits into saved a0.
      Advance_SEPC (Frame);
      Save_Current_Context (Frame);
      Kernel.Tasks.Set_State (Current.all, Kernel.Tasks.Blocked_Notification);
      Schedule_Saved_Context (Frame, Scheduler_Result);
   end Handle_Ntfn_Wait;

   procedure Handle_Ntfn_Signal (Frame : System.Address) is
      Current : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Object  : System.Address;
      Valid   : Boolean;
   begin
      Lookup_Ntfn_Cap (Frame, Current, Ntfn_Signal_Right, Object, Valid);
      if not Valid then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Kernel.Notifications.Signal (Object, Trap_Frame_Get_A1 (Frame));
      Trap_Frame_Set_A0 (Frame, 0);
   end Handle_Ntfn_Signal;

   procedure Handle_Ntfn_Bind_Thread (Frame : System.Address) is
      Current : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Object  : System.Address;
      Valid   : Boolean;
      Bind_Result : Kernel.Notifications.Status;
   begin
      Lookup_Ntfn_Cap (Frame, Current, Ntfn_Manage_Right, Object, Valid);
      if not Valid or else Current = null then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Kernel.Notifications.Bind_Thread (Object, Current, Bind_Result);
      if Bind_Result = Kernel.Notifications.Ok then
         Trap_Frame_Set_A0 (Frame, 0);
      else
         Trap_Frame_Set_A0 (Frame, 1);
      end if;
   end Handle_Ntfn_Bind_Thread;

   procedure Handle_IRQ_Bind_Ntfn (Frame : System.Address) is
      use type Kernel.Capabilities.Object_Kind;
      use type Kernel.Capabilities.Status;

      Current : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      IRQ_Handle  : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Ntfn_Handle : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handle_Valid : Boolean;
      Cap_Result   : Kernel.Capabilities.Status;
      IRQ_Info     : Kernel.Capabilities.Cap_Entry;
      Ntfn_Info    : Kernel.Capabilities.Cap_Entry;
      Line         : Kernel.Objects.IRQ_Line_Access;
   begin
      Decode_Handle (Trap_Frame_Get_A0 (Frame), IRQ_Handle, Handle_Valid);
      if not Handle_Valid then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;
      Decode_Handle (Trap_Frame_Get_A1 (Frame), Ntfn_Handle, Handle_Valid);
      if not Handle_Valid or else Current = null then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Current.all,
         Cap       => IRQ_Handle,
         Result    => Cap_Result,
         Out_Entry => IRQ_Info);
      if Cap_Result /= Kernel.Capabilities.Ok
        or else IRQ_Info.Kind /= Kernel.Capabilities.IRQ_Object
        or else not IRQ_Info.Rights.Ack
      then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Current.all,
         Cap       => Ntfn_Handle,
         Result    => Cap_Result,
         Out_Entry => Ntfn_Info);
      if Cap_Result /= Kernel.Capabilities.Ok
        or else Ntfn_Info.Kind /= Kernel.Capabilities.Notification_Object
        or else not Ntfn_Info.Rights.Write
      then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Line := To_IRQ_Line (IRQ_Info.Object);
      if Line = null then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Kernel.Interrupts.Bind_Notification
        (Line, Ntfn_Info.Object, Trap_Frame_Get_A2 (Frame));
      Trap_Frame_Set_A0 (Frame, 0);
   end Handle_IRQ_Bind_Ntfn;

   procedure Handle_Exit (Frame : System.Address) is
      Current          : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Exit_Result      : Kernel.Scheduler.Status;
      Scheduler_Result : Kernel.Scheduler.Status;
   begin
      if Current = null then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Flush_Debug_Line (Current);
      Kernel.Processes.Mark_Exited (Current);
      Advance_SEPC (Frame);
      Kernel.Scheduler.Exit_Current (Exit_Result);
      if Exit_Result /= Kernel.Scheduler.Ok then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Schedule_Saved_Context (Frame, Scheduler_Result);
   end Handle_Exit;

   procedure Handle_EP_Create (Frame : System.Address) is
      use type Kernel.Capabilities.Status;

      Current : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      IPC_Result : Kernel.IPC.Status;
      Cap_Result : Kernel.Capabilities.Status;
      Object     : System.Address;
      New_Cap    : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
   begin
      if Current = null then
         Trap_Frame_Set_A0 (Frame, U64'Last);
         return;
      end if;

      Kernel.IPC.Create_Endpoint (IPC_Result, Object);
      if IPC_Result /= Kernel.IPC.Ok then
         Trap_Frame_Set_A0 (Frame, U64'Last);
         return;
      end if;

      --  Fresh endpoint has refcount 0; the insert retains it to 1.
      Kernel.Tasks.Insert_Cap
        (TCB    => Current.all,
         Kind   => Kernel.Capabilities.Endpoint_Object,
         Object => Object,
         Rights => Kernel.IPC.Endpoint_Full_Rights,
         Badge  => 0,
         Result => Cap_Result,
         Cap    => New_Cap);

      if Cap_Result /= Kernel.Capabilities.Ok then
         Kernel.IPC.Discard (Object);
         Trap_Frame_Set_A0 (Frame, U64'Last);
         return;
      end if;

      Trap_Frame_Set_A0 (Frame, U64 (New_Cap));
   end Handle_EP_Create;

   --  Map an IPC kernel status to the userspace result code.
   procedure Set_IPC_Result
     (Frame  : System.Address;
      Result : Kernel.IPC.Status)
   is
   begin
      if Result = Kernel.IPC.Ok then
         Trap_Frame_Set_A0 (Frame, Kernel.IPC.Result_Ok);
      elsif Result = Kernel.IPC.Transfer_Failed then
         Trap_Frame_Set_A0 (Frame, Kernel.IPC.Result_Transfer_Failed);
      else
         Trap_Frame_Set_A0 (Frame, Kernel.IPC.Result_Invalid);
      end if;
   end Set_IPC_Result;

   procedure Handle_IPC_Call (Frame : System.Address) is
      Cap_Handle  : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handle_Valid : Boolean;
      Current     : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      IPC_Result       : Kernel.IPC.Status;
      Scheduler_Result : Kernel.Scheduler.Status;
   begin
      Decode_Handle (Trap_Frame_Get_A0 (Frame), Cap_Handle, Handle_Valid);
      if not Handle_Valid or else Current = null then
         Trap_Frame_Set_A0 (Frame, Kernel.IPC.Result_Invalid);
         Advance_SEPC (Frame);
         return;
      end if;

      Kernel.IPC.Call (Current, Cap_Handle, IPC_Result);

      if IPC_Result = Kernel.IPC.Would_Block then
         --  Caller queued (or delivered and awaiting reply): block
         --  until a waker writes the result code into the saved
         --  context. Pre-set invalid as a defensive default.
         Advance_SEPC (Frame);
         Trap_Frame_Set_A0 (Frame, Kernel.IPC.Result_Invalid);
         Save_Current_Context (Frame);
         Kernel.Tasks.Set_State (Current.all, Kernel.Tasks.Blocked_Send);
         Schedule_Saved_Context (Frame, Scheduler_Result);
         return;
      end if;

      Set_IPC_Result (Frame, IPC_Result);
      Advance_SEPC (Frame);
   end Handle_IPC_Call;

   procedure Handle_IPC_Recv (Frame : System.Address) is
      Cap_Handle  : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handle_Valid : Boolean;
      Current     : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      IPC_Result       : Kernel.IPC.Status;
      Scheduler_Result : Kernel.Scheduler.Status;
      Bound       : System.Address;
      Bits        : U64;
   begin
      if Current = null then
         Trap_Frame_Set_A0 (Frame, Kernel.IPC.Result_Invalid);
         Advance_SEPC (Frame);
         return;
      end if;

      --  Thread-bound notification fast path: pending bits beat an
      --  endpoint wait, delivered as a synthetic message so a
      --  server multiplexes IPC and IRQ notifications on one recv.
      Bound := Kernel.Tasks.Bound_Ntfn (Current.all);
      if Bound /= System.Null_Address then
         Bits := Kernel.Notifications.Take (Bound);
         if Bits /= 0 then
            Kernel.IPC.Write_Notification_Message (Current, Bits);
            Trap_Frame_Set_A0 (Frame, Kernel.IPC.Result_Ok);
            Advance_SEPC (Frame);
            return;
         end if;
      end if;

      Decode_Handle (Trap_Frame_Get_A0 (Frame), Cap_Handle, Handle_Valid);
      if not Handle_Valid then
         Trap_Frame_Set_A0 (Frame, Kernel.IPC.Result_Invalid);
         Advance_SEPC (Frame);
         return;
      end if;

      Kernel.IPC.Receive (Current, Cap_Handle, IPC_Result);

      if IPC_Result = Kernel.IPC.Would_Block then
         Advance_SEPC (Frame);
         Trap_Frame_Set_A0 (Frame, Kernel.IPC.Result_Invalid);
         Save_Current_Context (Frame);
         Kernel.Tasks.Set_State (Current.all, Kernel.Tasks.Blocked_Receive);
         Schedule_Saved_Context (Frame, Scheduler_Result);
         return;
      end if;

      Set_IPC_Result (Frame, IPC_Result);
      Advance_SEPC (Frame);
   end Handle_IPC_Recv;

   procedure Handle_IPC_Reply (Frame : System.Address) is
      Current     : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      IPC_Result  : Kernel.IPC.Status;
   begin
      if Current = null
        or else Trap_Frame_Get_A0 (Frame) /=
          U64 (Kernel.IPC.Reply_Cap_Handle)
      then
         Trap_Frame_Set_A0 (Frame, Kernel.IPC.Result_Invalid);
         return;
      end if;

      Kernel.IPC.Reply (Current, IPC_Result);
      Set_IPC_Result (Frame, IPC_Result);
   end Handle_IPC_Reply;

   --  mem_alloc (a0 = page count): mint a memory object cap
   --  (Map+Read+Write+Transfer+Manage rights). Returns the handle
   --  or U64'Last on failure.
   procedure Handle_Mem_Alloc (Frame : System.Address) is
      use type Kernel.Capabilities.Status;
      use type Kernel.Memory.Status;

      Pages   : constant U64 := Trap_Frame_Get_A0 (Frame);
      Current : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Mem_Result : Kernel.Memory.Status;
      Cap_Result : Kernel.Capabilities.Status;
      Object     : System.Address;
      New_Cap    : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
   begin
      if Current = null then
         Trap_Frame_Set_A0 (Frame, U64'Last);
         return;
      end if;

      Kernel.Memory.Create (Pages, Mem_Result, Object);
      if Mem_Result /= Kernel.Memory.Ok then
         Trap_Frame_Set_A0 (Frame, U64'Last);
         return;
      end if;

      --  Fresh object has refcount 0; the insert retains it to 1.
      Kernel.Tasks.Insert_Cap
        (TCB    => Current.all,
         Kind   => Kernel.Capabilities.Memory_Object,
         Object => Object,
         Rights => Kernel.Memory.Memory_Full_Rights,
         Badge  => 0,
         Result => Cap_Result,
         Cap    => New_Cap);

      if Cap_Result /= Kernel.Capabilities.Ok then
         Kernel.Memory.Discard (Object);
         Trap_Frame_Set_A0 (Frame, U64'Last);
         return;
      end if;

      Trap_Frame_Set_A0 (Frame, U64 (New_Cap));
   end Handle_Mem_Alloc;

   --  mem_map (a0 = as cap, a1 = memory cap, a2 = VA, a3 = offset,
   --  a4 = length, a5 = flags bit0 R / bit1 W): map the object's
   --  frames as borrowed user pages (frames stay object-owned).
   procedure Handle_Mem_Map (Frame : System.Address) is
      use type Kernel.Capabilities.Object_Kind;
      use type Kernel.Capabilities.Status;
      use type Kernel.Boot_Files.Status;

      Address_Space_Cap : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Cap_Handle        : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handles_Valid     : Boolean;
      VA                : constant U64 := Trap_Frame_Get_A2 (Frame);
      Offset            : constant U64 := Trap_Frame_Get_A3 (Frame);
      Length            : constant U64 := Trap_Frame_Get_A4 (Frame);
      Flags             : constant U64 := Trap_Frame_Get_A5 (Frame);
      Current    : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Cap_Result : Kernel.Capabilities.Status;
      Cap_Info   : Kernel.Capabilities.Cap_Entry;
      Map_Result : Arch.MMU.Status;
      Page_Flags : Arch.MMU.Page_Flags;
      Page_Count : U64;
   begin
      Decode_Handle
        (Trap_Frame_Get_A0 (Frame), Address_Space_Cap, Handles_Valid);
      if not Handles_Valid then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Decode_Handle (Trap_Frame_Get_A1 (Frame), Cap_Handle, Handles_Valid);
      if not Handles_Valid then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      if Current = null
        or else not Kernel.Tasks.Has_Address_Space_Map_Authority
          (Current.all, Address_Space_Cap)
      then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Current.all,
         Cap       => Cap_Handle,
         Result    => Cap_Result,
         Out_Entry => Cap_Info);

      --  Shared checks: flag bits 0 (read) / 1 (write) only, never
      --  empty, and Sv39 reserves write-without-read leaves.
      if Cap_Result /= Kernel.Capabilities.Ok
        or else (Flags and not 3) /= 0
        or else Flags = 0
        or else (Flags and 3) = 2
        or else VA < 16#4000_0000#
        or else VA + Length > 16#8000_0000#
        or else Length = 0
        or else not Is_Page_Aligned (VA)
        or else not Is_Page_Aligned (Offset)
        or else not Is_Page_Aligned (Length)
      then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Page_Flags :=
        (Read    => (Flags and 1) /= 0,
         Write   => (Flags and 2) /= 0,
         Execute => False,
         User    => True,
         Global  => False);

      if Cap_Info.Kind = Kernel.Capabilities.Boot_File_Object then
         --  Boot files as memory objects: borrowed read-only pages
         --  over the initrd image frames (pinned, never freed).
         --  File data need not start on a page boundary; a1 returns
         --  the byte offset of the file start within the first
         --  mapped page.
         declare
            Bounds_Result : Kernel.Boot_Files.Status;
            Base_VA       : U64;
            File_Length   : U64;
            PA            : U64;
            Lead_In         : U64;
         begin
            if not Cap_Info.Rights.Read
              or else Flags /= 1  --  initrd image is read-only
            then
               Trap_Frame_Set_A0 (Frame, 1);
               return;
            end if;

            Kernel.Boot_Files.Bounds
              (Cap     => Cap_Info,
               Result => Bounds_Result,
               Base   => Base_VA,
               Length => File_Length);

            --  The file's true page span: the lead-in byte offset
            --  can push file data one page past the rounded length.
            if Bounds_Result /= Kernel.Boot_Files.Ok
              or else Offset + Length >
                (((Base_VA mod Arch.MMU.Page_Size) + File_Length
                    + Arch.MMU.Page_Size - 1)
                   / Arch.MMU.Page_Size) * Arch.MMU.Page_Size
            then
               Trap_Frame_Set_A0 (Frame, 1);
               return;
            end if;

            PA := Base_VA - Arch.Physmap_Base + Offset;
            Lead_In := PA mod Arch.MMU.Page_Size;

            Page_Count := Length / Arch.MMU.Page_Size;
            for Page in U64 range 0 .. Page_Count - 1 loop
               Arch.MMU.Map_Page
                 (Root     => Kernel.Tasks.Address_Space_Root
                    (Current.all),
                  Virtual  => VA + Page * Arch.MMU.Page_Size,
                  Physical => PA - Lead_In + Page * Arch.MMU.Page_Size,
                  Flags    => Page_Flags,
                  Result   => Map_Result,
                  Borrowed => True);

               if Map_Result /= Arch.MMU.Ok then
                  Trap_Frame_Set_A0 (Frame, 1);
                  return;
               end if;
            end loop;

            Trap_Frame_Set_A1 (Frame, Lead_In);
            Trap_Frame_Set_A0 (Frame, 0);
            return;
         end;
      end if;

      if Cap_Info.Kind /= Kernel.Capabilities.Memory_Object
        or else not Cap_Info.Rights.Map
        or else ((Flags and 1) /= 0 and then not Cap_Info.Rights.Read)
        or else ((Flags and 2) /= 0 and then not Cap_Info.Rights.Write)
        or else Offset + Length >
          Kernel.Memory.Page_Count (Cap_Info.Object)
            * Kernel.Physical_Memory.Page_Size
      then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Page_Count := Length / Arch.MMU.Page_Size;
      for Page in U64 range 0 .. Page_Count - 1 loop
         Arch.MMU.Map_Page
           (Root     => Kernel.Tasks.Address_Space_Root (Current.all),
            Virtual  => VA + Page * Arch.MMU.Page_Size,
            Physical => Kernel.Memory.Frame_At
              (Cap_Info.Object, (Offset / Arch.MMU.Page_Size) + Page),
            Flags    => Page_Flags,
            Result   => Map_Result,
            Borrowed => True);

         if Map_Result /= Arch.MMU.Ok then
            Trap_Frame_Set_A0 (Frame, 1);
            return;
         end if;
      end loop;

      Trap_Frame_Set_A0 (Frame, 0);
   end Handle_Mem_Map;

   --  mem_unmap (a0 = as cap, a1 = VA, a2 = length): drop borrowed
   --  memory-object mappings; frames stay with their objects.
   procedure Handle_Mem_Unmap (Frame : System.Address) is
      Address_Space_Cap : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Handles_Valid     : Boolean;
      VA                : constant U64 := Trap_Frame_Get_A1 (Frame);
      Length            : constant U64 := Trap_Frame_Get_A2 (Frame);
      Current    : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Map_Result : Arch.MMU.Status;
      Page_Count : U64;
   begin
      Decode_Handle
        (Trap_Frame_Get_A0 (Frame), Address_Space_Cap, Handles_Valid);
      if not Handles_Valid or else Current = null
        or else not Kernel.Tasks.Has_Address_Space_Map_Authority
          (Current.all, Address_Space_Cap)
      then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      if VA < 16#4000_0000#
        or else VA + Length > 16#8000_0000#
        or else Length = 0
        or else not Is_Page_Aligned (VA)
        or else not Is_Page_Aligned (Length)
      then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Page_Count := Length / Arch.MMU.Page_Size;
      for Page in U64 range 0 .. Page_Count - 1 loop
         Arch.MMU.Unmap_Borrowed_Page
           (Root    => Kernel.Tasks.Address_Space_Root (Current.all),
            Virtual => VA + Page * Arch.MMU.Page_Size,
            Result  => Map_Result);

         if Map_Result /= Arch.MMU.Ok then
            Trap_Frame_Set_A0 (Frame, 1);
            return;
         end if;
      end loop;

      Trap_Frame_Set_A0 (Frame, 0);
   end Handle_Mem_Unmap;

   procedure Handle_Syscall (Frame : System.Address) is
      Number           : constant U64 := Trap_Frame_Get_A7 (Frame);
      Scheduler_Result : Kernel.Scheduler.Status;
   begin
      if Number = Sys_Yield then
         Advance_SEPC (Frame);
         Trap_Frame_Set_A0 (Frame, 0);

         Save_Current_Context (Frame);
         Schedule_Saved_Context (Frame, Scheduler_Result);
         return;
      elsif Number = Sys_Debug_Putchar then
         Handle_Debug_Putchar (Frame);
      elsif Number = Sys_Map_MMIO then
         Handle_Map_MMIO (Frame);
      elsif Number = Sys_IRQ_Wait then
         Handle_IRQ_Wait (Frame);
         return;
      elsif Number = Sys_IRQ_Ack then
         Handle_IRQ_Ack (Frame);
      elsif Number = Sys_Boot_File_Size then
         Handle_Boot_File_Size (Frame);
      elsif Number = Sys_Boot_Read_Byte then
         Handle_Boot_Read_Byte (Frame);
      elsif Number = Sys_Spawn then
         Handle_Spawn (Frame);
      elsif Number = Sys_Exit then
         Handle_Exit (Frame);
         return;
      elsif Number = Sys_Reap_Process then
         Handle_Reap_Process (Frame);
      elsif Number = Sys_EP_Create then
         Handle_EP_Create (Frame);
      elsif Number = Sys_IPC_Call then
         Handle_IPC_Call (Frame);
         return;
      elsif Number = Sys_IPC_Recv then
         Handle_IPC_Recv (Frame);
         return;
      elsif Number = Sys_IPC_Reply then
         Handle_IPC_Reply (Frame);
      elsif Number = Sys_Mem_Alloc then
         Handle_Mem_Alloc (Frame);
      elsif Number = Sys_Mem_Map then
         Handle_Mem_Map (Frame);
      elsif Number = Sys_Mem_Unmap then
         Handle_Mem_Unmap (Frame);
      elsif Number = Sys_Ntfn_Create then
         Handle_Ntfn_Create (Frame);
      elsif Number = Sys_Ntfn_Wait then
         Handle_Ntfn_Wait (Frame);
         return;
      elsif Number = Sys_Ntfn_Signal then
         Handle_Ntfn_Signal (Frame);
      elsif Number = Sys_Ntfn_Bind_Thread then
         Handle_Ntfn_Bind_Thread (Frame);
      elsif Number = Sys_IRQ_Bind_Ntfn then
         Handle_IRQ_Bind_Ntfn (Frame);
      else
         Trap_Frame_Set_A0 (Frame, U64'Last);
      end if;

      Advance_SEPC (Frame);
   end Handle_Syscall;

   --  SMP: every trap (user ecall, timer, external, software, fault)
   --  runs under the big kernel lock.  Kernel mode executes with
   --  sstatus.SIE clear, so acquisition is flat (never recursive).
   --  Two paths drop the lock: the trampoline itself, after this
   --  handler returns (so nothing reads the old thread's kernel
   --  stack once the lock is gone), and Idle_Loop around its wfi on
   --  the safe per-hart main stack.
   procedure Riscv_Trap_Handler (Frame : System.Address)
     with Export, Convention => C, External_Name => "riscv_trap_handler";

   procedure Dispatch_Trap (Frame : System.Address) is
      Cause : constant U64 := Arch.SBI.Scause;
      Code  : constant U64 := Cause and not Interrupt_Bit;
   begin
      if (Cause and Interrupt_Bit) = 0 and then Code = User_Ecall then
         Handle_Syscall (Frame);
         return;
      elsif (Cause and Interrupt_Bit) /= 0
        and then Code = Supervisor_Timer
      then
         Arch.SBI.Set_Timer (Arch.SBI.Time + Timer_Interval);
         Tick_Count := Tick_Count + 1;
         if Tick_Count = 1 then
            Board.UART.Put_Line ("timer interrupt online");
         end if;

         Handle_Preemption (Frame);
         return;
      elsif (Cause and Interrupt_Bit) /= 0
        and then Code = Supervisor_External
      then
         Board.Interrupts.Handle_External_Interrupt;
         return;
      elsif (Cause and Interrupt_Bit) /= 0
        and then Code = Supervisor_Software
      then
         --  IPI from a waker: the work is visible through the ready
         --  queue; this hart only needs to drop the pending bit.
         Arch.SBI.Clear_Software_Pending;
         return;
      end if;

      Arch.SBI.Disable_Interrupts;
      if not Kernel.Lock.Try_Enter_Fatal then
         --  Another hart is already dumping a fatal; halt quietly.
         Kernel.Lock.Release;
         Halt;
      end if;

      Board.UART.Put_Line_Unsafe ("unexpected trap");
      Board.UART.Put_Unsafe ("  hart   = ");
      Put_Hex_Unsafe (U64 (Kernel.CPUs.Current));
      Board.UART.Put_Line_Unsafe ("");
      Board.UART.Put_Unsafe ("  scause = ");
      Put_Hex_Unsafe (Cause);
      Board.UART.Put_Line_Unsafe ("");

      if Kernel.Scheduler.Current /= null then
         Board.UART.Put_Unsafe ("  thread = ");
         Put_Hex_Unsafe (U64 (Kernel.Tasks.Thread_Id'Pos
                   (Kernel.Tasks.Id (Kernel.Scheduler.Current.all))));
         Board.UART.Put_Line_Unsafe ("");
      end if;

      Board.UART.Put_Unsafe ("  sepc   = ");
      Put_Hex_Unsafe (Arch.SBI.Sepc);
      Board.UART.Put_Line_Unsafe ("");

      Board.UART.Put_Unsafe ("  stval  = ");
      Put_Hex_Unsafe (Arch.SBI.Stval);
      Board.UART.Put_Line_Unsafe ("");
      Kernel.Lock.Release;
      Halt;
   end Dispatch_Trap;

   procedure Riscv_Trap_Handler (Frame : System.Address) is
   begin
      Kernel.Lock.Acquire;
      Dispatch_Trap (Frame);
      --  No Release here: the trampoline releases the lock after
      --  this handler returns (see startup.s), so the return path
      --  above is the last read of the old thread's kernel stack
      --  while the lock still guarantees that stack is ours.
   exception
      when others =>
         if not Kernel.Lock.Try_Enter_Fatal then
            Halt;
         end if;
         Board.UART.Put_Line_Unsafe ("fatal: exception in trap handler");
         Board.UART.Put_Unsafe ("  sepc   = ");
         Put_Hex_Unsafe (Arch.SBI.Sepc);
         Board.UART.Put_Line_Unsafe ("");
         Halt;
   end Riscv_Trap_Handler;

   --  Secondary hart kernel entry (called from secondary_boot asm
   --  with trap/main stacks, stvec, satp and the hart slot set up).
   --  Joins the same idle/scheduling loop the boot hart's trap
   --  handler drops into when no work exists; never returns.
   procedure Secondary_Main
     with Export, Convention => C, External_Name => "secondary_main";

   procedure Secondary_Main is
      Self : constant Kernel.CPUs.CPU_Index := Kernel.CPUs.Current;
   begin
      Kernel.Lock.Acquire;
      Kernel.CPUs.Mark_Started (Self);
      Board.UART.Put ("hart ");
      Board.UART.Put_Decimal (Natural (Self));
      Board.UART.Put_Line (" online");
      Arch.SBI.Set_Timer (Arch.SBI.Time + Timer_Interval);
      Arch.SBI.Enable_Timer_And_Software_SIE;
      Idle_Loop;
   end Secondary_Main;

   procedure Initialize is
   begin
      Arch.SBI.Set_Timer (Arch.SBI.Time + Timer_Interval);
      Arch.SBI.Enable_Timer_Interrupts;
      Arch.SBI.Enable_External_Interrupts;
      Arch.SBI.Enable_Software_Interrupts;
   end Initialize;
end Arch.Traps;
