with Interfaces;

package Kernel.Initrd is
   subtype U64 is Interfaces.Unsigned_64;

   Initrd_Base : constant U64 := 16#8400_0000#;

   type Status is
     (Ok,
      Bad_Header,
      Not_Found,
      Bad_CPIO);

   procedure Find
     (Name   : String;
      Result : out Status;
      Base   : out U64;
      Size   : out U64);
end Kernel.Initrd;
