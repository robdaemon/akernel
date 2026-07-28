with Interfaces;
use type Interfaces.Unsigned_64;

package Arch is
   subtype U64 is Interfaces.Unsigned_64;

   --  High-half layout:
   --  - Kernel image is linked at Kernel_Virt_Base + (PA - Kernel_Phys_Base);
   --    QEMU loads it at physical Kernel_Phys_Base (ELF LMA).
   --  - All physical memory (RAM frames, page tables, MMIO, initrd, DTB)
   --    is accessed through the physmap at Physmap_Base + PA.
   --  Kernel_Virt_Base sits in the medlow top-2GiB window so the
   --  precompiled light runtime keeps linking, and is chosen so
   --  VA - PA is a whole number of gigapages: the kernel VMA gigapage
   --  can then map the kernel image 1:1 (PA 0x80200000 is not 1 GiB
   --  aligned, so the VMA base must equal the PA modulo 1 GiB).
   Kernel_Virt_Base : constant U64 := 16#FFFF_FFFF_8020_0000#;
   Kernel_Phys_Base : constant U64 := 16#0000_0000_8020_0000#;
   Kernel_Delta     : constant U64 := Kernel_Virt_Base - Kernel_Phys_Base;

   Physmap_Base     : constant U64 := 16#FFFF_FFC0_0000_0000#;

   function Phys_To_Virt (PA : U64) return U64 is (Physmap_Base + PA);

   function Kernel_Virt_To_Phys (VA : U64) return U64 is (VA - Kernel_Delta);
end Arch;
