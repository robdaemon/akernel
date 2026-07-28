with Interfaces;

package Arch.User_Mode is
   subtype U64 is Interfaces.Unsigned_64;

   --  Enters user mode in the target address space.  User_Satp is the
   --  satp CSR value for the target root (see Arch.MMU.Satp_Value).
   procedure Enter_User_Mode
     (Entry_Point : U64;
      Stack       : U64;
      User_Satp   : U64)
     with No_Return;
end Arch.User_Mode;
