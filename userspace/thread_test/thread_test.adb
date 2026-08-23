with Interfaces;
with System;
with System.Machine_Code;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Thread_Test_Sync;

procedure Thread_Test is
   subtype U64 is Interfaces.Unsigned_64;
   use type U64;
   use type Interfaces.Unsigned_32;
   use type System.Storage_Elements.Integer_Address;

   package SYS renames Akernel_User.Syscalls;

   Page_Size : constant U64 := 4096;

   --  Worker VAs sit above the args page (0x4800_0000) and below the
   --  initial-thread IPC buffer (0x6FFF_0000).
   Stack_VA : constant U64 := 16#4A002000#;  --  initial sp
   IPC_VA   : constant U64 := 16#4A003000#;
   TLS_VA   : constant U64 := 16#4A004000#;

   Main_Id    : constant U64 := SYS.Thread_Self;
   Stack_Cap  : U64;
   IPC_Cap    : U64;
   TLS_Cap    : U64;
   Thread_Cap : U64;
   Ignore     : U64;
   Now        : U64;
   Deadline   : U64;
   Worker_Addr : constant U64 :=
     U64 (System.Storage_Elements.To_Integer (Thread_Test_Sync.Worker'Address));

   procedure Die (Code : U64) with No_Return;
   procedure Die (Code : U64) is
   begin
      --  Exit this thread.  When the worker is the last live thread
      --  the process goes down with it; using Thread_Exit instead of
      --  Process_Exit avoids the main thread tearing down the worker
      --  while the worker is still in its Thread_Exit syscall.
      if Code = 0 then
         SYS.Thread_Exit;
      else
         SYS.Process_Exit (Code);
      end if;
      loop null; end loop;
   end Die;

begin
   SYS.Debug_Put_Line ("thread_test: start");

   if Main_Id = 0 then
      SYS.Debug_Put_Line ("FAIL thread_test: Thread_Self returned 0");
      Die (1);
   end if;

   --  Allocate backing memory for the worker stack, IPC buffer and TLS.
   Stack_Cap := SYS.Mem_Alloc (1);
   IPC_Cap   := SYS.Mem_Alloc (1);
   TLS_Cap   := SYS.Mem_Alloc (1);
   if Stack_Cap = SYS.Syscall_Failed
     or else IPC_Cap = SYS.Syscall_Failed
     or else TLS_Cap = SYS.Syscall_Failed
   then
      SYS.Debug_Put_Line ("FAIL thread_test: Mem_Alloc failed");
      Die (1);
   end if;

   --  Map the TLS buffer into the current address space.  The kernel
   --  maps the stack and IPC buffer from the Thread_Create caps.
   Ignore := SYS.Mem_Map
     (Address_Space => 0,
      Cap           => TLS_Cap,
      VA            => TLS_VA,
      Offset        => 0,
      Length        => Page_Size,
      Flags         => SYS.Right_Read or SYS.Right_Write);

   --  Write the parameter block into the initial thread's IPC buffer.
   --  Entry_PC is the generic runtime trampoline; the real worker
   --  function address travels in the argument word.
   SYS.Thread_Create_Write_Params
     (Params =>
        (Stack_VA      => Stack_VA,
         Stack_Pages   => 1,
         Entry_PC      => SYS.Thread_Entry_Point,
         Arg           => Worker_Addr,
         TLS_Base      => TLS_VA,
         Priority_Bits => 0,
         Stack_Cap     => Stack_Cap,
         IPC_Cap       => IPC_Cap,
         IPC_VA        => IPC_VA));

   Thread_Cap := SYS.Thread_Create;
   if Thread_Cap = U64'Last then
      SYS.Debug_Put_Line ("FAIL thread_test: Thread_Create failed");
      Die (1);
   end if;

   SYS.Debug_Put_Line
     ("thread_test: created worker, cap=" & Thread_Cap'Image);

   --  Wait for the worker to set the flag, with a 1 s timeout.
   --  Use timer sleeps rather than a tight yield loop so the worker
   --  gets a chance to run even if preemption is lazy.
   Now      := SYS.Read_Time;
   Deadline := Now + 10_000_000;  --  1 s at 10 MHz
   while Thread_Test_Sync.Worker_Done = 0
     and then SYS.Read_Time < Deadline
   loop
      System.Machine_Code.Asm ("fence", Volatile => True);
      Ignore := SYS.Sleep_Until (SYS.Read_Time + 10_000);  --  1 ms
   end loop;

   if Thread_Test_Sync.Worker_Done = 0 then
      SYS.Debug_Put_Line ("FAIL thread_test: worker timed out");
      Die (1);
   end if;

   --  Also exercise Thread_Wait: it should return immediately
   --  because the worker has already exited.
   Ignore := SYS.Thread_Wait (Thread_Cap);
   if Ignore /= 0 then
      SYS.Debug_Put_Line ("FAIL thread_test: Thread_Wait returned " & Ignore'Image);
      Die (1);
   end if;

   SYS.Debug_Put_Line ("PASS thread_test");
   Die (0);
end Thread_Test;
