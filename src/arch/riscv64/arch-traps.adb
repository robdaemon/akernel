with System;
with Ada.Unchecked_Conversion;
with Arch.MMU;
with Arch.SBI;
with Board.Interrupts;
with Board.PLIC;
with Board.UART;
with Kernel.Boot_Files;
with Kernel.Capabilities;
with Kernel.Interrupts;
with Kernel.Objects;
with Kernel.Processes;
with Kernel.Scheduler;
with Kernel.Tasks;

package body Arch.Traps is
   use type Arch.MMU.Status;
   use type Kernel.Processes.Status;
   use type Kernel.Objects.IRQ_Line_Access;
   use type Kernel.Scheduler.Status;
   use type Kernel.Tasks.Thread_Access;

   Timer_Ticks_Per_Second : constant U64 := 10_000_000;
   Timer_Interval        : constant U64 := Timer_Ticks_Per_Second;
   Interrupt_Bit         : constant U64 := 16#8000_0000_0000_0000#;
   User_Ecall            : constant U64 := 8;
   Supervisor_Timer      : constant U64 := 5;
   Supervisor_External   : constant U64 := 9;

   Sys_Yield             : constant U64 := 0;
   Sys_Debug_Putchar     : constant U64 := 1;
   Sys_Map_MMIO          : constant U64 := 2;
   Sys_IRQ_Wait          : constant U64 := 3;
   Sys_IRQ_Ack           : constant U64 := 4;
   Sys_Boot_File_Size    : constant U64 := 6;
   Sys_Boot_Read_Byte    : constant U64 := 7;
   Sys_Spawn_Boot_Path   : constant U64 := 8;
   Sys_Exit              : constant U64 := 9;
   Sys_Reap_Process      : constant U64 := 10;

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

   procedure Advance_SEPC (Frame : System.Address)
     with Import, Convention => C, External_Name => "trap_frame_advance_sepc";

   function Trap_Frame_For_Stack (Stack_Top : U64) return System.Address
     with Import, Convention => C, External_Name => "trap_frame_for_stack";

   procedure Set_Kernel_Trap_Stack (Stack_Top : U64) is
   begin
      Raw_Set_Trap_Stack (Stack_Top);
   end Set_Kernel_Trap_Stack;

   function Hex_Digit (Nibble : U64) return Character is
      Hex : constant String := "0123456789abcdef";
   begin
      return Hex (Natural (Nibble) + 1);
   end Hex_Digit;

   procedure Put_Hex (Value : U64) is
      Shift : Natural := 60;
   begin
      Board.UART.Put ("0x");
      loop
         Board.UART.Put
           ((1 => Hex_Digit
              (Interfaces.Shift_Right (Value, Shift) and 16#f#)));
         exit when Shift = 0;
         Shift := Shift - 4;
      end loop;
   end Put_Hex;

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
               Set_Kernel_Trap_Stack (Arch.Phys_To_Virt (Top));
               --  Restore context into the newly current thread's own
               --  kernel stack frame (reached through the physmap);
               --  the exit trampoline finds it via sscratch and
               --  installs the frame's satp slot.
               Kernel.Tasks.Restore_Trap_Context
                 (TCB   => Current.all,
                  Frame => Trap_Frame_For_Stack (Arch.Phys_To_Virt (Top)));
            end if;
         end;
      elsif Result /= Kernel.Scheduler.Ok then
         Trap_Frame_Set_A0 (Frame, U64'Last);
      end if;
   end Restore_Scheduled_Context;

   procedure Schedule_Saved_Context
     (Frame  : System.Address;
      Result : out Kernel.Scheduler.Status)
   is
   begin
      loop
         Kernel.Scheduler.Yield (Result);
         exit when Result /= Kernel.Scheduler.Queue_Empty
           and then (Result /= Kernel.Scheduler.Ok
                     or else Kernel.Scheduler.Current /= null);
         Arch.SBI.Wait_For_Interrupt;
      end loop;

      Restore_Scheduled_Context (Frame, Result);
   end Schedule_Saved_Context;

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
         return;
      end if;

      Line := To_IRQ_Line (Cap_Info.Object);
      if Line = null then
         Trap_Frame_Set_A0 (Frame, 1);
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

   procedure Handle_Spawn_Boot_Path (Frame : System.Address) is
      Path_Offset : constant U64 := Trap_Frame_Get_A0 (Frame);
      Path_Length : constant U64 := Trap_Frame_Get_A1 (Frame);
      Grant_Mask  : constant U64 := Trap_Frame_Get_A2 (Frame);
      Current     : constant Kernel.Tasks.Thread_Access :=
        Kernel.Scheduler.Current;
      Result      : Kernel.Processes.Status;
      Process_Cap : Kernel.Capabilities.Handle;
   begin
      Kernel.Processes.Spawn_Boot_Path
        (Parent      => Current,
         Path_Offset => Path_Offset,
         Path_Length => Path_Length,
         Grant_Mask  => Grant_Mask,
         Result      => Result,
         Process_Cap => Process_Cap);

      Trap_Frame_Set_A0 (Frame, Process_Status_Code (Result));
      if Result = Kernel.Processes.Ok then
         Trap_Frame_Set_A1 (Frame, U64 (Process_Cap));
      else
         Trap_Frame_Set_A1 (Frame, 0);
      end if;
   end Handle_Spawn_Boot_Path;

   procedure Handle_Boot_File_Size (Frame : System.Address) is
      use type Kernel.Boot_Files.Status;

      File_Id : constant U64 := Trap_Frame_Get_A0 (Frame);
      Result  : Kernel.Boot_Files.Status;
      Length  : U64;
   begin
      Kernel.Boot_Files.Size
        (File_Id => File_Id,
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

      File_Id : constant U64 := Trap_Frame_Get_A0 (Frame);
      Offset  : constant U64 := Trap_Frame_Get_A1 (Frame);
      Result  : Kernel.Boot_Files.Status;
      Value   : U64;
   begin
      Kernel.Boot_Files.Read_Byte
        (File_Id => File_Id,
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

      Kernel.Processes.Mark_Exited (Current);
      Advance_SEPC (Frame);
      Kernel.Scheduler.Exit_Current (Exit_Result);
      if Exit_Result /= Kernel.Scheduler.Ok then
         Trap_Frame_Set_A0 (Frame, 1);
         return;
      end if;

      Schedule_Saved_Context (Frame, Scheduler_Result);
   end Handle_Exit;

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
         Board.UART.Put
           ((1 => Character'Val
              (Natural (Trap_Frame_Get_A0 (Frame) and 16#ff#))));
         Trap_Frame_Set_A0 (Frame, 0);
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
      elsif Number = Sys_Spawn_Boot_Path then
         Handle_Spawn_Boot_Path (Frame);
      elsif Number = Sys_Exit then
         Handle_Exit (Frame);
         return;
      elsif Number = Sys_Reap_Process then
         Handle_Reap_Process (Frame);
      else
         Trap_Frame_Set_A0 (Frame, U64'Last);
      end if;

      Advance_SEPC (Frame);
   end Handle_Syscall;

   procedure Riscv_Trap_Handler (Frame : System.Address)
     with Export, Convention => C, External_Name => "riscv_trap_handler";

   procedure Riscv_Trap_Handler (Frame : System.Address) is
      Cause : constant U64 := Arch.SBI.Scause;
      Code  : constant U64 := Cause and not Interrupt_Bit;
   begin
      if (Cause and Interrupt_Bit) = 0 and then Code = User_Ecall then
         Handle_Syscall (Frame);
         return;
      elsif (Cause and Interrupt_Bit) /= 0
        and then Code = Supervisor_Timer
      then
         Tick_Count := Tick_Count + 1;
         if Tick_Count = 1 then
            Board.UART.Put_Line ("timer interrupt online");
         else
            Board.UART.Put (".");
         end if;

         Arch.SBI.Set_Timer (Arch.SBI.Time + Timer_Interval);
         return;
      elsif (Cause and Interrupt_Bit) /= 0
        and then Code = Supervisor_External
      then
         Board.Interrupts.Handle_External_Interrupt;
         return;
      end if;

      Arch.SBI.Disable_Interrupts;
      Board.UART.Put_Line ("unexpected trap");
      Board.UART.Put ("  scause = ");
      Put_Hex (Cause);
      Board.UART.Put_Line ("");

      Board.UART.Put ("  sepc   = ");
      Put_Hex (Arch.SBI.Sepc);
      Board.UART.Put_Line ("");

      Board.UART.Put ("  stval  = ");
      Put_Hex (Arch.SBI.Stval);
      Board.UART.Put_Line ("");
      Halt;
   end Riscv_Trap_Handler;

   procedure Initialize is
   begin
      Arch.SBI.Set_Timer (Arch.SBI.Time + Timer_Interval);
      Arch.SBI.Enable_Timer_Interrupts;
      Arch.SBI.Enable_External_Interrupts;
   end Initialize;
end Arch.Traps;
