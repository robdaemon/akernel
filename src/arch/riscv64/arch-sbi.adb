package body Arch.SBI is
   procedure Raw_Set_Timer (Time_Value : U64)
     with Import, Convention => C, External_Name => "sbi_set_timer";

   function Raw_Time return U64
     with Import, Convention => C, External_Name => "riscv_read_time";

   procedure Raw_Enable_Timer_Interrupts
     with Import,
          Convention => C,
          External_Name => "riscv_enable_timer_interrupts";

   procedure Raw_Enable_External_Interrupts
     with Import,
          Convention => C,
          External_Name => "riscv_enable_external_interrupts";

   procedure Raw_Enable_Software_Interrupts
     with Import,
          Convention => C,
          External_Name => "riscv_enable_software_interrupts";

   procedure Raw_Enable_Timer_And_Software_SIE
     with Import,
          Convention => C,
          External_Name => "riscv_enable_timer_software_sie";

   function Raw_Pending return U64
     with Import, Convention => C, External_Name => "riscv_read_sip";

   procedure Raw_Clear_Software_Pending
     with Import,
          Convention => C,
          External_Name => "riscv_clear_soft_pending";

   function Raw_Hart_Start
     (Raw_Hart_Id : U64;
      Entry_PA    : U64;
      Opaque      : U64) return U64
     with Import, Convention => C, External_Name => "sbi_hart_start";

   procedure Raw_Disable_Interrupts
     with Import, Convention => C, External_Name => "riscv_disable_interrupts";

   procedure Raw_Wait_For_Interrupt
     with Import, Convention => C, External_Name => "riscv_wfi";

   function Raw_Scause return U64
     with Import, Convention => C, External_Name => "riscv_read_scause";

   function Raw_Sepc return U64
     with Import, Convention => C, External_Name => "riscv_read_sepc";

   function Raw_Stval return U64
     with Import, Convention => C, External_Name => "riscv_read_stval";

   function Raw_Sstatus return U64
     with Import, Convention => C, External_Name => "riscv_read_sstatus";

   procedure Set_Timer (Time_Value : U64) is
   begin
      Raw_Set_Timer (Time_Value);
   end Set_Timer;

   function Time return U64 is (Raw_Time);

   procedure Enable_Timer_Interrupts is
   begin
      Raw_Enable_Timer_Interrupts;
   end Enable_Timer_Interrupts;

   procedure Enable_External_Interrupts is
   begin
      Raw_Enable_External_Interrupts;
   end Enable_External_Interrupts;

   procedure Enable_Software_Interrupts is
   begin
      Raw_Enable_Software_Interrupts;
   end Enable_Software_Interrupts;

   procedure Enable_Timer_And_Software_SIE is
   begin
      Raw_Enable_Timer_And_Software_SIE;
   end Enable_Timer_And_Software_SIE;

   function Pending return U64 is (Raw_Pending);

   procedure Clear_Software_Pending is
   begin
      Raw_Clear_Software_Pending;
   end Clear_Software_Pending;

   function Hart_Start
     (Raw_Hart_Id : U64;
      Entry_PA    : U64;
      Opaque      : U64) return U64 is
     (Raw_Hart_Start (Raw_Hart_Id, Entry_PA, Opaque));

   procedure Disable_Interrupts is
   begin
      Raw_Disable_Interrupts;
   end Disable_Interrupts;

   procedure Wait_For_Interrupt is
   begin
      Raw_Wait_For_Interrupt;
   end Wait_For_Interrupt;

   function Scause return U64 is (Raw_Scause);
   function Sepc return U64 is (Raw_Sepc);
   function Stval return U64 is (Raw_Stval);
   function Sstatus return U64 is (Raw_Sstatus);
end Arch.SBI;
