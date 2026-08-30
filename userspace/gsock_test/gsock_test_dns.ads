with Interfaces;

--  Gsock_Test (milestone 73) helper: an in-process DNS responder
--  task serving exactly one A-record query over GNAT.Sockets UDP.
--  The main task points Net:dns at its own address, so the whole
--  exchange is a deterministic hairpin.  Jorvik has no task
--  entries, so sequencing rides Atomic flags (the task_test
--  pattern): main fills Own_IP/Reply_Word, raises Go, waits for
--  Bound (socket bound to port 53, Receive_Socket armed), and
--  waits for Done after its lookup.

package Gsock_Test_Dns is
   subtype U32 is Interfaces.Unsigned_32;

   Own_IP     : String (1 .. 16);        --  valid 1 .. Own_Len
   Own_Len    : Natural := 0;
   Reply_Word : U32 := 0;                --  host-order packed A record

   Go    : Boolean := False with Atomic, Volatile;
   Bound : Boolean := False with Atomic, Volatile;
   Done  : Boolean := False with Atomic, Volatile;

   task Responder;

end Gsock_Test_Dns;
