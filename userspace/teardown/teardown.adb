with Akernel_User.Syscalls;

--  Endpoint-teardown test peer for the fuzzer (milestone 34):
--  receiver death must fail the callers parked on its endpoint
--  instead of leaving them blocked forever (the orphaned-shell
--  burn).
--
--  Role comes from the spawn-args page (milestone 33a):
--    "R" — receive one message on handle 1, then exit WITHOUT
--          replying. Teardown closes the reply cap (fails the
--          caller awaiting the reply with Reply_Gone) and closes
--          the Receive-right endpoint cap (Fail_Endpoint: queued
--          callers wake with Endpoint_Gone, later calls fail
--          immediately).
--    "C" — call handle 1, then report the wake result code in
--          word 0 of a call on handle 2 so the fuzzer can check
--          who woke with what.
--    "S" — plain-send handle 1 (a marker in word 0), then report
--          the send result code in word 0 of a call on handle 2.
--          Send ends at delivery: the peer wakes with Ok as soon
--          as the fuzzer receives, and the fuzzer's Reply attempt
--          must fail.
--
--  Grant layout (handles): 1 = service endpoint, 2 = result
--  endpoint (C only), 3 = filler (duplicated cap; the args page
--  must sit at grant index 3 = handle 4, see
--  Syscalls.Args_Handle), 4 = args page.
procedure Teardown is
   use Akernel_User.Syscalls;
   use type U64;

   Service_EP : constant U64 := 1;
   Result_EP  : constant U64 := 2;

   Arg    : String (1 .. 8);
   Arg_Ln : Natural;
   Result : U64;
begin
   Read_Args (Arg, Arg_Ln);

   if Arg_Ln > 0 and then Arg (1) = 'R' then
      --  One receive, no reply, exit.
      Result := IPC_Recv (Service_EP);
      Process_Exit;
   end if;

   if Arg_Ln > 0 and then Arg (1) = 'S' then
      --  Plain send: delivered, no reply phase, then report.
      Message.Label := 16#5D#;
      Message.Words := (0 => 16#5EAD_5EAD#, others => 0);
      Message.Caps  := (others => 0);
      Result := IPC_Send (Service_EP);

      Message.Label := 16#7D0#;
      Message.Words := (0 => Result, others => 0);
      Message.Caps  := (others => 0);
      Result := IPC_Call (Result_EP);

      Process_Exit;
   end if;

   --  Caller role: park on the service endpoint until it fails,
   --  then report the wake code.
   Result := IPC_Call (Service_EP);

   Message.Label := 16#7D0#;
   Message.Words := (0 => Result, others => 0);
   Message.Caps  := (others => 0);
   Result := IPC_Call (Result_EP);

   Process_Exit;
end Teardown;
