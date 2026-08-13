with Interfaces;
with System;
with Kernel.Capabilities;
with Kernel.Objects;

--  Memory objects (docs/IPC.md "Memory objects (bulk/DMA)"): a
--  capability-ownable bundle of PMM frames. Userspace allocates an
--  object (mem_alloc), maps its frames into an address space
--  (mem_map, borrowed mappings: frames stay owned by the object),
--  and shares derived caps over IPC or spawn grants for bulk data /
--  future DMA. Refcounted: frames return to the PMM when the last
--  cap closes.

package Kernel.Memory is
   subtype U64 is Interfaces.Unsigned_64;
   subtype U32 is Interfaces.Unsigned_32;

   --  Pages per memory object (fixed upper bound; one object holds
   --  up to Max_Pages * 4096 bytes, bigger buffers use several
   --  objects).
   Max_Pages : constant := 256;
   --  Milestone 53a: full-runtime ELFs stage at 300+ KiB (the ZCX
   --  machinery), so 64 pages stopped fitting a one-object staging
   --  buffer; 256 pages = 1 MiB.

   --  DMA authorization backlink: how many distinct PCI device ids
   --  one object's frames may be IOMMU-mapped into at once
   --  (mem_object_pa records the mapping here so the finalizer can
   --  tear the IOVA=PA entries down before frames return to the
   --  PMM).
   Max_DMA_Devices : constant := 8;

   type Status is
     (Ok,
      No_Memory);

   --  Rights granted to the creator of a memory object.
   Memory_Full_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => True,
      Write    => True,
      Execute  => False,
      Map      => True,
      Send     => False,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => True,
      Manage   => True);

   --  Allocate a zeroed memory object of Pages frames from the
   --  kernel slab + PMM. On Ok the object has refcount 0; the caller
   --  inserts a cap (which retains it) or Discards it.
   procedure Create
     (Pages  : U64;
      Result : out Status;
      Object : out System.Address);

   --  Return an unreferenced (refcount 0) object to the slab and its
   --  frames to the PMM (create-then-fail rollback).
   procedure Discard (Object : System.Address);

   --  Refcount operations on a memory object address. Retain adds
   --  one reference; Release drops one and returns True when the
   --  last reference dropped (frames returned to the PMM, slot
   --  freed). Refcount convention matches Kernel.IPC: Count = number
   --  of caps referencing the object.
   procedure Retain (Object : System.Address);
   function Release (Object : System.Address) return Boolean;

   --  Object geometry for the mem_map syscall path.
   function Page_Count (Object : System.Address) return U64;

   --  Physical address of frame Index (0-based), 0 when out of
   --  range.
   function Frame_At
     (Object : System.Address;
      Index  : U64) return U64;

   --  Record that Object's frames were IOMMU-mapped for Device_Id
   --  (deduped). False when the per-object device list is full —
   --  the caller must roll back the mapping it just installed.
   function Note_DMA_Mapping
     (Object    : System.Address;
      Device_Id : U32) return Boolean;

private
   type Frame_Array is array (0 .. Max_Pages - 1) of U64;
   type DMA_Device_Array is
     array (0 .. Max_DMA_Devices - 1) of Interfaces.Unsigned_32;

   type Memory_Object is record
      Header    : Kernel.Objects.Object_Header;
      Pages     : U64;
      Frames    : Frame_Array;
      DMA_Devs  : DMA_Device_Array;
      DMA_Count : Natural;
      Next_Free : System.Address;
   end record;
end Kernel.Memory;
