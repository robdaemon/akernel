package body Arch.User_Mode is
   procedure Raw_Enter_User_Mode
     (Entry_Point : U64;
      Stack       : U64;
      User_Satp   : U64)
     with Import, Convention => C, External_Name => "riscv_enter_user_mode",
          No_Return;

   procedure Enter_User_Mode
     (Entry_Point : U64;
      Stack       : U64;
      User_Satp   : U64)
   is
   begin
      Raw_Enter_User_Mode (Entry_Point, Stack, User_Satp);
   end Enter_User_Mode;
end Arch.User_Mode;
