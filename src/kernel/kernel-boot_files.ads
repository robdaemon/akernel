with Interfaces;
with System;
with Kernel.Capabilities;

package Kernel.Boot_Files is
   subtype U64 is Interfaces.Unsigned_64;

   --  Boot-file image caps (docs/IPC.md): one pinned Boot_File_Object
   --  per initrd file, enumerated at boot and handed to init. Spawn
   --  consumes them as ELF images; the cap-based byte API lets init
   --  parse the manifest without the kernel ever parsing a path.
   Max_Files       : constant := 24;
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

   --  Append the pseudo-file "dtb": the flattened device tree
   --  itself, exposed to init through the ordinary boot-file cap
   --  path (read bytes, borrowed RO mapping) so userspace device
   --  enumeration needs no new kernel mechanism. Base is the
   --  physmap VA of the DTB; Length its FDT totalsize. Called once
   --  at boot after Enumerate when DTB discovery succeeded.
   procedure Add_DTB
     (Base   : U64;
      Length : U64;
      Result : out Status);

   function File_Count return Natural;
   function File_Name (Index : Natural) return String;
   function File_Object (Index : Natural) return System.Address;

   --  Cap-based byte API (syscalls 6/7): the cap must name a
   --  Boot_File_Object with the Read right.
   procedure Size
     (Cap     : Kernel.Capabilities.Cap_Entry;
      Result  : out Status;
      Length  : out U64);

   --  File extent for borrowed read-only mapping (mem_map syscall):
   --  Base is the physmap VA of the file data; Length is the file
   --  length in bytes. The cap must have the Read right.
   procedure Bounds
     (Cap     : Kernel.Capabilities.Cap_Entry;
      Result  : out Status;
      Base    : out U64;
      Length  : out U64);

   procedure Read_Byte
     (Cap     : Kernel.Capabilities.Cap_Entry;
      Offset  : U64;
      Result  : out Status;
      Value   : out U64);
end Kernel.Boot_Files;
