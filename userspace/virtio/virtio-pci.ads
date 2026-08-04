--  Virtio PCI register-level operations (virtio 1.2 §4.1.4, modern
--  common-config structure; INTx interrupts, no MSI-X). Generic
--  over width-exact register access — the spec requires field-width
--  accesses on the common-config structure, so no 32-bit
--  read-modify-write tricks. The driver maps the per-region caps
--  (common/notify/ISR/device-cfg, all discovered by the device
--  manager from the PCI capability list) and instantiates with
--  overlays. Device-specific config (e.g. blk capacity) is read by
--  the driver from its own device-cfg region; this package covers
--  the transport only.

generic
   with function Common_Read8 (Offset : U64) return U8;
   with function Common_Read16 (Offset : U64) return U16;
   with function Common_Read32 (Offset : U64) return U32;
   with procedure Common_Write8 (Offset : U64; Value : U8);
   with procedure Common_Write16 (Offset : U64; Value : U16);
   with procedure Common_Write32 (Offset : U64; Value : U32);
   --  8-bit ISR register read, zero-extended; the read clears the
   --  register (deasserts INTx once the queue interrupt cause is
   --  consumed).
   with function ISR_Read return U32;
   --  16-bit write into the notify region. Notify_Offset is the
   --  raw queue_notify_off value; the driver multiplies it by the
   --  notify capability's notify_off_multiplier (a runtime value
   --  from the device manager's config message) to get the byte
   --  offset into its mapped notify region.
   with procedure Notify_Write (Notify_Offset : U64; Value : U16);
package Virtio.PCI is
   --  Common-config structure offsets.
   Cfg_Device_Feat_Sel   : constant U64 := 16#00#;
   Cfg_Device_Features   : constant U64 := 16#04#;
   Cfg_Driver_Feat_Sel   : constant U64 := 16#08#;
   Cfg_Driver_Features   : constant U64 := 16#0C#;
   Cfg_MSIX_Vector       : constant U64 := 16#10#;
   Cfg_Num_Queues        : constant U64 := 16#12#;
   Cfg_Device_Status     : constant U64 := 16#14#;
   Cfg_Config_Generation : constant U64 := 16#15#;
   Cfg_Queue_Sel         : constant U64 := 16#16#;
   Cfg_Queue_Size        : constant U64 := 16#18#;
   Cfg_Queue_MSIX_Vector : constant U64 := 16#1A#;
   Cfg_Queue_Enable      : constant U64 := 16#1C#;
   Cfg_Queue_Notify_Off  : constant U64 := 16#1E#;
   Cfg_Queue_Desc_Low    : constant U64 := 16#20#;
   Cfg_Queue_Desc_High   : constant U64 := 16#24#;
   Cfg_Queue_Avail_Low   : constant U64 := 16#28#;
   Cfg_Queue_Avail_High  : constant U64 := 16#2C#;
   Cfg_Queue_Used_Low    : constant U64 := 16#30#;
   Cfg_Queue_Used_High   : constant U64 := 16#34#;

   MSIX_None : constant U16 := 16#FFFF#;

   --  Full reset: status 0, poll until it reads back 0.
   procedure Reset;

   function Status return U32;
   procedure Set_Status (Bits : U32);
   procedure Add_Status (Bits : U32);

   --  Feature negotiation, feature word 0 (bits 0..31); ring/
   --  transport features (bit 32+) are not consulted.
   function Device_Features return U32;
   procedure Set_Driver_Features (Bits : U32);

   function Num_Queues return U32;

   --  Modern queue programming: Queue_Select, then Queue_Setup
   --  writes size/addresses and Queue_Enable last. MSI-X vectors
   --  are parked at MSIX_None so the device raises INTx.
   procedure Queue_Select (Index : U32);
   function Queue_Size return U32;
   procedure Queue_Setup
     (Num       : U32;
      Desc_PA   : U64;
      Avail_PA  : U64;
      Used_PA   : U64);

   --  Doorbell: queue_notify_off for the queue (re-read per call,
   --  the field is per-queue) handed to the driver's Notify_Write.
   procedure Notify (Queue : U32);

   --  Interrupt status: reads (and clears) the ISR register.
   --  ACK is a no-op kept for MMIO-API symmetry.
   function Interrupt_Status return U32;
   procedure ACK_Interrupt (Bits : U32);
end Virtio.PCI;
