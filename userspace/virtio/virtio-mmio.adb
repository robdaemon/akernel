package body Virtio.MMIO is
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   function Magic_Ok return Boolean is
   begin
      return Reg_Read (Reg_Magic) = Magic;
   end Magic_Ok;

   function Version return U32 is
   begin
      return Reg_Read (Reg_Version);
   end Version;

   function Device_ID return U32 is
   begin
      return Reg_Read (Reg_Device_ID);
   end Device_ID;

   procedure Reset is
   begin
      Reg_Write (Reg_Status, 0);
      --  Device must raise Device_NEEDS_RESET... for MMIO simple:
      --  poll until status reads back 0.
      loop
         exit when Reg_Read (Reg_Status) = 0;
      end loop;
   end Reset;

   function Status return U32 is
   begin
      return Reg_Read (Reg_Status);
   end Status;

   procedure Set_Status (Bits : U32) is
   begin
      Reg_Write (Reg_Status, Bits);
   end Set_Status;

   procedure Add_Status (Bits : U32) is
   begin
      Reg_Write (Reg_Status, Reg_Read (Reg_Status) or Bits);
   end Add_Status;

   function Device_Features return U32 is
   begin
      Reg_Write (Reg_Device_Feat_Sel, 0);
      return Reg_Read (Reg_Device_Features);
   end Device_Features;

   procedure Set_Driver_Features (Bits : U32) is
   begin
      Reg_Write (Reg_Driver_Feat_Sel, 0);
      Reg_Write (Reg_Driver_Features, Bits);
   end Set_Driver_Features;

   procedure Queue_Select (Index : U32) is
   begin
      Reg_Write (Reg_Queue_Sel, Index);
   end Queue_Select;

   function Queue_Num_Max return U32 is
   begin
      return Reg_Read (Reg_Queue_Num_Max);
   end Queue_Num_Max;

   procedure Queue_Setup
     (Num       : U32;
      Desc_PA   : U64;
      Avail_PA  : U64;
      Used_PA   : U64)
   is
   begin
      Reg_Write (Reg_Queue_Num, Num);
      Reg_Write (Reg_Queue_Desc_Low,  U32 (Desc_PA and 16#FFFF_FFFF#));
      Reg_Write (Reg_Queue_Desc_High, U32 (Interfaces.Shift_Right (Desc_PA, 32)));
      Reg_Write (Reg_Queue_Avail_Low, U32 (Avail_PA and 16#FFFF_FFFF#));
      Reg_Write (Reg_Queue_Avail_High, U32 (Interfaces.Shift_Right (Avail_PA, 32)));
      Reg_Write (Reg_Queue_Used_Low,  U32 (Used_PA and 16#FFFF_FFFF#));
      Reg_Write (Reg_Queue_Used_High, U32 (Interfaces.Shift_Right (Used_PA, 32)));
      Reg_Write (Reg_Queue_Ready, 1);
   end Queue_Setup;

   procedure Notify (Queue : U32) is
   begin
      Reg_Write (Reg_Queue_Notify, Queue);
   end Notify;

   function Interrupt_Status return U32 is
   begin
      return Reg_Read (Reg_Interrupt_Status);
   end Interrupt_Status;

   procedure ACK_Interrupt (Bits : U32) is
   begin
      Reg_Write (Reg_Interrupt_ACK, Bits);
   end ACK_Interrupt;
end Virtio.MMIO;
