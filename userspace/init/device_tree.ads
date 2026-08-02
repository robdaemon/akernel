with Interfaces;

--  Userspace FDT walker for the device manager: parses the mapped
--  "dtb" boot file and reports every node that carries a compatible
--  property. Per-node capture (compatible entries, first reg entry,
--  first interrupts cell) is decided at node close because FDT
--  property order is arbitrary; reg cells are interpreted with the
--  PARENT's #address-cells/#size-cells via a depth stack (the
--  node's own cells props apply to its children only).

package Device_Tree is
   subtype U8 is Interfaces.Unsigned_8;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   type Status is
     (Ok,
      Bad_Magic,
      Unsupported_Format);

   Max_Compatible : constant := 4;
   Max_Name       : constant := 32;
   Max_Depth      : constant := 16;

   type Compatible_String is record
      Text   : String (1 .. Max_Name) := (others => Character'Val (0));
      Length : Natural := 0;
   end record;

   type Compatible_List is array (1 .. Max_Compatible)
     of Compatible_String;

   type Node_Info is record
      Compatibles : Compatible_List;
      Compatible_Count : Natural := 0;
      Base        : U64 := 0;   --  first reg entry, 0 when absent
      Size        : U64 := 0;
      IRQ         : U64 := 0;   --  first interrupts cell, 0 when absent
   end record;

   type Node_Handler is access procedure (Info : Node_Info);

   --  Base is the address of the FDT header (mapped boot file VA +
   --  lead-in). On_Node fires once per node with a compatible
   --  property, in tree order.
   procedure Walk
     (Base    : U64;
      On_Node : Node_Handler;
      Result  : out Status);
end Device_Tree;
