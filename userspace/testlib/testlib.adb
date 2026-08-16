with Libserv;
with Testlib_Lib;

--  Testlib: example shared library server for milestone 58 Tier-1.
--  Uses Libserv for lifecycle and Testlib_Lib for the request dispatch.

procedure Testlib is
begin
   Libserv.Run (Testlib_Lib.On_Open'Access, Testlib_Lib.Dispatch'Access);
end Testlib;
