with Arch;
with System.Storage_Elements;

package body Kernel.CPUs is
   use type Interfaces.Unsigned_64;

   function Raw_Current_Hart return U64
     with Import, Convention => C, External_Name => "riscv_current_hart";

   procedure Raw_Send_IPI (Mask : U64; Mask_Base : U64)
     with Import, Convention => C, External_Name => "sbi_send_ipi";

   IDs          : Raw_Id_Array := (others => 0);
   Started      : array (CPU_Index) of Boolean := (others => False);
   Infos        : array (CPU_Index) of aliased Boot_Info :=
     (others => (Trap_Stack_Top => 0, Index => 0, Main_Stack_Top => 0));
   Configured   : Natural := 1;

   procedure Configure (Raw_Ids : Raw_Id_Array; Count : Natural) is
   begin
      IDs := Raw_Ids;
      Configured := Natural'Min (Count, Max_CPUs);
      for CPU in CPU_Index loop
         Infos (CPU).Index := U64 (CPU);
      end loop;
      Started := (others => False);
      Started (CPU_Index'First) := True;   --  the boot hart
   end Configure;

   function Count return Natural is (Configured);

   function Current return CPU_Index is
   begin
      return CPU_Index (Raw_Current_Hart mod U64 (Max_CPUs));
   end Current;

   function Raw_Id (CPU : CPU_Index) return U64 is (IDs (CPU));

   function Info_Block_PA (CPU : CPU_Index) return U64 is
   begin
      return Arch.Kernel_Virt_To_Phys
        (U64 (System.Storage_Elements.To_Integer
           (Infos (CPU)'Address)));
   end Info_Block_PA;

   procedure Set_Stacks
     (CPU       : CPU_Index;
      Trap_Top  : U64;
      Main_Top  : U64)
   is
   begin
      Infos (CPU).Trap_Stack_Top := Trap_Top;
      Infos (CPU).Main_Stack_Top := Main_Top;
   end Set_Stacks;

   function Idle_Trap_Stack_Top (CPU : CPU_Index) return U64 is
     (Arch.Phys_To_Virt (Infos (CPU).Trap_Stack_Top));

   function Idle_Main_Stack_Top (CPU : CPU_Index) return U64 is
     (Arch.Phys_To_Virt (Infos (CPU).Main_Stack_Top));

   procedure Mark_Started (CPU : CPU_Index) is
   begin
      Started (CPU) := True;
   end Mark_Started;

   procedure Notify_Work is
      Mask : U64 := 0;
      Self : constant CPU_Index := Current;
   begin
      if Configured <= 1 then
         return;
      end if;

      for CPU in CPU_Index range 0 .. CPU_Index (Configured - 1) loop
         if CPU /= Self and then Started (CPU) then
            Mask := Mask or Interfaces.Shift_Left (U64'(1), Natural (IDs (CPU)));
         end if;
      end loop;

      if Mask /= 0 then
         Raw_Send_IPI (Mask, 0);
      end if;
   end Notify_Work;

end Kernel.CPUs;
