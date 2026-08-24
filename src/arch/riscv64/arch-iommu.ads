with Interfaces;

--  RISC-V IOMMU (riscv-iommu spec 1.0, memory-mapped register
--  variant) kernel driver: DMA isolation for PCI devices on qemu
--  virt (-machine iommu-sys=on; the pci host node's iommu-map
--  routes all PCI requester ids here, virtio-mmio is NOT covered).
--
--  Model: 3-level device directory table, one device context per
--  PCI requester id (bus 0 devfn), first-stage Sv39 IO page table
--  per device with IOVA = PA identity mappings — isolation comes
--  from mapping ONLY the memory-object frames userspace explicitly
--  exposed for DMA (mem_object_pa is the authorization point,
--  see arch-traps Handle_Mem_Object_PA); every other device access
--  faults into the fault queue, which the wired PLIC interrupt
--  drains and logs. MSI translation stays off (drivers use INTx).
--
--  Encodings follow the spec (chapter 5 registers, chapter 2 data
--  structures, chapter 3 command/fault queues), cross-checked
--  against Linux drivers/iommu/riscv/bits.h.
--
--  When Caps_MSI_Flat is set, the IOMMU is also used as a software
--  MSI controller: MSI/MSI-X writes are detected by address pattern,
--  forced to fault on an invalid flat MSI page table, and converted
--  into virtual kernel IRQ source deliveries by the fault handler.
--  This is a qemu-virt-specific stop-gap until AIA/APLIC/IMSIC is
--  available.

package Arch.IOMMU is
   subtype U64 is Interfaces.Unsigned_64;
   subtype U32 is Interfaces.Unsigned_32;

   No_Device : constant U32 := 16#FF_FFFF#;

   --  Probe the DTB for a "riscv,iommu" node; when present set up
   --  the queues, an empty translating DDT (3LVL) and the fault
   --  interrupt, and mark the driver available. When the node is
   --  absent the system runs without DMA isolation (mem_object_pa
   --  behaves as before) and Available stays False.
   procedure Initialize (DTB : U64);

   function Available return Boolean;

   --  True when the IOMMU supports the flat-MSI page-table format and
   --  the kernel allocated the shared (invalid) MSI page table.  When
   --  False, callers must fall back to INTx-style wired interrupts.
   function MSI_Available return Boolean;

   --  Create the device context for Device_Id on first use and map
   --  Frame_PA (IOVA = Frame_PA, R+W) into its IO page table,
   --  IOTLB-invalidated and fenced before return.
   procedure Map_DMA (Device_Id : U32; Frame_PA : U64);

   --  Drop the IOVA = Frame_PA mapping from the device's IO table
   --  (no-op when the device or mapping does not exist).
   procedure Unmap_DMA (Device_Id : U32; Frame_PA : U64);

   --  Allocate a virtual MSI vector for Device_Id.  On success the
   --  kernel reserves a virtual IRQ source, configures the IOMMU to
   --  trap MSI writes from this device, and returns the Address/Data
   --  the caller must program into the PCI MSI/MSI-X table entry.
   --  Returns False if the IOMMU has no MSI support or allocation
   --  fails.
   function MSI_Vector_Create
     (Device_Id : U32;
      Vector    : Natural;
      Source    : out U64;
      Address   : out U64;
      Data      : out U32) return Boolean;

   --  PLIC-wired fault-queue interrupt (vector 0): drain and log
   --  fault records, clear ipsr, and deliver software MSI vectors.
   procedure Handle_Fault_Interrupt;
end Arch.IOMMU;
