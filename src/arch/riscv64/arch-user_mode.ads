with Interfaces;

package Arch.User_Mode is
   subtype U64 is Interfaces.Unsigned_64;

   procedure Enter_User_Mode
     (Entry_Point : U64;
      Stack       : U64)
     with No_Return;
end Arch.User_Mode;
