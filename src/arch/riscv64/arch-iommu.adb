with System.Storage_Elements;
with Board.PLIC;
with Board.UART;
with Kernel.Device_Tree;
with Kernel.Interrupts;
with Kernel.Physical_Memory;

package body Arch.IOMMU is
   use type U32;
   use type Kernel.Device_Tree.Status;
   use type Kernel.Physical_Memory.Status;

   ------------------------------------------------------------------
   --  Register map (spec chapter 5)
   ------------------------------------------------------------------

   Reg_Caps  : constant U64 := 16#00#;
   Reg_Fctl  : constant U64 := 16#08#;
   Reg_Ddtp  : constant U64 := 16#10#;
   Reg_Cqb   : constant U64 := 16#18#;
   Reg_Cqh   : constant U64 := 16#20#;
   Reg_Cqt   : constant U64 := 16#24#;
   Reg_Fqb   : constant U64 := 16#28#;
   Reg_Fqh   : constant U64 := 16#30#;
   Reg_Fqt   : constant U64 := 16#34#;
   Reg_Cqcsr : constant U64 := 16#48#;
   Reg_Fqcsr : constant U64 := 16#4C#;
   Reg_Ipsr  : constant U64 := 16#54#;
   Reg_Icvec : constant U64 := 16#2F8#;

   --  Debug translation-probe registers (spec 5.24..5.26).
   Reg_Tr_Iova : constant U64 := 16#258#;
   Reg_Tr_Ctl  : constant U64 := 16#260#;
   Reg_Tr_Resp : constant U64 := 16#268#;

   --  Capabilities bits.
   Caps_SV39     : constant U64 := 2#1_0000_0000#;          --  bit 9
   Caps_MSI_Flat : constant U64 := 16#40_0000#;             --  bit 22
   Caps_DBG      : constant U64 := 16#8000_0000#;           --  bit 31
   Caps_IGS_Mask : constant U64 := 16#3000_0000#;           --  bits 29:28
   IGS_WSI_Only  : constant U64 := 16#1000_0000#;
   pragma Unreferenced (IGS_WSI_Only);

   --  64-byte device-context offsets when Caps_MSI_Flat is set.
   --  Layout: tc(0), iohgatp(8), ta(16), fsc(24), msiptp(32),
   --  msi_addr_mask(40), msi_addr_pattern(48), custom(56).
   DC_Off_Msiptp   : constant U64 := 32;
   DC_Off_Mask     : constant U64 := 40;
   DC_Off_Pattern  : constant U64 := 48;
   Msiptp_Mode_Flat : constant U64 := 1;

   --  Reserved IOVA page for software MSI delivery.  The IOMMU is
   --  configured to treat any write inside this page as an MSI; an
   --  invalid flat MSI page table forces a fault, and the fault
   --  handler converts the (device_id, data) pair into a virtual IRQ
   --  source delivery.  This page is far above any identity-mapped
   --  DMA region on qemu-virt.
   MSI_IOVA_Base   : constant U64 := 16#0000_0003_FFFF_0000#;
   MSI_IOVA_Mask   : constant U64 := 16#FFFF_FFFF_FFFF_F000#;

   --  fctl.
   Fctl_WSI : constant U32 := 2;

   --  ddtp: iommu_mode in bits 3:0, busy bit 4, PPN in bits 53:10.
   Ddtp_Mode_3LVL : constant U64 := 4;
   Ddtp_Busy      : constant U64 := 16#10#;

   --  Queue CSRs.
   Queue_Enable      : constant U32 := 1;
   Queue_Intr_Enable : constant U32 := 2;
   Queue_Mem_Fault   : constant U32 := 16#100#;
   Queue_Overflow    : constant U32 := 16#200#;
   Queue_Active      : constant U32 := 16#1_0000#;
   Cqcsr_Cmd_To      : constant U32 := 16#200#;
   Cqcsr_Cmd_Ill     : constant U32 := 16#400#;

   --  ipsr.
   Ipsr_Fip : constant U32 := 2;

   --  Command opcodes and fields (spec chapter 3.1).
   Cmd_IotINVAL    : constant U64 := 1;
   Cmd_Iofence     : constant U64 := 2;
   Cmd_Iodir       : constant U64 := 3;
   Cmd0_AV         : constant U64 := 16#400#;           --  bit 10
   Cmd0_Iodir_DV   : constant U64 := 16#2_0000_0000#;   --  bit 33
   Cmd0_Fence_PR   : constant U64 := 16#1000#;          --  bit 12
   Cmd0_Fence_PW   : constant U64 := 16#2000#;          --  bit 13

   --  Device context (spec 2.1): tc/iohgatp/ta/fsc (+ MSI fields
   --  when capabilities.MSI_FLAT makes DCs 64 bytes).
   DC_TC_V   : constant U64 := 1;
   Fsc_Sv39  : constant U64 := 8;

   --  Sv39 PTE bits (same encoding as satp PTEs).
   Pte_V : constant U64 := 1;
   Pte_R : constant U64 := 2;
   Pte_W : constant U64 := 4;
   Pte_A : constant U64 := 64;
   Pte_D : constant U64 := 128;

   Queue_Entries : constant U32 := 16;          --  log2sz = 4
   Queue_Log2_M1 : constant U64 := 3;           --  cqb/fqb bits 4:0

   Poll_Limit : constant U32 := 10_000_000;

   ------------------------------------------------------------------
   --  State
   ------------------------------------------------------------------

   Is_Available : Boolean := False;
   Base_VA      : U64 := 0;          --  physmap VA of the registers
   IRQ_Source   : U64 := 0;

   DC_Stride    : U64 := 32;         --  64 when MSI_FLAT
   DDT_Root_PA  : U64 := 0;
   CQ_PA        : U64 := 0;
   FQ_PA        : U64 := 0;

   Faults_Seen  : U64 := 0;

   --  Lazily created device contexts.
   Max_Devices : constant := 16;

   type Device_Record is record
      Device_Id  : U32 := No_Device;
      DC_VA      : U64 := 0;         --  VA of the DC in its DDT leaf
      IO_Root_PA : U64 := 0;         --  Sv39 IO page table root
   end record;

   --  MSI controller: one flat (invalid) page table shared by all
   --  devices, plus a small vector table that maps (device_id, data)
   --  to a virtual kernel IRQ source.
   Max_MSI_Vectors : constant := 64;

   type MSI_Record is record
      Device_Id : U32 := No_Device;
      Data      : U32 := 0;
      Source    : U64 := 0;
   end record;

   MSI_PT_PA      : U64 := 0;
   MSI_Next_Index : Natural := 0;
   MSI_Vectors    : array (1 .. Max_MSI_Vectors) of MSI_Record;
   MSI_Supported  : Boolean := False;

   Devices      : array (1 .. Max_Devices) of Device_Record;
   Device_Count : Natural := 0;

   ------------------------------------------------------------------
   --  Low-level access helpers
   ------------------------------------------------------------------

   function To_Addr (VA : U64) return System.Address is
     (System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (VA)));

   function Read64 (VA : U64) return U64 is
      V : U64 with Volatile, Address => To_Addr (VA);
   begin
      return V;
   end Read64;

   procedure Write64 (VA : U64; Value : U64) is
      V : U64 with Volatile, Address => To_Addr (VA);
   begin
      V := Value;
   end Write64;

   function Read32 (VA : U64) return U32 is
      V : U32 with Volatile, Address => To_Addr (VA);
   begin
      return V;
   end Read32;

   procedure Write32 (VA : U64; Value : U32) is
      V : U32 with Volatile, Address => To_Addr (VA);
   begin
      V := Value;
   end Write32;

   function Reg (Offset : U64) return U64 is (Read64 (Base_VA + Offset));
   procedure Set_Reg (Offset : U64; Value : U64) is
   begin
      Write64 (Base_VA + Offset, Value);
   end Set_Reg;

   function Reg32 (Offset : U64) return U32 is (Read32 (Base_VA + Offset));
   procedure Set_Reg32 (Offset : U64; Value : U32) is
   begin
      Write32 (Base_VA + Offset, Value);
   end Set_Reg32;

   procedure Fence
     with Import, Convention => C, External_Name => "riscv_fence_rw";

   --  PPN fields live at bits 53:10 holding PA >> 12.
   function PPN_Field (PA : U64) return U64 is
     (Interfaces.Shift_Left (Interfaces.Shift_Right (PA, 12), 10));

   function PPN_Of (Table_Entry : U64) return U64 is
     (Interfaces.Shift_Left
        (Interfaces.Shift_Right (Table_Entry, 10) and 16#FFF_FFFF_FFFF#, 12));

   function Alloc_Page (PA : out U64) return Boolean is
      Result : Kernel.Physical_Memory.Status;
   begin
      Kernel.Physical_Memory.Allocate_Frame (Result, PA);
      if Result /= Kernel.Physical_Memory.Ok then
         return False;
      end if;

      declare
         VA : constant U64 := Arch.Phys_To_Virt (PA);
      begin
         for Off in U64 range 0 .. 511 loop
            Write64 (VA + Off * 8, 0);
         end loop;
      end;
      return True;
   end Alloc_Page;

   ------------------------------------------------------------------
   --  Command queue
   ------------------------------------------------------------------

   procedure Submit_Command (D0 : U64; D1 : U64) is
      Tail : constant U32 := Reg32 (Reg_Cqt);
      Idx  : constant U64 := U64 (Tail mod Queue_Entries);
      Next : constant U32 := (Tail + 1) mod Queue_Entries;
      VA   : constant U64 := Arch.Phys_To_Virt (CQ_PA) + Idx * 16;
      Poll : U32 := 0;
      CSR  : U32;
   begin
      Write64 (VA, D0);
      Write64 (VA + 8, D1);
      Fence;
      Set_Reg32 (Reg_Cqt, Next);

      loop
         exit when Reg32 (Reg_Cqh) = Next;
         Poll := Poll + 1;
         if Poll > Poll_Limit then
            Board.UART.Put_Line ("iommu command timeout");
            return;
         end if;
      end loop;

      CSR := Reg32 (Reg_Cqcsr);
      if (CSR and (Queue_Mem_Fault or Cqcsr_Cmd_To or Cqcsr_Cmd_Ill)) /= 0 then
         Board.UART.Put ("iommu command error csr ");
         Board.UART.Put_Hex (U64 (CSR));
         Board.UART.Put_Line ("");
         Set_Reg32
           (Reg_Cqcsr,
            CSR and (Queue_Mem_Fault or Cqcsr_Cmd_To or Cqcsr_Cmd_Ill));
      end if;
   end Submit_Command;

   procedure Invalidate_DDT (Device_Id : U32) is
   begin
      Submit_Command
        (Cmd_Iodir or Cmd0_Iodir_DV
           or Interfaces.Shift_Left (U64 (Device_Id), 40),
         0);
   end Invalidate_DDT;

   procedure Invalidate_VMA (IOVA : U64) is
   begin
      Submit_Command
        (Cmd_IotINVAL or Cmd0_AV,
         Interfaces.Shift_Left (Interfaces.Shift_Right (IOVA, 12), 10));
   end Invalidate_VMA;

   procedure Fence_Commands is
   begin
      Submit_Command (Cmd_Iofence or Cmd0_Fence_PR or Cmd0_Fence_PW, 0);
   end Fence_Commands;

   ------------------------------------------------------------------
   --  Device contexts
   ------------------------------------------------------------------

   function Find_Device (Device_Id : U32) return Natural is
   begin
      for I in 1 .. Device_Count loop
         if Devices (I).Device_Id = Device_Id then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Device;

   --  Walk/create the 3-level DDT path to Device_Id's DC and return
   --  its VA; returns 0 on allocation failure.
   function Ensure_DC (Device_Id : U32) return U64 is
      I2 : constant U64 := Interfaces.Shift_Right (U64 (Device_Id), 15)
        and 16#1FF#;
      I1 : constant U64 := Interfaces.Shift_Right (U64 (Device_Id), 6)
        and 16#1FF#;
      I0 : constant U64 := U64 (Device_Id) and 16#3F#;
      Cur  : U64 := DDT_Root_PA;
      Ent  : U64;
      PA   : U64;
   begin
      declare
         Level : Natural := 2;
      begin
         while Level >= 1 loop
            declare
               VA     : constant U64 := Arch.Phys_To_Virt (Cur);
               Ent_VA : constant U64 :=
                 VA + (if Level = 2 then I2 else I1) * 8;
            begin
               Ent := Read64 (Ent_VA);
               if (Ent and 1) = 0 then
                  if not Alloc_Page (PA) then
                     return 0;
                  end if;
                  Ent := 1 or PPN_Field (PA);
                  Write64 (Ent_VA, Ent);
               end if;
               Cur := PPN_Of (Ent);
            end;
            Level := Level - 1;
         end loop;
      end;

      return Arch.Phys_To_Virt (Cur) + I0 * DC_Stride;
   end Ensure_DC;

   --  Get or create the device record (context + empty IO table).
   function Ensure_Device (Device_Id : U32) return Natural is
      Existing : constant Natural := Find_Device (Device_Id);
      DC_VA    : U64;
      Root_PA  : U64;
   begin
      if Existing /= 0 then
         return Existing;
      end if;

      if Device_Count >= Max_Devices then
         Board.UART.Put_Line ("iommu device table full");
         return 0;
      end if;

      DC_VA := Ensure_DC (Device_Id);
      if DC_VA = 0 then
         Board.UART.Put_Line ("iommu ddt alloc failed");
         return 0;
      end if;

      if not Alloc_Page (Root_PA) then
         Board.UART.Put_Line ("iommu io root alloc failed");
         return 0;
      end if;

      --  tc = valid; iohgatp bare; ta 0; fsc = Sv39 over the IO
      --  root; MSI translation off (INTx devices). A/D bits are
      --  preset in PTEs, so SADE stays 0.
      Write64 (DC_VA,      DC_TC_V);
      Write64 (DC_VA + 8,  0);
      Write64 (DC_VA + 16, 0);
      Write64 (DC_VA + 24, Root_PA / 4096
                 or Interfaces.Shift_Left (Fsc_Sv39, 60));
      if DC_Stride = 64 then
         Write64 (DC_VA + 32, 0);
         Write64 (DC_VA + 40, 0);
         Write64 (DC_VA + 48, 0);
         Write64 (DC_VA + 56, 0);
      end if;

      Invalidate_DDT (Device_Id);
      Fence_Commands;

      Device_Count := Device_Count + 1;
      Devices (Device_Count) :=
        (Device_Id  => Device_Id,
         DC_VA      => DC_VA,
         IO_Root_PA => Root_PA);

      Board.UART.Put ("iommu context online for device ");
      Board.UART.Put_Hex (U64 (Device_Id));
      Board.UART.Put_Line ("");

      return Device_Count;
   end Ensure_Device;

   function MSI_Address_For (Device_Id : U32) return U64 is
   begin
      return MSI_IOVA_Base + U64 (Device_Id) * 16;
   end MSI_Address_For;

   function MSI_Data_For (Vector : Natural) return U32 is
   begin
      return U32 (Vector);
   end MSI_Data_For;

   ------------------------------------------------------------------
   --  MSI controller (software delivery through the IOMMU fault queue)
   ------------------------------------------------------------------

   function MSI_Vector_Create
     (Device_Id : U32;
      Vector    : Natural;
      Source    : out U64;
      Address   : out U64;
      Data      : out U32) return Boolean
   is
      Idx      : Natural;
      Dev_Idx  : Natural;
      DC_VA    : U64;
      Msiptp   : U64;
   begin
      Source  := 0;
      Address := 0;
      Data    := 0;

      if not Is_Available
        or else not MSI_Supported
        or else Device_Id = No_Device
        or else Vector > Natural'Last / 2
      then
         return False;
      end if;

      Dev_Idx := Ensure_Device (Device_Id);
      if Dev_Idx = 0 then
         return False;
      end if;

      DC_VA := Devices (Dev_Idx).DC_VA;

      if MSI_Next_Index >= Max_MSI_Vectors then
         Board.UART.Put_Line ("iommu msi vector table full");
         return False;
      end if;

      MSI_Next_Index := MSI_Next_Index + 1;
      Idx := MSI_Next_Index;

      Source := Kernel.Interrupts.MSI_Vector_Base + U64 (Idx) - 1;
      if Source >= U64 (Kernel.Interrupts.Max_Sources) then
         MSI_Next_Index := MSI_Next_Index - 1;
         Board.UART.Put_Line ("iommu msi source exhausted");
         return False;
      end if;

      Address := MSI_Address_For (Device_Id);
      Data    := MSI_Data_For (Vector);

      MSI_Vectors (Idx) :=
        (Device_Id => Device_Id,
         Data      => Data,
         Source    => Source);

      --  Enable MSI detection for this device.  Rewriting the same
      --  values is harmless; we do it lazily on the first vector.
      Msiptp := PPN_Field (MSI_PT_PA) or Msiptp_Mode_Flat;
      Write64 (DC_VA + DC_Off_Msiptp,   Msiptp);
      Write64 (DC_VA + DC_Off_Mask,     MSI_IOVA_Mask);
      Write64 (DC_VA + DC_Off_Pattern,  MSI_IOVA_Base);
      Invalidate_DDT (Device_Id);
      Fence_Commands;

      Board.UART.Put ("iommu msi vector ");
      Board.UART.Put_Hex (U64 (Vector));
      Board.UART.Put (" source ");
      Board.UART.Put_Hex (Source);
      Board.UART.Put_Line ("");

      return True;
   end MSI_Vector_Create;

   ------------------------------------------------------------------
   --  IO page tables (Sv39, 4 KiB pages, IOVA = PA)
   ------------------------------------------------------------------

   procedure Walk_IO_Table
     (Root_PA  : U64;
      IOVA     : U64;
      Create   : Boolean;
      Leaf_VA  : out U64)   --  VA of the level-0 PTE, 0 when absent
   is
      VPN : array (0 .. 2) of U64;
      Cur : U64 := Root_PA;
      Ent : U64;
      PA  : U64;
   begin
      VPN (2) := Interfaces.Shift_Right (IOVA, 30) and 16#1FF#;
      VPN (1) := Interfaces.Shift_Right (IOVA, 21) and 16#1FF#;
      VPN (0) := Interfaces.Shift_Right (IOVA, 12) and 16#1FF#;

      Leaf_VA := 0;
      for Level in reverse 1 .. 2 loop
         declare
            Ent_VA : constant U64 :=
              Arch.Phys_To_Virt (Cur) + VPN (Level) * 8;
         begin
            Ent := Read64 (Ent_VA);
            if (Ent and Pte_V) = 0 then
               if not Create or else not Alloc_Page (PA) then
                  return;
               end if;
               Ent := Pte_V or PPN_Field (PA);
               Write64 (Ent_VA, Ent);
            end if;
            Cur := PPN_Of (Ent);
         end;
      end loop;

      Leaf_VA := Arch.Phys_To_Virt (Cur) + VPN (0) * 8;
   end Walk_IO_Table;

   procedure Map_DMA (Device_Id : U32; Frame_PA : U64) is
      Idx  : Natural;
      Leaf : U64;
   begin
      if not Is_Available or else Device_Id = No_Device then
         return;
      end if;

      Idx := Ensure_Device (Device_Id);
      if Idx = 0 then
         return;
      end if;

      Walk_IO_Table
        (Devices (Idx).IO_Root_PA, Frame_PA, Create => True,
         Leaf_VA => Leaf);
      if Leaf = 0 then
         Board.UART.Put_Line ("iommu io walk alloc failed");
         return;
      end if;

      if (Read64 (Leaf) and Pte_V) /= 0 then
         return;  --  already mapped
      end if;

      Write64 (Leaf, Pte_V or Pte_R or Pte_W or Pte_A or Pte_D
                or PPN_Field (Frame_PA));
      Invalidate_VMA (Frame_PA);
      Fence_Commands;
   end Map_DMA;

   procedure Unmap_DMA (Device_Id : U32; Frame_PA : U64) is
      Idx  : Natural;
      Leaf : U64;
   begin
      if not Is_Available or else Device_Id = No_Device then
         return;
      end if;

      Idx := Find_Device (Device_Id);
      if Idx = 0 then
         return;
      end if;

      Walk_IO_Table
        (Devices (Idx).IO_Root_PA, Frame_PA, Create => False,
         Leaf_VA => Leaf);
      if Leaf = 0 or else (Read64 (Leaf) and Pte_V) = 0 then
         return;
      end if;

      Write64 (Leaf, 0);
      Invalidate_VMA (Frame_PA);
      Fence_Commands;
   end Unmap_DMA;

   ------------------------------------------------------------------
   --  Fault queue interrupt
   ------------------------------------------------------------------

   procedure Handle_Fault_Interrupt is
      Head      : U32;
      Tail      : U32;
      Rec       : U64;
      Hdr       : U64;
      IOVA      : U64;
      Data      : U32;
      Device_Id : U32;
      CSR       : U32;
      Claimed   : Boolean;
   begin
      loop
         Head := Reg32 (Reg_Fqh);
         Tail := Reg32 (Reg_Fqt);
         exit when Head = Tail;

         Rec := Arch.Phys_To_Virt (FQ_PA) + U64 (Head) * 32;
         Hdr := Read64 (Rec);
         IOVA := Read64 (Rec + 16);
         Faults_Seen := Faults_Seen + 1;

         --  Software MSI delivery: an MSI write to the reserved page
         --  faults on the invalid flat MSI page table.  Convert the
         --  (device_id, data) pair into a virtual IRQ source delivery.
         if MSI_Supported
           and then (IOVA and MSI_IOVA_Mask) = MSI_IOVA_Base
         then
            Device_Id := U32 ((IOVA - MSI_IOVA_Base) / 16);
            Data := U32 (Read64 (Rec + 8) and 16#FFFF_FFFF#);
            for I in 1 .. MSI_Next_Index loop
               if MSI_Vectors (I).Device_Id = Device_Id
                 and then MSI_Vectors (I).Data = Data
               then
                  Kernel.Interrupts.Deliver
                    (MSI_Vectors (I).Source, Claimed);
                  exit;
               end if;
            end loop;
         else
            Board.UART.Put ("iommu fault cause ");
            Board.UART.Put_Hex (Hdr and 16#FFF#);
            Board.UART.Put (" did ");
            Board.UART.Put_Hex
              (Interfaces.Shift_Right (Hdr, 40) and 16#FF_FFFF#);
            Board.UART.Put (" ttyp ");
            Board.UART.Put_Hex
              (Interfaces.Shift_Right (Hdr, 34) and 16#3F#);
            Board.UART.Put (" iova ");
            Board.UART.Put_Hex (IOVA);
            Board.UART.Put_Line ("");
         end if;

         Set_Reg32 (Reg_Fqh, (Head + 1) mod Queue_Entries);
      end loop;

      Set_Reg32 (Reg_Ipsr, Ipsr_Fip);

      CSR := Reg32 (Reg_Fqcsr);
      if (CSR and (Queue_Mem_Fault or Queue_Overflow)) /= 0 then
         Board.UART.Put ("iommu fault queue error csr ");
         Board.UART.Put_Hex (U64 (CSR));
         Board.UART.Put_Line ("");
         Set_Reg32 (Reg_Fqcsr, CSR and (Queue_Mem_Fault or Queue_Overflow));
      end if;
   end Handle_Fault_Interrupt;

   ------------------------------------------------------------------
   --  Init
   ------------------------------------------------------------------

   function Available return Boolean is (Is_Available);

   function MSI_Available return Boolean is
   begin
      return Is_Available and then MSI_Supported;
   end MSI_Available;

   ------------------------------------------------------------------
   --  Boot self-test through the debug translation-probe registers:
   --  a scratch device context proves unmapped IOVAs fault, a
   --  mapped frame resolves to its PPN, and the unmap faults
   --  again — no cooperating device needed.
   ------------------------------------------------------------------

   Tr_Go_Busy    : constant U64 := 1;
   Tr_Resp_Fault : constant U64 := 1;

   function Probe (Device_Id : U32; IOVA : U64) return U64 is
      Poll : U32 := 0;
   begin
      Set_Reg (Reg_Tr_Iova, IOVA);
      Set_Reg (Reg_Tr_Ctl,
               Tr_Go_Busy or Interfaces.Shift_Left (U64 (Device_Id), 40));
      loop
         exit when (Reg (Reg_Tr_Ctl) and Tr_Go_Busy) = 0;
         Poll := Poll + 1;
         if Poll > Poll_Limit then
            return Tr_Resp_Fault;
         end if;
      end loop;
      return Reg (Reg_Tr_Resp);
   end Probe;

   procedure Self_Test is
      Test_Dev : constant U32 := 16#F8#;  --  dev 31: never plugged
      Idx      : Natural;
      Frame    : U64;
      Resp     : U64;
      Passed   : Boolean := True;
   begin
      Idx := Ensure_Device (Test_Dev);
      if Idx = 0 or else not Alloc_Page (Frame) then
         Board.UART.Put_Line ("iommu selftest alloc failed");
         return;
      end if;

      Resp := Probe (Test_Dev, Frame);
      if (Resp and Tr_Resp_Fault) = 0 then
         Board.UART.Put_Line ("iommu selftest: unmapped probe did not fault");
         Passed := False;
      end if;

      Map_DMA (Test_Dev, Frame);
      Resp := Probe (Test_Dev, Frame);
      if (Resp and Tr_Resp_Fault) /= 0 then
         Board.UART.Put_Line ("iommu selftest: mapped probe faulted");
         Passed := False;
      elsif PPN_Of (Resp) /= Frame then
         Board.UART.Put_Line ("iommu selftest: probe PPN mismatch");
         Passed := False;
      end if;

      Unmap_DMA (Test_Dev, Frame);
      Resp := Probe (Test_Dev, Frame);
      if (Resp and Tr_Resp_Fault) = 0 then
         Board.UART.Put_Line
            ("iommu selftest: unmapped-again probe did not fault");
         Passed := False;
      end if;

      declare
         PMM_Result : Kernel.Physical_Memory.Status;
      begin
         Kernel.Physical_Memory.Deallocate_Frame (Frame, PMM_Result);
      end;

      if Passed then
         Board.UART.Put_Line ("iommu selftest online");
      end if;
   end Self_Test;

   procedure Initialize (DTB : U64) is
      Base     : U64;
      Size     : U64;
      IRQ      : U64;
      Result   : Kernel.Device_Tree.Status;
      Caps     : U64;
      Poll     : U32;
      Ok       : Boolean;
   begin
      Kernel.Device_Tree.Find_Device
        (DTB        => DTB,
         Compatible => "riscv,iommu",
         Base       => Base,
         Size       => Size,
         IRQ_Source => IRQ,
         Result     => Result);

      if Result /= Kernel.Device_Tree.Ok then
         return;  --  no IOMMU on this machine; DMA stays direct
      end if;

      Base_VA := Arch.Phys_To_Virt (Base);
      IRQ_Source := IRQ;

      Caps := Reg (Reg_Caps);
      Board.UART.Put ("iommu caps ");
      Board.UART.Put_Hex (Caps);
      Board.UART.Put_Line ("");

      if (Caps and Caps_SV39) = 0 then
         Board.UART.Put_Line ("iommu sv39 unsupported, staying bare");
         return;
      end if;

      if (Caps and Caps_IGS_Mask) = 0 then
         Board.UART.Put_Line ("iommu wired irqs unsupported, staying bare");
         return;
      end if;

      if (Caps and Caps_MSI_Flat) /= 0 then
         DC_Stride := 64;
         MSI_Supported := Alloc_Page (MSI_PT_PA);
         if not MSI_Supported then
            Board.UART.Put_Line ("iommu msi page table alloc failed");
         end if;
      end if;

      --  Queues: one page each (16 commands = 256 B, 16 fault
      --  records = 512 B), entries field is log2sz-1.
      Ok := Alloc_Page (CQ_PA) and then Alloc_Page (FQ_PA)
        and then Alloc_Page (DDT_Root_PA);
      if not Ok then
         Board.UART.Put_Line ("iommu alloc failed, staying bare");
         return;
      end if;

      Set_Reg (Reg_Cqb, PPN_Field (CQ_PA) or Queue_Log2_M1);
      Set_Reg32 (Reg_Cqcsr, Queue_Enable);
      Poll := 0;
      while (Reg32 (Reg_Cqcsr) and Queue_Active) = 0 loop
         Poll := Poll + 1;
         if Poll > Poll_Limit then
            Board.UART.Put_Line ("iommu cq enable timeout");
            return;
         end if;
      end loop;

      Set_Reg (Reg_Fqb, PPN_Field (FQ_PA) or Queue_Log2_M1);
      Set_Reg32 (Reg_Fqcsr, Queue_Enable);
      Poll := 0;
      while (Reg32 (Reg_Fqcsr) and Queue_Active) = 0 loop
         Poll := Poll + 1;
         if Poll > Poll_Limit then
            Board.UART.Put_Line ("iommu fq enable timeout");
            return;
         end if;
      end loop;

      --  Translating mode: 3-level DDT over the (empty) root.
      Set_Reg (Reg_Ddtp, PPN_Field (DDT_Root_PA) or Ddtp_Mode_3LVL);
      Poll := 0;
      while (Reg (Reg_Ddtp) and Ddtp_Busy) /= 0 loop
         Poll := Poll + 1;
         if Poll > Poll_Limit then
            Board.UART.Put_Line ("iommu ddtp busy timeout");
            return;
         end if;
      end loop;

      --  Wired interrupt on vector 0 (first DTB interrupt cell):
      --  all causes to vector 0, fault-queue interrupt enabled.
      Set_Reg32 (Reg_Fctl, Fctl_WSI);
      Set_Reg (Reg_Icvec, 0);
      Set_Reg32 (Reg_Fqcsr, Queue_Enable or Queue_Intr_Enable);

      if IRQ_Source /= 0 then
         Kernel.Interrupts.Register_Kernel
           (IRQ_Source, Handle_Fault_Interrupt'Access);
         Board.PLIC.Enable
           (Board.PLIC.Source_Id (IRQ_Source));
      end if;

      Is_Available := True;
      Board.UART.Put ("iommu online, irq ");
      Board.UART.Put_Hex (IRQ_Source);
      Board.UART.Put_Line ("");

      if (Caps and Caps_DBG) /= 0 then
         Self_Test;
      end if;
   end Initialize;
end Arch.IOMMU;
