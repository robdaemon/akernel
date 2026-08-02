with Interfaces;

package Kernel.Physical_Memory is
   subtype U64 is Interfaces.Unsigned_64;

   Page_Size : constant U64 := 4096;

   type Status is
     (Ok,
      Out_Of_Memory,
      Invalid_Range,
      Not_Initialized,
      Too_Many_Ranges);

   procedure Initialize
     (First_Free : U64;
      Last_Byte  : U64;
      Result     : out Status);

   --  Reserve a physical range against future allocation (initrd,
   --  DTB, firmware). Call after Initialize, before allocations
   --  reach the range. Bounds are rounded to whole pages; the bump
   --  allocator skips reserved pages, so they never enter the free
   --  list either. Up to Max_Reserved ranges.
   Max_Reserved : constant := 8;

   procedure Reserve
     (Base   : U64;
      Length : U64;
      Result : out Status);

   procedure Allocate_Frame
     (Result : out Status;
      Frame  : out U64);

   --  Bump-only contiguous run (never deallocated; SMP per-hart
   --  kernel stacks at boot).  Skips the free list so the run is
   --  guaranteed contiguous; fails when the bump region is exhausted.
   procedure Allocate_Contiguous
     (Pages       : Natural;
      Result      : out Status;
      First_Frame : out U64);

   procedure Deallocate_Frame
     (Frame  : U64;
      Result : out Status);

   function Mark return U64;

   procedure Rewind
     (To     : U64;
      Result : out Status);

   function Free_Bytes return U64;
   function Free_Frame_Count return U64;
   function Next_Free_Frame return U64;
   function Initialized return Boolean;
end Kernel.Physical_Memory;
