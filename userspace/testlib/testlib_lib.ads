with Libserv;
with Akernel_User.Syscalls;

--  Library-level dispatch logic for the Testlib server. The dispatch
--  callback must live at library level because Libserv's access type
--  is a library-level access-to-procedure type (Ada accessibility).

package Testlib_Lib is
   use type Akernel_User.Syscalls.U64;

   subtype U64 is Akernel_User.Syscalls.U64;
   subtype Words is Libserv.Words;
   subtype Caps is Libserv.Caps;

   procedure On_Open;

   procedure Dispatch
     (Label        : U64;
      Request      : Words;
      Request_Caps : Caps;
      Reply_Handle : U64;
      Shutdown     : out Boolean);

end Testlib_Lib;
