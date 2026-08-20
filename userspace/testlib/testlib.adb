with Libserv;
with Testlib_Lib;

--  Testlib: example shared library server for milestone 58 Tier-1.
--  Uses Libserv for lifecycle and Testlib_Lib for the request dispatch.

procedure Testlib is
begin
   --  Testlib version 1.0.  The version floor is enforced by the
   --  library manager (milestone 65).
   Libserv.Run (Testlib_Lib.On_Open'Access, Testlib_Lib.Dispatch'Access,
                Version => 1, Revision => 0);
end Testlib;
