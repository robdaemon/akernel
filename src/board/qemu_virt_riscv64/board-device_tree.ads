with Interfaces;

package Board.Device_Tree is
   subtype U64 is Interfaces.Unsigned_64;

   function Boot_DTB_Physical_Address return U64;
end Board.Device_Tree;
