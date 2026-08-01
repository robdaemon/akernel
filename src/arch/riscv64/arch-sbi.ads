with Interfaces;

package Arch.SBI is
   subtype U64 is Interfaces.Unsigned_64;

   procedure Set_Timer (Time_Value : U64);
   function Time return U64;

   procedure Enable_Timer_Interrupts;
   procedure Enable_External_Interrupts;
   --  sie-only enables (no sstatus.SIE): kernel-mode wfi wakes on a
   --  pending interrupt without trapping, so idle paths must not
   --  take interrupt traps on a live kernel stack.
   procedure Enable_Software_Interrupts;
   procedure Enable_Timer_And_Software_SIE;
   procedure Disable_Interrupts;
   procedure Wait_For_Interrupt;

   --  sip: pending interrupt bits.  Software-pending (IPI) is the
   --  only bit S-mode can clear directly; timer-pending clears via
   --  Set_Timer, external-pending via PLIC claim.
   function Pending return U64;
   procedure Clear_Software_Pending;

   --  SBI HSM hart_start(hartid, entry PA, opaque): 0 on success.
   function Hart_Start
     (Raw_Hart_Id : U64;
      Entry_PA    : U64;
      Opaque      : U64) return U64;

   function Scause return U64;
   function Sepc return U64;
   function Stval return U64;
   function Sstatus return U64;
end Arch.SBI;
