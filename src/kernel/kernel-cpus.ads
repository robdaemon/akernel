with Interfaces;

--  SMP topology and per-hart identity.
--
--  The kernel supports a variable number of harts up to Max_CPUs.
--  Only static metadata (a few dozen bytes per hart: scheduler slot
--  elsewhere, raw id, started flag, boot info block) is bounded by
--  the cap; per-hart kernel stacks are allocated from the PMM at
--  boot, so the cap carries no real memory commitment and can be
--  raised freely.  The boot hart discovers the topology from the
--  device tree (/cpus), configures this package, then starts the
--  secondary harts via SBI HSM.
--
--  Two hart namings coexist:
--  - CPU_Index: dense kernel-internal index 0 .. Count - 1; index 0
--    is always the boot hart.  Indexes the scheduler's current-slot
--    array and is what riscv_current_hart reports (hart slot at the
--    top of every kernel stack).
--  - raw hart id: the value the hardware/OpenSBI uses (a0 at boot,
--    HSM arguments, IPI hart masks); not necessarily contiguous.

package Kernel.CPUs is
   subtype U64 is Interfaces.Unsigned_64;

   --  Static ceiling: per-CPU state is fixed-size records wired
   --  into the scheduler and trap path at boot; the DTB reports
   --  the actual hart count (any QEMU -smp we boot is far below
   --  this), and exceeding it is a boot-time config error, not
   --  a runtime growth case.
   Max_CPUs : constant := 64;

   type CPU_Index is range 0 .. Max_CPUs - 1;

   type Raw_Id_Array is array (CPU_Index) of U64;

   --  Boot info block handed to a secondary hart through the SBI HSM
   --  opaque argument (its physical address).  secondary_boot reads
   --  it with the MMU off, so the stack fields are physical
   --  addresses.
   type Boot_Info is record
      Trap_Stack_Top : U64;   --  PA; the hart slot lives at top - 8
      Index          : U64;   --  this hart's CPU_Index
      Main_Stack_Top : U64;   --  PA
   end record
     with Pack;

   --  Secondary-hart kernel stack sizes in PMM pages (16 KiB trap
   --  stack: idle trap handling is shallow; 8 KiB main stack: the
   --  scheduler-or-idle loop is shallow too).
   Trap_Stack_Pages : constant := 4;
   Main_Stack_Pages : constant := 2;

   --  Register the discovered topology.  Raw_Ids (0) must be the
   --  boot hart's raw id.  Count is the number of usable harts
   --  (1 .. Max_CPUs).
   procedure Configure (Raw_Ids : Raw_Id_Array; Count : Natural);

   --  Number of configured harts (>= 1).
   function Count return Natural;

   --  This hart's index, from the hart slot at the top of the
   --  current kernel stack (sscratch invariant).
   function Current return CPU_Index;

   function Raw_Id (CPU : CPU_Index) return U64;

   --  Physical address of a hart's boot info block, passed as the
   --  HSM opaque argument.
   function Info_Block_PA (CPU : CPU_Index) return U64;

   --  Record the PMM-allocated stack tops (physical addresses) for a
   --  secondary hart before it is started.  Also called for the
   --  boot hart (index 0) with the boot stack symbols so the idle
   --  path can leave a blocked thread's kernel stack.
   procedure Set_Stacks
     (CPU       : CPU_Index;
      Trap_Top  : U64;
      Main_Top  : U64);

   --  Per-hart idle stack tops as kernel virtual addresses.  A hart
   --  that finds no runnable thread switches to these before
   --  sleeping: a blocked thread's kernel stack must not host the
   --  idle wfi, because another hart can resume that thread and the
   --  thread's next trap would clobber the sleeping hart's frames.
   function Idle_Trap_Stack_Top (CPU : CPU_Index) return U64;
   function Idle_Main_Stack_Top (CPU : CPU_Index) return U64;

   --  A secondary hart marks itself started once it can take work.
   procedure Mark_Started (CPU : CPU_Index);

   --  IPI every started hart except the current one.  Called when
   --  the ready queue goes empty -> nonempty so idle harts leave
   --  their wfi and reschedule.
   procedure Notify_Work;

end Kernel.CPUs;
