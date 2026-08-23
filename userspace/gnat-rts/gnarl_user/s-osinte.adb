------------------------------------------------------------------------------
--                                                                          --
--                  GNAT RUN-TIME LIBRARY (GNARL) COMPONENTS                --
--                                                                          --
--                    S Y S T E M . O S _ I N T E R F A C E                 --
--                                                                          --
--                                  B o d y                                 --
--                                                                          --
--                      Akernel Ravenscar port (M67b)                       --
--                                                                          --
------------------------------------------------------------------------------

--  Minimal body mapping the GNARL OS interface onto the Akernel syscall
--  layer. This replaces the light-tasking-polarfiresoc System.BB layer.

pragma Style_Checks (Off);
pragma Warnings (Off);

with Ada.Unchecked_Conversion;
with System.Storage_Elements;

package body System.OS_Interface is

   use type Interfaces.Unsigned_64;

   Page_Size : constant System.Storage_Elements.Storage_Count := 4096;

   subtype U64 is Interfaces.Unsigned_64;

   function U64_To_Address is new Ada.Unchecked_Conversion
     (Source => U64, Target => System.Address);

   function To_U64 (X : System.Storage_Elements.Storage_Offset) return U64 is
      (Interfaces.Unsigned_64 (X));

   --  Imported linker symbols for the TLS template.
   __tls_init_start : U64;
   pragma Import (C, __tls_init_start, "__tls_init_start");

   __tls_init_end : U64;
   pragma Import (C, __tls_init_end, "__tls_init_end");

   __tls_bss_start : U64;
   pragma Import (C, __tls_bss_start, "__tls_bss_start");

   __tls_bss_end : U64;
   pragma Import (C, __tls_bss_end, "__tls_bss_end");

   --  Raw Akernel syscalls (provided by libakernel / the program).

   function Raw_Thread_Self return U64
     with Import, Convention => C, External_Name => "akernel_sys_thread_self";

   procedure Raw_Thread_Exit
     with Import, Convention => C, External_Name => "akernel_sys_thread_exit";

   function Raw_Thread_Create return U64
     with Import, Convention => C, External_Name => "akernel_sys_thread_create";

   function Raw_Sleep_Until (Deadline : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_sleep_until";

   function Raw_Mem_Alloc (Pages : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_mem_alloc";

   function Raw_Mem_Map
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Flags         : U64) return U64
     with Import, Convention => C, External_Name => "akernel_sys_mem_map";

   function Raw_Set_Priority
     (Target       : U64;
      New_Priority : U64;
      Old_Priority : System.Address) return U64
     with Import, Convention => C, External_Name => "akernel_sys_set_priority";

   function Raw_Read_Time return U64
     with Import, Convention => C, External_Name => "akernel_rdtime";

   procedure Raw_Yield
     with Import, Convention => C, External_Name => "akernel_sys_yield";

   procedure Raw_Debug_Putchar (C : U64)
     with Import, Convention => C, External_Name => "akernel_sys_debug_putchar";

   function Thread_Entry_Point return U64
     with Import, Convention => C, External_Name => "akernel_thread_entry";

   --  Fixed VA windows for secondary-thread resources. The initial thread
   --  keeps the legacy IPC buffer at 0x6FFF_0000 mapped by the kernel at
   --  spawn. Secondary threads use a small window below that.
   Initial_IPC_VA : constant U64 := 16#6FFF_0000#;
   Next_Stack_VA  : U64;
   Next_TLS_VA    : U64;
   Next_IPC_VA    : U64;

   Max_Threads     : constant := 64;
   Descriptor_Table : array (0 .. Max_Threads - 1) of Thread_Id;
   pragma Suppress_Initialization (Descriptor_Table);
   ATCB_Table       : array (0 .. Max_Threads - 1) of System.Address;
   pragma Suppress_Initialization (ATCB_Table);
   Priority_Table   : array (0 .. Max_Threads - 1) of Integer;
   pragma Suppress_Initialization (Priority_Table);

   function Kernel_Id return U64 is (Raw_Thread_Self);

   function Table_Index (Id : U64) return Natural is
   begin
      return Natural (Id mod U64 (Max_Threads));
   end Table_Index;

   function TLS_Size return System.Storage_Elements.Storage_Offset is
      use System.Storage_Elements;
      Init_Size : constant Storage_Offset :=
        Storage_Offset (__tls_init_end - __tls_init_start);
      Bss_Size  : constant Storage_Offset :=
        Storage_Offset (__tls_bss_end - __tls_bss_start);
      Total     : constant Storage_Offset := Init_Size + Bss_Size;
   begin
      return (Total + Page_Size - 1) / Page_Size * Page_Size;
   end TLS_Size;

   procedure Copy_TLS (Dest : System.Address) is
      use System.Storage_Elements;
      Init_Size : constant Storage_Offset :=
        Storage_Offset (__tls_init_end - __tls_init_start);
      Bss_Size  : constant Storage_Offset :=
        Storage_Offset (__tls_bss_end - __tls_bss_start);
      Src  : System.Address := U64_To_Address (__tls_init_start);
      Dst  : System.Address := Dest;
      Zero : System.Address := Dest + Init_Size;
   begin
      for I in 1 .. Init_Size loop
         declare
            V : Interfaces.Unsigned_8
              with Address => Src, Volatile => True;
            W : Interfaces.Unsigned_8
              with Address => Dst, Volatile => True;
         begin
            W := V;
         end;
         Src := System.Storage_Elements."+" (Src, Storage_Offset'(1));
         Dst := System.Storage_Elements."+" (Dst, Storage_Offset'(1));
      end loop;
      for I in 1 .. Bss_Size loop
         declare
            V : Interfaces.Unsigned_8
              with Address => Zero, Volatile => True;
         begin
            V := 0;
         end;
         Zero := System.Storage_Elements."+" (Zero, Storage_Offset'(1));
      end loop;
   end Copy_TLS;

   ----------------
   -- Interrupts --
   ----------------

   procedure Attach_Handler
     (Handler : Interrupt_Handler;
      Id      : Interrupt_ID;
      PO_Prio : Interrupt_Priority)
   is
      pragma Unreferenced (Handler, Id, PO_Prio);
   begin
      null;
   end Attach_Handler;

   procedure Power_Down is
   begin
      Raw_Yield;
   end Power_Down;

   ----------
   -- Time --
   ----------

   function Clock return Time is
   begin
      return Time (Raw_Read_Time);
   end Clock;

   procedure Delay_Until (T : Time) is
      Ignore : U64;
   begin
      Ignore := Raw_Sleep_Until (U64 (T));
   end Delay_Until;

   -------------
   -- Threads --
   -------------

   procedure Initialize
     (Environment_Thread : Thread_Id;
      Main_Priority      : System.Any_Priority)
   is
      Id : constant U64 := Kernel_Id;
   begin
      Next_Stack_VA := 16#6F00_0000#;
      Next_TLS_VA   := 16#6F10_0000#;
      Next_IPC_VA   := 16#6FFE_0000#;
      Descriptor_Table (Table_Index (Id)) := Environment_Thread;
      Priority_Table (Table_Index (Id)) := Integer (Main_Priority);
   end Initialize;

   procedure Initialize_Slave
     (Idle_Thread   : Thread_Id;
      Idle_Priority : Integer;
      Stack_Address : System.Address;
      Stack_Size    : System.Storage_Elements.Storage_Offset)
   is
      pragma Unreferenced
        (Idle_Thread, Idle_Priority, Stack_Address, Stack_Size);
   begin
      null;
   end Initialize_Slave;

   procedure Thread_Create
     (Id            : Thread_Id;
      Code          : System.Address;
      Arg           : System.Address;
      Priority      : Integer;
      Base_CPU      : System.Multiprocessors.CPU_Range;
      Stack_Address : System.Address;
      Stack_Size    : System.Storage_Elements.Storage_Offset)
   is
      pragma Unreferenced (Base_CPU, Code, Stack_Address);
      use System.Storage_Elements;

      Stack_Pages : constant U64 :=
        To_U64 ((Stack_Size + Page_Size - 1) / Page_Size);
      Stack_Top  : constant U64 := Next_Stack_VA + To_U64 (Stack_Size);
      TLS_Base   : constant U64 := Next_TLS_VA;
      IPC_VA     : constant U64 := Next_IPC_VA;

      Stack_Cap  : U64;
      IPC_Cap    : U64;
      TLS_Cap    : U64;
      Thread_Cap : U64;
      Ignore     : U64;

      type Param_Block is record
         Stack_VA      : U64;
         Stack_Pages   : U64;
         Entry_PC      : U64;
         Arg           : U64;
         TLS_Base      : U64;
         Priority_Bits : U64;
         Stack_Cap     : U64;
         IPC_Cap       : U64;
         IPC_VA        : U64;
      end record;
      pragma Convention (C, Param_Block);

      P : Param_Block
        with Volatile, Address => U64_To_Address (Initial_IPC_VA + 8);
   begin
      Stack_Cap := Raw_Mem_Alloc (Stack_Pages);
      IPC_Cap   := Raw_Mem_Alloc (1);
      TLS_Cap   := Raw_Mem_Alloc (To_U64 (TLS_Size / Page_Size));

      if Stack_Cap = U64'Last or else IPC_Cap = U64'Last
        or else TLS_Cap = U64'Last
      then
         Raw_Debug_Putchar (Character'Pos ('E'));
         return;
      end if;

      Ignore := Raw_Mem_Map
        (Address_Space => 0,
         Cap           => TLS_Cap,
         VA            => TLS_Base,
         Offset        => 0,
         Length        => To_U64 (TLS_Size),
         Flags         => 3);

      Copy_TLS (U64_To_Address (TLS_Base));

      P :=
        (Stack_VA      => Stack_Top,
         Stack_Pages   => Stack_Pages,
         Entry_PC      => Thread_Entry_Point,
         Arg           => To_U64 (System.Storage_Elements.Storage_Offset (To_Integer (Arg))),
         TLS_Base      => TLS_Base,
         Priority_Bits => To_U64 (System.Storage_Elements.Storage_Offset (Priority)),
         Stack_Cap     => Stack_Cap,
         IPC_Cap       => IPC_Cap,
         IPC_VA        => IPC_VA);

      Thread_Cap := Raw_Thread_Create;

      if Thread_Cap = U64'Last then
         Raw_Debug_Putchar (Character'Pos ('C'));
         return;
      end if;

      Id.Cap := Thread_Cap;

      Next_Stack_VA :=
        Next_Stack_VA + Stack_Pages * To_U64 (Page_Size) + To_U64 (Page_Size);
      Next_TLS_VA   :=
        Next_TLS_VA + To_U64 (TLS_Size) + To_U64 (Page_Size);
      Next_IPC_VA   := Next_IPC_VA - To_U64 (Page_Size);
   end Thread_Create;

   function Thread_Self return Thread_Id is
   begin
      return Descriptor_Table (Table_Index (Kernel_Id));
   end Thread_Self;

   procedure Set_ATCB (Id : Thread_Id; ATCB : System.Address) is
      Idx : constant Natural := Table_Index (Id.Cap);
   begin
      Descriptor_Table (Idx) := Id;
      ATCB_Table (Idx) := ATCB;
   end Set_ATCB;

   function Get_ATCB return System.Address is
   begin
      return ATCB_Table (Table_Index (Kernel_Id));
   end Get_ATCB;

   procedure Set_Priority (Priority : Integer) is
      Id  : constant U64 := Kernel_Id;
      Old : aliased U64 := 0;
      Ignore : U64;
   begin
      Ignore := Raw_Set_Priority
        (Target       => U64'Last,
         New_Priority => To_U64 (System.Storage_Elements.Storage_Offset (Priority)),
         Old_Priority => Old'Address);
      Priority_Table (Table_Index (Id)) := Priority;
   end Set_Priority;

   function Get_Priority (Id : Thread_Id) return Integer is
   begin
      return Priority_Table (Table_Index (Id.Cap));
   end Get_Priority;

   procedure Sleep is
   begin
      Raw_Thread_Exit;
   end Sleep;

   procedure Wakeup (Id : Thread_Id) is
      pragma Unreferenced (Id);
   begin
      null;
   end Wakeup;

   function Get_Affinity (Id : Thread_Id) return Multiprocessors.CPU_Range is
      pragma Unreferenced (Id);
   begin
      return Multiprocessors.Not_A_Specific_CPU;
   end Get_Affinity;

   function Get_CPU (Id : Thread_Id) return Multiprocessors.CPU is
      pragma Unreferenced (Id);
   begin
      return Multiprocessors.CPU'First;
   end Get_CPU;

   function Current_Priority
     (CPU_Id : Multiprocessors.CPU) return System.Any_Priority
   is
      pragma Unreferenced (CPU_Id);
   begin
      return System.Any_Priority'First;
   end Current_Priority;

   function Current_CPU return Multiprocessors.CPU is
   begin
      return Multiprocessors.CPU'First;
   end Current_CPU;

end System.OS_Interface;
