with Interfaces;

--  Virtio constants and base types (virtio 1.2 spec), shared by
--  the MMIO (Virtio.MMIO) and PCI (Virtio.PCI) transports.
--  Shared by the individual virtio driver programs;
--  deliberately free of any akernel RTS dependencies so the crate
--  stays target-independent.

package Virtio is
   subtype U8  is Interfaces.Unsigned_8;
   subtype U16 is Interfaces.Unsigned_16;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   Magic : constant U32 := 16#7472_6976#;  --  "virt"

   --  Device IDs (DeviceID register at MMIO offset 0x08).
   Device_Invalid : constant U32 := 0;
   Device_Network : constant U32 := 1;
   Device_Block   : constant U32 := 2;
   Device_Console : constant U32 := 3;
   Device_RNG     : constant U32 := 4;
   Device_9P      : constant U32 := 9;
   Device_GPU     : constant U32 := 16;

   --  Status register bits.
   Status_Acknowledge  : constant U32 := 1;
   Status_Driver       : constant U32 := 2;
   Status_Driver_Ok    : constant U32 := 4;
   Status_Features_Ok  : constant U32 := 8;
   Status_Device_Error : constant U32 := 64;
   Status_Failed       : constant U32 := 128;

   --  Interrupt status bits (InterruptStatus register).
   ISR_Used_Buffer  : constant U32 := 1;
   ISR_Config_Change : constant U32 := 2;

   --  Descriptor flags.
   Desc_F_Next     : constant U16 := 1;
   Desc_F_Write    : constant U16 := 2;
   Desc_F_Indirect : constant U16 := 4;

   No_Desc : constant U16 := 16#FFFF#;
end Virtio;
