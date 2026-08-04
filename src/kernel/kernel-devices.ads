with Interfaces;
with System;
with Kernel.Objects;

--  Dynamic device objects: MMIO regions and IRQ lines created at
--  runtime (io_map / irq_create syscalls, plus the boot UART
--  devices). PMM-backed slab, frames never returned (same policy as
--  the endpoint and memory-object slabs). Caps (MMIO_Object /
--  IRQ_Object kinds) hold references; the slot returns to the pool
--  when the last cap closes.

package Kernel.Devices is
   subtype U64 is Interfaces.Unsigned_64;
   subtype U32 is Interfaces.Unsigned_32;

   --  PCI requester id (bus/dev/func) an MMIO region belongs to, or
   --  No_Device when the region carries no DMA identity (platform
   --  MMIO, probe windows). The IOMMU authorization hook in
   --  mem_object_pa maps DMA frames for every device id the calling
   --  thread holds an MMIO cap for.
   No_Device : constant U32 := 16#FF_FFFF#;

   type Status is
     (Ok,
      No_Memory,
      Invalid_Object);

   procedure Create_MMIO
     (Base      : U64;
      Length    : U64;
      Device_Id : U32 := No_Device;
      Result    : out Status;
      Object    : out System.Address);

   --  The line starts unregistered; the caller passes Line_Of to
   --  Kernel.Interrupts.Register (and enables the PLIC source).
   procedure Create_IRQ
     (Source : U64;
      Result : out Status;
      Object : out System.Address);

   --  Views of a live object for syscall handlers and interrupt
   --  plumbing. Null when the object address is not a pool slot of
   --  the matching kind.
   function Region_Of
     (Object : System.Address) return access Kernel.Objects.MMIO_Region;
   function Line_Of
     (Object : System.Address) return Kernel.Objects.IRQ_Line_Access;

   --  PCI requester id of an MMIO slot, No_Device for IRQ slots /
   --  unattributed regions / invalid objects.
   function Device_Id_Of (Object : System.Address) return U32;

   --  Refcount operations (Retain_Cap / Cleanup_Thread_Cap_Object
   --  dispatch for the MMIO_Object and IRQ_Object cap kinds).
   procedure Retain (Object : System.Address);
   function Release (Object : System.Address) return Boolean;
end Kernel.Devices;
