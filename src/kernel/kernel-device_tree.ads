with Interfaces;

package Kernel.Device_Tree is
   subtype U64 is Interfaces.Unsigned_64;

   type Status is
     (Ok,
      Bad_Magic,
      Unsupported_Format,
      Memory_Not_Found);

   procedure Discover_Memory
     (DTB    : U64;
      Result : out Status;
      Base   : out U64;
      Size   : out U64);
end Kernel.Device_Tree;
