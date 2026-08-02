with Arch;
with Interfaces;

package Kernel.Initrd is
   subtype U64 is Interfaces.Unsigned_64;

   --  QEMU loads the initrd at physical 0x8400_0000; the kernel
   --  reaches it through the physmap.
   Initrd_Base : constant U64 := Arch.Phys_To_Virt (16#8400_0000#);

   type Status is
     (Ok,
      Bad_Header,
      Not_Found,
      Bad_CPIO);

   --  Whole image extent (akrd header + cpio payload) from the
   --  image header; used to reserve the initrd frames against the
   --  PMM.
   function Image_Length return U64;

   procedure Find
     (Name   : String;
      Result : out Status;
      Base   : out U64;
      Size   : out U64);

   --  Sequential iteration over all archive entries (boot-file
   --  enumeration). Reset_Iteration rewinds; Next returns Ok per
   --  entry and Not_Found at the end. Names longer than the caller's
   --  buffer are truncated (Name_Length = characters copied).
   procedure Reset_Iteration;

   procedure Next
     (Result      : out Status;
      Name        : out String;
      Name_Length : out Natural;
      Base        : out U64;
      Size        : out U64);
end Kernel.Initrd;
