--  Virtio MMIO register-level operations (virtio 1.2 §4.2, modern
--  interface; Version register = 2). Generic over 32-bit register
--  access so the crate stays independent of how the driver maps the
--  device page.

generic
   with function Reg_Read (Offset : U64) return U32;
   with procedure Reg_Write (Offset : U64; Value : U32);
package Virtio.MMIO is
   --  Register offsets.
   Reg_Magic            : constant U64 := 16#00#;
   Reg_Version          : constant U64 := 16#04#;
   Reg_Device_ID        : constant U64 := 16#08#;
   Reg_Device_Features  : constant U64 := 16#10#;
   Reg_Device_Feat_Sel  : constant U64 := 16#14#;
   Reg_Driver_Features  : constant U64 := 16#20#;
   Reg_Driver_Feat_Sel  : constant U64 := 16#24#;
   Reg_Queue_Sel        : constant U64 := 16#30#;
   Reg_Queue_Num_Max    : constant U64 := 16#34#;
   Reg_Queue_Num        : constant U64 := 16#38#;
   Reg_Queue_Ready      : constant U64 := 16#44#;
   Reg_Queue_Notify     : constant U64 := 16#50#;
   Reg_Interrupt_Status : constant U64 := 16#60#;
   Reg_Interrupt_ACK    : constant U64 := 16#64#;
   Reg_Status           : constant U64 := 16#70#;
   Reg_Queue_Desc_Low   : constant U64 := 16#80#;
   Reg_Queue_Desc_High  : constant U64 := 16#84#;
   Reg_Queue_Avail_Low  : constant U64 := 16#90#;
   Reg_Queue_Avail_High : constant U64 := 16#94#;
   Reg_Queue_Used_Low   : constant U64 := 16#A0#;
   Reg_Queue_Used_High  : constant U64 := 16#A4#;

   function Magic_Ok return Boolean;
   function Version return U32;
   function Device_ID return U32;

   --  Full reset: status 0, queue ready cleared.
   procedure Reset;

   function Status return U32;
   procedure Set_Status (Bits : U32);
   procedure Add_Status (Bits : U32);

   --  Feature negotiation: read device bits for word 0 (features
   --  0..31), write back the accepted subset. Ring/transport
   --  features (bit 32+) are not consulted by these drivers.
   function Device_Features return U32;
   procedure Set_Driver_Features (Bits : U32);

   --  Modern queue programming (QueueSel then per-queue area
   --  addresses + size, QueueReady last).
   procedure Queue_Select (Index : U32);
   function Queue_Num_Max return U32;
   procedure Queue_Setup
     (Num       : U32;
      Desc_PA   : U64;
      Avail_PA  : U64;
      Used_PA   : U64);

   procedure Notify (Queue : U32);

   function Interrupt_Status return U32;
   procedure ACK_Interrupt (Bits : U32);
end Virtio.MMIO;
