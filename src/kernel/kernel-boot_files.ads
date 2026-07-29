with Interfaces;
with System;
with Kernel.Capabilities;

package Kernel.Boot_Files is
   subtype U64 is Interfaces.Unsigned_64;

   --  Boot-file image caps (docs/IPC.md): one pinned Boot_File_Object
   --  per initrd file, enumerated at boot and handed to init. Spawn
   --  consumes them as ELF images; the cap-based byte API lets init
   --  parse the manifest without the kernel ever parsing a path.
   Max_Files       : constant := 16;
   Max_Name_Length : constant := 48;

   type Status is
     (Ok,
      Invalid_File,
      Not_Found,
      Bad_Image,
      Out_Of_Range);

   --  Walk the initrd and build the static boot-file table.
   --  Zero-length entries (cpio directories) are skipped.
   procedure Enumerate
     (Result : out Status;
      Count  : out Natural);

   function File_Count return Natural;
   function File_Name (Index : Natural) return String;
   function File_Object (Index : Natural) return System.Address;

   --  Cap-based byte API (syscalls 6/7): the cap must name a
   --  Boot_File_Object with the Read right.
   procedure Size
     (Cap     : Kernel.Capabilities.Cap_Entry;
      Result  : out Status;
      Length  : out U64);

   procedure Read_Byte
     (Cap     : Kernel.Capabilities.Cap_Entry;
      Offset  : U64;
      Result  : out Status;
      Value   : out U64);
end Kernel.Boot_Files;
