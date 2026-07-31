with Interfaces;
with System;

package Kernel.ELF is
   subtype U64 is Interfaces.Unsigned_64;

   User_Alias_Delta : constant U64 := 16#4000_0000#;

   type Status is
     (Ok,
      Bad_Magic,
      Unsupported,
      Bad_Image);

   --  Where ELF bytes come from: a contiguous kernel-visible range
   --  (physmap VA, e.g. an initrd boot file) or the scattered frames
   --  of a memory object (spawn v2: image staged by a file server).
   type Source_Kind is (Physmap_Bytes, Object_Frames);

   type Source (Kind : Source_Kind := Physmap_Bytes) is record
      case Kind is
         when Physmap_Bytes =>
            Base : U64;
         when Object_Frames =>
            Object : System.Address;
      end case;
   end record;

   procedure Load_User_Alias
     (Image       : Source;
      Image_Size  : U64;
      Result      : out Status;
      Entry_Point : out U64);

   procedure Load_Into_Address_Space
     (Image       : Source;
      Image_Size  : U64;
      Root        : U64;
      Result      : out Status;
      Entry_Point : out U64);
end Kernel.ELF;
