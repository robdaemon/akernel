with Akernel_User.Console;
with Akernel_User.Syscalls;

--  Spawn-v2 staging target (milestone 12): a finite program the
--  fuzzer reads into a memory object via the file server, spawns
--  from that object, and reaps. Granted the console Send cap at
--  handle 1 by the spawner's grant list.
procedure Memstage is
begin
   Akernel_User.Console.Set_Endpoint (1);
   Akernel_User.Console.Put_Line ("memstage online");
   Akernel_User.Syscalls.Process_Exit;
end Memstage;
