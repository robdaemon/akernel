with Interfaces;
with System;
with System.Storage_Elements;

package Akernel_User.Syscalls is
   subtype U64 is Interfaces.Unsigned_64;

   procedure Yield;
   Address_Space_Cap : constant U64 := 255;

   function Map_MMIO
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Flags         : U64) return U64;
   UART_MMIO_Grant_Bit : constant U64 := 1;
   UART_IRQ_Grant_Bit  : constant U64 := 2;
   Syscall_Failed      : constant U64 := U64'Last;
   Boot_EOF            : constant U64 := 256;

   --  Rights-mask bits for spawn grant lists (kernel encoding:
   --  Read = bit 0 .. Manage = bit 9).
   Right_Read     : constant U64 := 1;
   Right_Write    : constant U64 := 2;
   Right_Execute  : constant U64 := 4;
   Right_Map      : constant U64 := 8;
   Right_Send     : constant U64 := 16;
   Right_Receive  : constant U64 := 32;
   Right_Wait     : constant U64 := 64;
   Right_Ack      : constant U64 := 128;
   Right_Transfer : constant U64 := 256;
   Right_Manage   : constant U64 := 512;

   Spawn_Ok               : constant U64 := 0;
   Spawn_Invalid_Program  : constant U64 := 1;
   Spawn_No_Slot          : constant U64 := 2;
   Spawn_Load_Failed      : constant U64 := 3;
   Spawn_Cap_Failed       : constant U64 := 4;
   Spawn_Scheduler_Failed : constant U64 := 5;
   Spawn_Invalid_Parent   : constant U64 := 6;

   function IRQ_Wait (Cap : U64) return U64;
   function IRQ_Ack (Cap : U64) return U64;
   --  Spawn ABI v2: Image_Cap is a Boot_File_Object cap (Read +
   --  Execute rights); grant entries are in the IPC buffer.
   function Spawn
     (Image_Cap   : U64;
      Grant_Count : U64;
      Process_Cap : out U64) return U64;
   --  Cap-based boot byte API: Cap must be a Boot_File_Object cap
   --  with the Read right.
   function Boot_File_Size (Cap : U64) return U64;
   function Boot_Read_Byte
     (Cap     : U64;
      Offset  : U64) return U64;
   --  Exit status (milestone 40b): a0 of the exit syscall rides
   --  into the PCB; the reaper reads it back as a1 of reap
   --  (Amiga RC conventions live in Akernel_User.CLI).
   procedure Process_Exit (Code : U64 := 0);
   function Reap_Process (Process_Cap : U64) return U64;
   function Reap_Process_Code
     (Process_Cap : U64;
      Code        : out U64) return U64;
   function EP_Create return U64;

   --  Memory objects (PMM-backed frame bundles, refcounted).
   --  Mem_Alloc returns a cap handle (Map+Read+Write+Transfer+
   --  Manage) or Syscall_Failed. Mem_Map/Mem_Unmap map the object's
   --  frames as borrowed user pages (frames stay object-owned);
   --  Flags bit 0 = read, bit 1 = write (write implies read).
   --  Return 0 on success, 1 on failure.
   function Mem_Alloc (Pages : U64) return U64;
   function Mem_Map
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Flags         : U64) return U64;
   function Mem_Unmap
     (Address_Space : U64;
      VA            : U64;
      Length        : U64) return U64;

   --  Notification objects (docs/IPC.md): a word of pending signal
   --  bits with an optional bound thread. Ntfn_Create returns a cap
   --  handle (Wait+Write+Transfer+Manage) or Syscall_Failed. Ntfn_Wait
   --  blocks until bits are pending and returns them (consumed),
   --  Syscall_Failed on a bad cap. A thread binds one notification
   --  to itself (Ntfn_Bind_Thread, Manage right); IPC_Recv then
   --  checks it before blocking and signals can wake a blocked
   --  receiver with a synthetic message (Label = Notification_Label,
   --  word 0 = bits). IRQ_Bind_Ntfn makes an IRQ line signal the
   --  notification with Badge when it fires (IRQ cap Ack right,
   --  notification Write right).
   Notification_Label : constant U64 := U64'Last;

   function Ntfn_Create return U64;
   function Ntfn_Wait (Cap : U64) return U64;
   function Ntfn_Signal (Cap : U64; Bits : U64) return U64;
   function Ntfn_Bind_Thread (Cap : U64) return U64;
   function IRQ_Bind_Ntfn
     (IRQ_Cap  : U64;
      Ntfn_Cap : U64;
      Badge    : U64) return U64;

   --  Device plumbing (init holds the "device_resource" Kernel_Object
   --  cap with Manage; every other caller is refused). IO_Map
   --  (syscall 23) creates an MMIO_Object cap over the physical range
   --  [Base, Base + Length) — page-aligned, at most 64 pages — and
   --  returns its handle (Map+Read+Write+Transfer+Manage) or
   --  Syscall_Failed. IRQ_Create (syscall 24) registers and
   --  PLIC-enables an interrupt source and returns an IRQ_Object cap
   --  handle (Wait+Ack+Transfer+Manage) or Syscall_Failed
   --  (already-registered sources fail). IO_Map's Device_Id
   --  attributes the region to a PCI requester id (bus/dev/func);
   --  with the IOMMU online, mem_object_pa exposes DMA frames only
   --  to devices the caller holds an attributed MMIO cap for.
   --  Mem_Object_PA (syscall 25)
   --  returns the physical address of frame Index of a memory object
   --  (Manage right), 0 on bad cap or out of range — DMA drivers
   --  program devices with these addresses.
   function IO_Map
     (Resource  : U64;
      Base      : U64;
      Length    : U64;
      Device_Id : U64 := U64'Last) return U64;
   function IRQ_Create (Resource : U64; Source : U64) return U64;
   --  IRQ_MSI_Create (syscall 42): allocate a virtual MSI/MSI-X
   --  vector for the PCI requester id Device_Id.  On success returns
   --  the IRQ cap handle and, via Address and Data, the values the
   --  caller must write into the PCI MSI/MSI-X table entry.
   function IRQ_MSI_Create
     (Resource    : U64;
      Device_Id   : U64;
      Vector      : U64;
      Address     : out U64;
      Data        : out U64) return U64;
   function Mem_Object_PA (Cap : U64; Index : U64) return U64;

   --  Cap_Delete (syscall 26) closes one of the caller's own
   --  cap-table slots, running the same per-kind cleanup the exit
   --  path runs (object release, endpoint/IRQ/notification hooks).
   --  Servers that receive transferred caps per request must
   --  delete them after use or leak a table slot per transfer.
   --  Returns 0 on success, Syscall_Failed on an invalid or
   --  unopened handle.
   function Cap_Delete (Cap : U64) return U64;

   --  CPU_Count (syscall 27) returns the number of online harts.
   --  First kernel-introspection syscall; lets programs adapt to
   --  UP vs SMP (Tests/Spin skips itself on UP).
   function CPU_Count return U64;

   --  Cap_Mint (syscall 28) derives a cap in the caller's own
   --  table with attenuated rights (subset of the source's) and a
   --  badge. Same validation as spawn grant lists. The badge rides
   --  the endpoint when the holder calls it (session-manager
   --  pattern: e.g. init mints partN-badged partition-service
   --  caps). Returns the new handle or Syscall_Failed.
   function Cap_Mint (Source : U64; Rights_Mask : U64; Badge : U64)
                      return U64;

   --  Process_Info (syscall 30): kernel introspection snapshot of
   --  one process, written as a 64-byte record into a caller-owned
   --  memory object (Write right; Offset 8-aligned with the record
   --  fully inside the object). Authority: Resource must be the
   --  device_resource Kernel_Object cap with Manage — the same cap
   --  that gates io_map/irq_create, granted down from init.
   --  Slot names a process-table slot 0..127; Self_Slot names the
   --  calling thread's own process (also covers kernel-started
   --  processes, which have no table slot). Returns Info_Ok,
   --  Info_Not_Found (unused or out-of-range slot — enumeration
   --  end), or Syscall_Failed (authority/cap/offset rejected).
   --  Record layout (words, U64): 0 process id; 1 spawner process
   --  id (0 = kernel-started, stable after the spawner exits);
   --  2 lifecycle (0 initializing, 1 alive, 2 dead); 3 thread
   --  state (0 ready, 1 running, 2 blocked-send, 3 blocked-recv,
   --  4 blocked-irq, 5 blocked-notification, 6 blocked-sleeping,
   --  7 blocked-thread-wait, 8 dead); 4 open cap
   --  count; 5 flags (bit0 awaiting reply, bit1 reply wanted,
   --  bit2 wakeup-boosted, bit3 ready-queued); 6 receive endpoint
   --  object address (0 = none); 7 badge of the last Call;
   --  8 scheduling priority, sign-extended (-128..127; m62).
   Process_Info_Word_Count : constant := 9;
   type Process_Info_Words is
     array (0 .. Process_Info_Word_Count - 1) of U64;
   --  Spawn-table size — mirror of the kernel's
   --  Max_Process_Slots (enumeration walks slots
   --  0 .. Process_Table_Slots - 1; no-slot answers mean
   --  skip / end, Op_ReadDir idiom).
   Process_Table_Slots : constant := 128;
   Self_Slot      : constant U64 := U64'Last;
   Info_Ok        : constant U64 := 0;
   Info_Not_Found : constant U64 := 1;
   function Process_Info
     (Resource : U64;
      Slot     : U64;
      Buffer   : U64;
      Offset   : U64 := 0) return U64;

   --  Set_Priority (syscall 35, milestone 62): Amiga SetTaskPri
   --  with capability discipline. Target = Priority_Self for the
   --  calling thread, else a Process_Object cap WITH the Manage
   --  right (the spawn/reap cap a parent holds over a child).
   --  New_Priority is clamped into -128 .. 127 (Amiga task
   --  priority range); the scheduler always runs the highest-
   --  priority ready thread and a priority-crossing wake preempts
   --  immediately. Returns 0 (Old_Priority = the previous value)
   --  or 1 (bad handle / wrong kind / no Manage / dead slot).
   Priority_Self : constant U64 := U64'Last;
   function Set_Priority
     (Target       : U64;
      New_Priority : Integer;
      Old_Priority : out Integer) return U64;

   --  Endpoint identity stamp (milestone 41b/Proc:self): when
   --  Stamp is True, calls through this endpoint with a zero badge
   --  surface the caller's process id as Message.Badge.  The file
   --  server uses this to learn the real client identity without
   --  requiring every client to hold a per-process capability.
   function EP_Set_Stamp_Identity (Cap : U64; Stamp : Boolean)
                                   return U64;

   --  Threading primitives (Milestone 66).
   --  Thread_Create: caller fills Thread_Create_Params and writes it
   --  to the IPC buffer with Thread_Create_Write_Params; then calls
   --  Thread_Create. Returns the new thread cap handle or Syscall_Failed.
   type Thread_Create_Params is record
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

   procedure Thread_Create_Write_Params (Params : Thread_Create_Params);
   function Thread_Create return U64;
   procedure Thread_Exit;
   function Thread_Self return U64;
   --  Thread_Wait (syscall 40): block until the thread whose cap
   --  handle is Cap has exited. Returns 0 on success, 1 on error.
   function Thread_Wait (Cap : U64) return U64;

   --  Sleep_Until (syscall 39): blocks the calling thread until the
   --  riscv time CSR reaches Deadline (mtime ticks, i.e. the same
   --  units as Read_Time). Returns 0 on normal wakeup, 1 on failure.
   function Read_Time return U64;
   function Sleep_Until (Deadline : U64) return U64;

   --  Secondary-thread entry trampoline.  Pass its address as the
   --  Thread_Create entry PC and the real worker function address as
   --  the argument; the trampoline sets gp and then calls the worker.
   procedure Thread_Entry_Trampoline
     with Import, Convention => C, External_Name => "akernel_thread_entry";
   function Thread_Entry_Point return U64;

   --  Cap_Info (syscall 31): one cap-table slot of a process,
   --  64-byte record into a caller-owned memory object. Authority:
   --  Admin must be the admin Admin_Object cap with Manage
   --  (bootinfo "admin", manifest token — capability possession is
   --  the identity; the kernel has no user model). Slot names a
   --  process-table slot 0..127 or Self_Slot; Cap_Index walks the
   --  16384-handle space sparsely. Returns Info_Ok,
   --  Info_Not_Found (no process slot / empty cap slot),
   --  Syscall_Failed (authority/cap/offset rejected).
   --  Record layout (words, U64): 0 handle; 1 object-kind position
   --  (0 null, 1 frame, 2 address-space, 3 process, 4 thread,
   --  5 endpoint, 6 reply, 7 irq, 8 mmio, 9 dma, 10 kernel-object,
   --  11 boot-file, 12 memory-object, 13 notification, 14 admin);
   --  2 rights mask (Right_* encoding); 3 object address;
   --  4 badge; 5 valid (1); 6..7 zero.
   Cap_Info_Word_Count : constant := 8;
   type Cap_Info_Words is
     array (0 .. Cap_Info_Word_Count - 1) of U64;
   function Cap_Info
     (Admin     : U64;
      Slot      : U64;
      Cap_Index : U64;
      Buffer    : U64;
      Offset    : U64 := 0) return U64;

   --  Thread_Regs (syscall 32): saved trap-frame snapshot of a
   --  process's thread, 320-byte record into a caller-owned memory
   --  object. Same admin authority as Cap_Info. BLOCKED threads
   --  only: a ready/running thread has no stable frame — returns
   --  Info_Busy (no cross-hart stop-the-world by design). Returns
   --  Info_Ok, Info_Not_Found (no such slot), Info_Busy, or
   --  Syscall_Failed.
   --  Record layout (words, U64): 0..30 = x1..x31 (word 1 = sp,
   --  word 9 = a0); 31 sepc; 32 satp; 33 thread-state position
   --  (Process_Info encoding); 34 process id; 35..39 zero.
   Thread_Regs_Word_Count : constant := 40;
   type Thread_Regs_Words is
     array (0 .. Thread_Regs_Word_Count - 1) of U64;
   Info_Busy : constant U64 := 2;
   function Thread_Regs
     (Admin  : U64;
      Slot   : U64;
      Buffer : U64;
      Offset : U64 := 0) return U64;

   --  System_Reset (syscall 33): SBI SRST machine shutdown or
   --  reboot — the clean-shutdown path (milestone 50). Same
   --  admin authority as Cap_Info; the only callers are
   --  System/Shutdown + System/Reboot through the Elevated
   --  mint. On success the machine goes down and the call never
   --  returns; a nonzero return is the SBI error code,
   --  Syscall_Failed on rejection (authority or reset type).
   Reset_Shutdown    : constant U64 := 0;
   Reset_Cold_Reboot : constant U64 := 1;
   Reset_Warm_Reboot : constant U64 := 2;
   function System_Reset
     (Admin      : U64;
      Reset_Type : U64) return U64;

   --  Read_Clock (syscall 34): wall clock from the board RTC
   --  (goldfish on qemu virt; milestone 59). Seconds/Nanos since
   --  the Unix epoch; both 0 when the board has no ticking RTC.
   --  Ungated — read-only and harmless to every process.
   procedure Read_Clock (Seconds : out U64; Nanos : out U64);

   --  Boot files as memory objects: maps a Boot_File_Object cap's
   --  frames read-only and borrowed. File data need not start on a
   --  page boundary; Lead_In returns the byte offset of the file
   --  start (plus Offset) within the first mapped page.
   function Mem_Map_File
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Lead_In       : out U64) return U64;

   Mem_Max_Pages : constant U64 := 64;
   Page_Size     : constant U64 := 4096;
   function IPC_Call (Cap : U64) return U64;
   --  Milestone 47: a received call mints its reply cap in an
   --  ordinary free slot and the handle surfaces in a1 ->
   --  Reply_Handle (0 = none: plain send or the synthetic
   --  notification message). A server may hold many outstanding
   --  reply caps and reply in any order.
   function IPC_Recv (Cap : U64; Reply_Handle : out U64) return U64;
   --  Plain send (milestone 35): rendezvous ends at delivery — the
   --  sender blocks only until a Receive takes the message; no
   --  reply cap is minted, so the receiver cannot reply.
   function IPC_Send (Cap : U64) return U64;
   --  Cap = the Reply_Handle an earlier IPC_Recv returned.
   function IPC_Reply (Cap : U64) return U64;

   IPC_Buffer_VA    : constant U64 := 16#6FFF_0000#;

   --  Argument passing (milestone 33a): a spawner MAY hand the
   --  child a one-page memory object at handle 4 holding a
   --  NUL-terminated argument string (the Amiga command-line
   --  analog). Absent handle = no args. The child Mem_Maps it
   --  read-only at Args_VA (0x4800_0000 — ABOVE the 0x4600_0000
   --  link base + image; the first choice 0x4600_0000 collided
   --  with the program's own .text, milestone-33a burn).
   Args_Handle : constant U64 := 4;
   Args_VA     : constant U64 := 16#4800_0000#;

   --  Redirection trailer (milestone 46b): a spawner that
   --  redirects the child's output/input writes a 64-byte
   --  trailer at Args_Trailer_Offset: magic u64, then the page
   --  offsets of two NUL-terminated paths (0 = none) —
   --  [magic][out_off][in_off][reserved]. Pages without the
   --  magic mean "no redirection" (old spawners need no
   --  change). The RTS wires out_path into Console (Put
   --  appends via fs Writes; pipes ignore offsets) and
   --  in_path into CLI.Get_Line.
   Args_Trailer_Offset : constant U64 := 4032;
   Args_Trailer_Magic  : constant U64 := 16#3152_4944_4552_4B41#;
   --  "AKREDIR1" little-endian

   --  Map the args page once (idempotent); Mapped is False
   --  when no page was granted. Callers MUST gate any
   --  Args_VA overlay on Mapped — reading an unmapped page
   --  faults.
   procedure Map_Args (Mapped : out Boolean);

   --  Copy the argument string into S (Len = its length, 0 when
   --  no args page was granted). The page stays mapped.
   procedure Read_Args (S : out String; Len : out Natural);
   IPC_Ok              : constant U64 := 0;
   IPC_Invalid         : constant U64 := 1;
   IPC_Transfer_Failed : constant U64 := 2;
   IPC_Endpoint_Gone   : constant U64 := 3;
   IPC_Reply_Gone      : constant U64 := 4;

   --  96-byte IPC message in this thread's buffer page.
   type IPC_Word_Array is array (0 .. 5) of U64;
   type IPC_Cap_Array is array (0 .. 3) of U64;
   type IPC_Message is record
      Label : U64;
      Words : IPC_Word_Array;
      Caps  : IPC_Cap_Array;
      Badge : U64;
   end record;

   Message : IPC_Message
     with Volatile, Address =>
       System'To_Address (System.Storage_Elements.Integer_Address
         (IPC_Buffer_VA));

   --  Spawn grant list: up to Max_Grants entries of (source handle,
   --  rights mask, badge) written into this thread's buffer page at
   --  Grant_List_Offset before calling Spawn_Boot_Path. The child
   --  receives the caps at handles 1..Grant_Count in list order.
   Grant_List_Offset : constant U64 := 128;
   Max_Grants        : constant U64 := 32;
   procedure Set_Grant
     (Index       : U64;
      Source_Cap  : U64;
      Rights_Mask : U64;
      Badge       : U64);

   --  Bootinfo region (init only): read-only kernel-written table
   --  of (handle, kind, rights mask, name) entries for every cap
   --  the kernel handed init at boot. Kind values match the kernel
   --  Object_Kind enumeration positions. Up to 8 pages mapped
   --  contiguously by the kernel as entries grow (one page was
   --  silently full at 63 entries — milestone 38b burn); the
   --  overlay spans the maximum so Count-bounded walks just work.
   Bootinfo_VA    : constant U64 := 16#6FFE_0000#;
   Bootinfo_Magic : constant U64 := 16#4B41_494E_464F_3031#;

   Kind_IRQ       : constant U64 := 7;
   Kind_MMIO      : constant U64 := 8;
   Kind_Boot_File : constant U64 := 11;
   Kind_Memory    : constant U64 := 12;

   Bootinfo_Max_Name : constant := 32;
   type Bootinfo_Name is array (1 .. Bootinfo_Max_Name) of Character;

   type Bootinfo_Entry is record
      Handle      : U64;
      Kind        : U64;
      Rights_Mask : U64;
      Name_Length : U64;
      Name        : Bootinfo_Name;
   end record;

   type Bootinfo_Entry_Array is array (0 .. 510) of Bootinfo_Entry;

   type Bootinfo_Page is record
      Magic   : U64;
      Count   : U64;
      Entries : Bootinfo_Entry_Array;
   end record;

   Bootinfo : Bootinfo_Page
     with Volatile, Address =>
       System'To_Address (System.Storage_Elements.Integer_Address
         (Bootinfo_VA));

   --  Bootinfo name lookup (init's namespace basis): resolve a
   --  kernel-assigned entry name (e.g. "System/Manifest", "dtb")
   --  to its cap handle; 0 when absent or bootinfo page invalid.
   function Boot_Cap (Name : String) return U64;

   --  Rights mask of the named entry as granted by the kernel;
   --  0 when absent. Children can be granted at most these rights.
   function Boot_Cap_Rights (Name : String) return U64;

   procedure Debug_Put (S : String);
   procedure Debug_Put_Line (S : String);
end Akernel_User.Syscalls;
