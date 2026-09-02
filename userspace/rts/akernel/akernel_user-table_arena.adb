with Akernel_User.Syscalls;

package body Akernel_User.Table_Arena is
   use type U64;

   package SYS renames Akernel_User.Syscalls;

   --  Lazy init to Arena_Base: no library-level elaboration runs
   --  in crates, so the cursor arms itself on first Reserve.
   Next_VA : U64 := 0;

   function Reserve (Pages : U64) return U64 is
      Cap : U64;
      VA  : U64;
      Del : U64;
   begin
      if Next_VA = 0 then
         Next_VA := Arena_Base;
      end if;

      if Pages = 0
        or else Pages > (Arena_End - Next_VA) / 4096
      then
         return 0;
      end if;

      Cap := SYS.Mem_Alloc (Pages);
      if Cap = SYS.Syscall_Failed then
         return 0;
      end if;

      VA := Next_VA;
      --  Flags 3 = read+write (write implies read).
      if SYS.Mem_Map
        (SYS.Address_Space_Cap, Cap, VA, 0, Pages * 4096, 3) /= 0
      then
         Del := SYS.Cap_Delete (Cap);
         return 0;
      end if;

      Next_VA := Next_VA + Pages * 4096;
      return VA;
   end Reserve;
end Akernel_User.Table_Arena;
