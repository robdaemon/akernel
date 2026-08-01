with Interfaces;

package Kernel.Device_Tree is
   subtype U64 is Interfaces.Unsigned_64;

   type Status is
     (Ok,
      Bad_Magic,
      Unsupported_Format,
      Memory_Not_Found,
      Device_Not_Found);

   procedure Discover_Memory
     (DTB    : U64;
      Result : out Status;
      Base   : out U64;
      Size   : out U64);

   --  Finds the first node whose compatible string list contains an
   --  entry exactly equal to Compatible. Returns the first reg entry
   --  (Base/Size, interpreted with the parent node's address/size
   --  cells) and, when the node has an interrupts property, its first
   --  cell in IRQ_Source (assumes single-cell interrupt specifiers,
   --  which holds for PLIC-wired devices); IRQ_Source is 0 when the
   --  node carries no interrupts property.
   procedure Find_Device
     (DTB        : U64;
      Compatible : String;
      Base       : out U64;
      Size       : out U64;
      IRQ_Source : out U64;
      Result     : out Status);
end Kernel.Device_Tree;
