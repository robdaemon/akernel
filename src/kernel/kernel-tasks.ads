with Arch.Context;
with Kernel.Capabilities;
with System;

package Kernel.Tasks is
   type Process_Id is new Natural;
   type Thread_Id is new Natural;

   type Thread_State is
     (Ready,
      Running,
      Blocked_Send,
      Blocked_Receive,
      Blocked_IRQ,
      Blocked_Notification,
      Blocked_Sleeping,
      Blocked_Thread_Wait,
      Dead);

   type Process_State is
     (Process_Initializing,
      Process_Alive,
      Process_Dead);

   type Process_Control_Block is private;
   type Process_Access is access all Process_Control_Block;

   type Thread_Control_Block is private;
   type Thread_Access is access all Thread_Control_Block;

   --  FIXED ABI value: userspace hardcodes 255 (s-memory.adb
   --  AS_Cap). Was Handle'Last — when Max_Caps grew past 256 this
   --  silently moved the handle and every userspace mem_map broke
   --  (milestone 38 burn). Never derive ABI handles from Max_Caps.
   Address_Space_Cap_Handle : constant Kernel.Capabilities.Handle :=
     255;

   --  Per-thread IPC buffer page user VA (just below user stack top).
   --  Fixed per address space: one IPC buffer page per process while
   --  processes have a single thread. The frame is kernel-allocated
   --  at spawn, mapped User_RW, and freed by user-address-space
   --  teardown; its physical address is recorded in the TCB.
   IPC_Buffer_VA : constant Kernel.Capabilities.U64 := 16#6FFF_0000#;

   procedure Initialize_Process
     (PCB : out Process_Control_Block;
      Id  : Process_Id);

   procedure Initialize_Thread
     (TCB     : out Thread_Control_Block;
      Id      : Thread_Id;
      Process : not null Process_Access);

   function Id (TCB : Thread_Control_Block) return Thread_Id;

   function Process_Id_Of (PCB : Process_Control_Block) return Process_Id;

   --  Introspection (milestone 37a): the process that spawned this
   --  one, recorded at spawn time (0 = kernel-started, e.g. init).
   --  Historical record: stable for tree display/teardown even
   --  after the spawner itself exits.
   function Spawner_Id (PCB : Process_Control_Block) return Process_Id;

   --  Exit status (milestone 40b): the code the process passed to
   --  the exit syscall (Amiga RC convention in userspace: 0 ok,
   --  5 warn, 10 error, 20 fail); 0 when the process died without
   --  exiting (fault, teardown).
   procedure Set_Exit_Code
     (PCB  : in out Process_Control_Block;
      Code : Kernel.Capabilities.U64);
   function Exit_Code
     (PCB : Process_Control_Block) return Kernel.Capabilities.U64;

   procedure Set_Spawner_Id
     (PCB     : in out Process_Control_Block;
      Spawner : Process_Id);

   function Owning_Process (TCB : Thread_Control_Block) return Process_Access;

   function State (TCB : Thread_Control_Block) return Thread_State;

   function Lifecycle_State
     (PCB : Process_Control_Block) return Process_State;

   procedure Set_Process_State
     (PCB       : in out Process_Control_Block;
      New_State : Process_State);

   function Process_Address_Space_Root
     (PCB : Process_Control_Block) return Kernel.Capabilities.U64;

   function Address_Space_Root (TCB : Thread_Control_Block)
      return Kernel.Capabilities.U64;

   procedure Set_Address_Space_Root
     (TCB  : in out Thread_Control_Block;
      Root : Kernel.Capabilities.U64);

   procedure Set_Process_Address_Space_Root
     (PCB  : in out Process_Control_Block;
      Root : Kernel.Capabilities.U64);

   procedure Install_Address_Space_Cap
     (PCB    : in out Process_Control_Block;
      Result : out Kernel.Capabilities.Status);

   function Has_Address_Space_Map_Authority
     (TCB : Thread_Control_Block;
      Cap : Kernel.Capabilities.Handle) return Boolean;

   procedure Save_Trap_Context
     (TCB   : in out Thread_Control_Block;
      Frame : System.Address);

   procedure Restore_Trap_Context
     (TCB   : Thread_Control_Block;
      Frame : System.Address);

   procedure Set_Kernel_Stack_Top
     (TCB       : in out Thread_Control_Block;
      Stack_Top : Kernel.Capabilities.U64);

   function Kernel_Stack_Top
     (TCB : Thread_Control_Block) return Kernel.Capabilities.U64;

   procedure Set_IPC_Buffer
     (TCB     : in out Thread_Control_Block;
      Phys_PA : Kernel.Capabilities.U64);

   function IPC_Buffer_PA
     (TCB : Thread_Control_Block) return Kernel.Capabilities.U64;

   --  Per-thread IPC buffer user VA (tasking). The initial thread of
   --  each process keeps the legacy IPC_Buffer_VA constant; secondary
   --  threads allocate their own page and the kernel records the VA.
   procedure Set_IPC_Buffer_VA
     (TCB     : in out Thread_Control_Block;
      User_VA : Kernel.Capabilities.U64);

   function IPC_Buffer_VA_Of
     (TCB : Thread_Control_Block) return Kernel.Capabilities.U64;

   procedure Initialize_Context
     (TCB       : in out Thread_Control_Block;
      PC        : Kernel.Capabilities.U64;
      Stack     : Kernel.Capabilities.U64;
      User_Satp : Kernel.Capabilities.U64;
      TLS_Base  : Kernel.Capabilities.U64 := 0;
      Arg       : Kernel.Capabilities.U64 := 0);

   function Has_Context (TCB : Thread_Control_Block) return Boolean;

   --  Snapshot of the saved frame for introspection
   --  (Sys_Thread_Regs); meaningful only while the thread is
   --  blocked (a running thread's live registers are not here).
   procedure Read_Context_Words
     (TCB   : Thread_Control_Block;
      Words : out Arch.Context.Context_Word_Array);

   function Is_Queued (TCB : Thread_Control_Block) return Boolean;

   procedure Set_Queued
     (TCB    : in out Thread_Control_Block;
      Queued : Boolean);

   --  Endpoint caller-queue membership (m72b): while the thread
   --  sits on an endpoint's caller queue this records WHICH
   --  endpoint, so thread-death paths can unlink it. Without the
   --  back-pointer a thread killed mid-call stayed linked, and the
   --  recycled slot later cross-delivered IPC to an innocent thread
   --  (the m72a/m72b wedge forensics).
   function Queued_On_EP
     (TCB : Thread_Control_Block) return System.Address;

   procedure Set_Queued_On_EP
     (TCB    : in out Thread_Control_Block;
      Object : System.Address);

   --  Scheduling priority (milestone 62), Amiga task-priority
   --  lineage: -128 .. 127, default 0.  The scheduler always runs
   --  the highest-priority ready thread; ties break boosted-first
   --  (freshly woken), then FIFO.  A strictly higher priority
   --  becoming ready preempts a running lower-priority thread
   --  immediately (IPI + syscall-exit check); equal priorities
   --  round-robin on the 20 Hz tick exactly as before.
   subtype Thread_Priority is Integer range -128 .. 127;

   function Priority (TCB : Thread_Control_Block) return Thread_Priority;

   procedure Set_Priority
     (TCB          : in out Thread_Control_Block;
      New_Priority : Thread_Priority);

   --  Wakeup boost: set when a blocked thread is woken (IPC
   --  transfer, notification), cleared when it blocks again.
   --  Boosted threads requeue at the FRONT of the ready queue so
   --  a CPU hog cannot steal quanta from rendezvous handoffs.
   function Is_Boosted (TCB : Thread_Control_Block) return Boolean;

   procedure Set_Boosted
     (TCB     : in out Thread_Control_Block;
      Boosted : Boolean);

   --  Absolute deadline stored when the thread enters the kernel
   --  sleep queue (milestone 66b).
   procedure Set_Sleep_Deadline
     (TCB      : in out Thread_Control_Block;
      Deadline : Kernel.Capabilities.U64);

   function Sleep_Deadline
     (TCB : Thread_Control_Block) return Kernel.Capabilities.U64;

   procedure Set_State
     (TCB       : in out Thread_Control_Block;
      New_State : Thread_State);

   --  Reply-cap bookkeeping: set when a caller's message has been
   --  delivered and it waits for a reply; cleared when the reply
   --  arrives or fails.
   procedure Set_Awaiting_Reply
     (TCB      : in out Thread_Control_Block;
      Awaiting : Boolean);

   function Is_Awaiting_Reply (TCB : Thread_Control_Block) return Boolean;

   --  Reply-cap generation tag (m75): bumped every time this
   --  thread's slot is reallocated (Kernel.Processes keeps the
   --  per-slot counter OUTSIDE the TCB because Initialize_Thread
   --  overwrites the whole record). Mint_Reply_Cap stamps it into
   --  the reply cap's badge; Reply and Fail_Reply_Target refuse a
   --  cap whose badge is stale, so a reply cap left dangling by a
   --  dead caller can never cross-deliver to the thread that later
   --  reuses the slot (the TCB-address ABA).
   procedure Set_Reply_Generation
     (TCB        : in out Thread_Control_Block;
      Generation : Kernel.Capabilities.U64);

   function Reply_Generation
     (TCB : Thread_Control_Block) return Kernel.Capabilities.U64;

   --  Plain-send bookkeeping (milestone 35): set at Call (True) /
   --  Send (False) before queueing; the receiver reads it to decide
   --  whether to mint a reply cap and leave the caller parked, or
   --  to wake the sender with Ok immediately on delivery.
   procedure Set_Reply_Wanted
     (TCB    : in out Thread_Control_Block;
      Wanted : Boolean);

   function Is_Reply_Wanted (TCB : Thread_Control_Block) return Boolean;

   --  Endpoint blocked-caller queue link (FIFO per endpoint).
   procedure Set_Endpoint_Queue_Next
     (TCB    : in out Thread_Control_Block;
      Next   : Thread_Access);

   function Endpoint_Queue_Next
     (TCB : Thread_Control_Block) return Thread_Access;

   --  Badge of the endpoint cap a queued caller called through;
   --  recorded at Call time, consumed when the message transfers.
   procedure Set_IPC_Badge
     (TCB   : in out Thread_Control_Block;
      Badge : Kernel.Capabilities.U64);

   function IPC_Badge
     (TCB : Thread_Control_Block) return Kernel.Capabilities.U64;

   procedure Set_User_Thread_Cap
     (TCB : in out Thread_Control_Block;
      Cap : Kernel.Capabilities.Handle);

   function User_Thread_Cap
     (TCB : Thread_Control_Block) return Kernel.Capabilities.Handle;

   --  Per-thread debug_putchar line buffer (line-atomic debug
   --  output: bytes accumulate per thread, the trap handler flushes
   --  to the UART only on newline or a full buffer, so concurrent
   --  threads' debug lines never interleave).
   Debug_Line_Max : constant := 128;

   --  Append one byte; Flush is True when the caller must take and
   --  emit the line (newline appended, or the buffer is full).
   procedure Append_Debug_Char
     (TCB   : in out Thread_Control_Block;
      Char  : Character;
      Flush : out Boolean);

   --  Copy the pending line out and reset the buffer.
   procedure Take_Debug_Line
     (TCB  : in out Thread_Control_Block;
      Line : out String;
      Len  : out Natural);

   --  Thread-bound notification (seL4-style): at most one
   --  notification object is bound to a thread; IPC_Recv checks it
   --  before blocking and IRQ-driven signals can wake a receiver
   --  blocked on an endpoint with a synthetic message.
   procedure Set_Bound_Ntfn
     (TCB   : in out Thread_Control_Block;
      Ntfn  : System.Address);

   function Bound_Ntfn (TCB : Thread_Control_Block) return System.Address;

   --  Endpoint object a Blocked_Receive thread is waiting on,
   --  recorded so a notification signal can cancel the wait.
   procedure Set_Recv_Endpoint
     (TCB      : in out Thread_Control_Block;
      Endpoint : System.Address);

   function Recv_Endpoint
     (TCB : Thread_Control_Block) return System.Address;

   --  Thread wait list: threads blocked in Thread_Wait on this thread.
   --  Waiters_Next chains waiters; Waiters_Head is the first waiter.
   --  Waiting_For points from a waiter back to the target thread.
   procedure Set_Waiting_For
     (TCB    : in out Thread_Control_Block;
      Target : Thread_Access);

   function Waiting_For
     (TCB : Thread_Control_Block) return Thread_Access;

   procedure Set_Waiters_Head
     (TCB    : in out Thread_Control_Block;
      Waiter : Thread_Access);

   function Waiters_Head
     (TCB : Thread_Control_Block) return Thread_Access;

   procedure Set_Waiters_Next
     (TCB  : in out Thread_Control_Block;
      Next : Thread_Access);

   function Waiters_Next
     (TCB : Thread_Control_Block) return Thread_Access;

   --  Overwrite the saved a0 of a blocked thread with a syscall
   --  result status (surfaces when the thread is rescheduled).
   procedure Set_Saved_Result
     (TCB   : in out Thread_Control_Block;
      Value : Kernel.Capabilities.U64);

   --  Overwrite the saved a1 of a blocked thread (milestone 47:
   --  the reply-cap handle delivered to a woken receiver).
   procedure Set_Saved_A1
     (TCB   : in out Thread_Control_Block;
      Value : Kernel.Capabilities.U64);

   procedure Insert_Cap
     (TCB    : in out Thread_Control_Block;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status;
      Cap    : out Kernel.Capabilities.Handle);

   procedure Insert_Process_Cap
     (PCB    : in out Process_Control_Block;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status;
      Cap    : out Kernel.Capabilities.Handle);

   procedure Insert_Cap_At
     (TCB    : in out Thread_Control_Block;
      Cap    : Kernel.Capabilities.Handle;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status);

   procedure Insert_Process_Cap_At
     (PCB    : in out Process_Control_Block;
      Cap    : Kernel.Capabilities.Handle;
      Kind   : Kernel.Capabilities.Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : Kernel.Capabilities.U64;
      Result : out Kernel.Capabilities.Status);

   procedure Lookup_Cap
     (TCB       : Thread_Control_Block;
      Cap       : Kernel.Capabilities.Handle;
      Result    : out Kernel.Capabilities.Status;
      Out_Entry : out Kernel.Capabilities.Cap_Entry);

   procedure Lookup_Process_Cap
     (PCB       : Process_Control_Block;
      Cap       : Kernel.Capabilities.Handle;
      Result    : out Kernel.Capabilities.Status;
      Out_Entry : out Kernel.Capabilities.Cap_Entry);

   --  Thread_Dying must be True only when closing caps as part of
   --  the thread's own teardown (see Cleanup_Thread_Cap_Object).
   procedure Close_Cap
     (Thread       : not null Thread_Access;
      Cap          : Kernel.Capabilities.Handle;
      Result       : out Kernel.Capabilities.Status;
      Thread_Dying : Boolean := False);

   --  Raw close with no cleanup hooks: table entry only. Used by the
   --  IPC reply path to consume a reply cap whose target was already
   --  satisfied (cleanup would wrongly fail the caller).
   procedure Forget_Cap
     (Thread : not null Thread_Access;
      Cap    : Kernel.Capabilities.Handle;
      Result : out Kernel.Capabilities.Status);

   procedure Reset_Process_Caps (PCB : in out Process_Control_Block);

   function Process_Cap_Count (PCB : Process_Control_Block) return Natural;

private
   type Process_Control_Block is record
      Identifier : Process_Id;
      Spawner    : Process_Id;
      Root       : Kernel.Capabilities.U64;
      Caps       : Kernel.Capabilities.Cap_Table;
      Status     : Process_State;
      Exit_Code  : Kernel.Capabilities.U64;
   end record;

   type Thread_Control_Block is record
      Identifier      : Thread_Id;
      User_Thread_Cap : Kernel.Capabilities.Handle :=
        Kernel.Capabilities.Invalid_Handle;
      Status     : Thread_State;
      Process          : Process_Access;
      Kernel_Stack_Top : Kernel.Capabilities.U64;
      IPC_Buffer       : Kernel.Capabilities.U64;
      IPC_Buffer_User_VA : Kernel.Capabilities.U64;
      Awaiting_Reply   : Boolean;
      Reply_Generation : Kernel.Capabilities.U64;
      Reply_Wanted     : Boolean;
      Queue_Next       : Thread_Access;
      Call_Badge       : Kernel.Capabilities.U64;
      Context          : Arch.Context.Thread_Context;
      Queued           : Boolean;
      Boosted          : Boolean;
      Priority         : Thread_Priority;
      Sleep_Deadline   : Kernel.Capabilities.U64;
      Bound_Ntfn       : System.Address;
      Recv_EP          : System.Address;
      Queued_On_EP     : System.Address;
      Waiting_For      : Thread_Access;
      Waiters_Head     : Thread_Access;
      Waiters_Next     : Thread_Access;
      Debug_Line       : String (1 .. Debug_Line_Max);
      Debug_Len        : Natural;
   end record;
end Kernel.Tasks;
