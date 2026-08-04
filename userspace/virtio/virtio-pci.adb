package body Virtio.PCI is
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   procedure Reset is
   begin
      Common_Write8 (Cfg_Device_Status, 0);
      loop
         exit when Common_Read8 (Cfg_Device_Status) = 0;
      end loop;
   end Reset;

   function Status return U32 is
   begin
      return U32 (Common_Read8 (Cfg_Device_Status));
   end Status;

   procedure Set_Status (Bits : U32) is
   begin
      Common_Write8 (Cfg_Device_Status, U8 (Bits and 16#FF#));
   end Set_Status;

   procedure Add_Status (Bits : U32) is
      Cur : constant U8 := Common_Read8 (Cfg_Device_Status);
   begin
      Common_Write8 (Cfg_Device_Status, Cur or U8 (Bits and 16#FF#));
   end Add_Status;

   function Device_Features return U32 is
   begin
      Common_Write32 (Cfg_Device_Feat_Sel, 0);
      return Common_Read32 (Cfg_Device_Features);
   end Device_Features;

   procedure Set_Driver_Features (Bits : U32) is
   begin
      Common_Write32 (Cfg_Driver_Feat_Sel, 0);
      Common_Write32 (Cfg_Driver_Features, Bits);
   end Set_Driver_Features;

   function Num_Queues return U32 is
   begin
      return U32 (Common_Read16 (Cfg_Num_Queues));
   end Num_Queues;

   procedure Queue_Select (Index : U32) is
   begin
      Common_Write16 (Cfg_Queue_Sel, U16 (Index and 16#FFFF#));
   end Queue_Select;

   function Queue_Size return U32 is
   begin
      return U32 (Common_Read16 (Cfg_Queue_Size));
   end Queue_Size;

   procedure Queue_Setup
     (Num       : U32;
      Desc_PA   : U64;
      Avail_PA  : U64;
      Used_PA   : U64)
   is
   begin
      Common_Write16 (Cfg_Queue_Size, U16 (Num and 16#FFFF#));
      Common_Write16 (Cfg_Queue_MSIX_Vector, MSIX_None);
      Common_Write32 (Cfg_Queue_Desc_Low,  U32 (Desc_PA and 16#FFFF_FFFF#));
      Common_Write32 (Cfg_Queue_Desc_High, U32 (Interfaces.Shift_Right (Desc_PA, 32)));
      Common_Write32 (Cfg_Queue_Avail_Low, U32 (Avail_PA and 16#FFFF_FFFF#));
      Common_Write32 (Cfg_Queue_Avail_High, U32 (Interfaces.Shift_Right (Avail_PA, 32)));
      Common_Write32 (Cfg_Queue_Used_Low,  U32 (Used_PA and 16#FFFF_FFFF#));
      Common_Write32 (Cfg_Queue_Used_High, U32 (Interfaces.Shift_Right (Used_PA, 32)));
      Common_Write16 (Cfg_Queue_Enable, 1);
   end Queue_Setup;

   procedure Notify (Queue : U32) is
      Notify_Off : U16;
   begin
      Queue_Select (Queue);
      Notify_Off := Common_Read16 (Cfg_Queue_Notify_Off);
      Notify_Write
        (U64 (Notify_Off),
         U16 (Queue and 16#FFFF#));
   end Notify;

   function Interrupt_Status return U32 is
   begin
      return ISR_Read;
   end Interrupt_Status;

   procedure ACK_Interrupt (Bits : U32) is
      pragma Unreferenced (Bits);
   begin
      --  The ISR read already cleared the register.
      null;
   end ACK_Interrupt;
end Virtio.PCI;
