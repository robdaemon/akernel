package body Board.Device_Tree is
   Boot_DTB_PA : U64
     with Import, Convention => C, External_Name => "boot_dtb_pa";

   function Boot_DTB_Physical_Address return U64 is
   begin
      return Boot_DTB_PA;
   end Boot_DTB_Physical_Address;
end Board.Device_Tree;
