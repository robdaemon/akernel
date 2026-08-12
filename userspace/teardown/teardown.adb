with Akernel_User.Syscalls;
with Akernel_User.Files;

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
--          who woke with what. Word 1 reports word 0 of the
--          reply payload (the deferred-reply test's ordering
--          token, milestone 47).
--    "D" — DEFERRED REPLIES (milestone 47): receive TWO calls
--          on handle 1, hold both reply caps, reply to the
--          SECOND caller first (word 0 = 2), then the first
--          (word 0 = 1). On the old fixed-slot reply cap the
--          second receive would have failed caller one with
--          Reply_Gone; duplication lets both complete, out of
--          order.
--    "S" — plain-send handle 1 (a marker in word 0), then report
--          the send result code in word 0 of a call on handle 2.
--          Send ends at delivery: the peer wakes with Ok as soon
--          as the fuzzer receives, and the fuzzer's Reply attempt
--          must fail.
--    "X <n>" — exit immediately with status <n> (decimal):
--          milestone-40b exit-code channel; the fuzzer's
--          Reap_Process_Code must read <n> back.
--    "P <path>" — blocking-pipe READER (milestone 49): bind the
--          fs cap (handle 5), read 16 bytes from the pipe; the
--          fileserver defers the reply until a writer pushes or
--          closes. Report status (word 0), count (word 1) and
--          the first 8 bytes packed big-endian (word 2) on
--          handle 2.
--    "W <path>" — blocking-pipe WRITER (milestone 49): write 16
--          bytes; deferred until a reader frees ring space.
--          Report status (word 0) + count (word 1) on handle 2.
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

   Arg    : String (1 .. 24);
   Arg_Ln : Natural;
   Result : U64;
   R_H    : U64;
begin
   Read_Args (Arg, Arg_Ln);

   if Arg_Ln > 0 and then Arg (1) = 'R' then
      --  One receive, no reply, exit.
      Result := IPC_Recv (Service_EP, R_H);
      Process_Exit;
   end if;

   if Arg_Ln > 0 and then Arg (1) = 'D' then
      --  Deferred replies (milestone 47): hold BOTH reply caps,
      --  then complete the second caller first. Each reply's
      --  word 0 carries the receive order so the fuzzer
      --  can verify out-of-order completion.
      declare
         H_A, H_B : U64;
      begin
         Result := IPC_Recv (Service_EP, H_A);
         if Result /= IPC_Ok then
            Process_Exit;
         end if;
         Result := IPC_Recv (Service_EP, H_B);
         if Result /= IPC_Ok then
            Process_Exit;
         end if;

         Message.Label := 16#7D2#;
         Message.Words := (0 => 2, others => 0);
         Message.Caps  := (others => 0);
         Result := IPC_Reply (H_B);
         if Result /= IPC_Ok then
            Process_Exit;
         end if;

         Message.Label := 16#7D2#;
         Message.Words := (0 => 1, others => 0);
         Message.Caps  := (others => 0);
         Result := IPC_Reply (H_A);
         Process_Exit;
      end;
   end if;

   if Arg_Ln > 2 and then Arg (1) = 'X' and then Arg (2) = ' ' then
      declare
         Code : U64 := 0;
      begin
         for I in 3 .. Arg_Ln loop
            if Arg (I) in '0' .. '9' then
               Code := Code * 10
                 + U64 (Character'Pos (Arg (I))
                          - Character'Pos ('0'));
            end if;
         end loop;
         Process_Exit (Code);
      end;
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

   if Arg_Ln > 2 and then Arg (1) = 'P' and then Arg (2) = ' ' then
      --  Blocking-pipe reader (milestone 49): the read blocks
      --  server-side until data or EOF arrives.
      declare
         Buf : String (1 .. 16) := (others => ' ');
         Cnt : U64;
         W2  : U64 := 0;
      begin
         Akernel_User.Files.Bind (5);
         Result := Akernel_User.Files.Read
           (Arg (3 .. Arg_Ln), 0, Buf'Address, 16, Cnt);
         for I in 1 .. 8 loop
            W2 := W2 * 256 + U64 (Character'Pos (Buf (I)));
         end loop;
         Message.Label := 16#7D3#;
         Message.Words := (0 => Result, 1 => Cnt, 2 => W2,
                           others => 0);
         Message.Caps  := (others => 0);
         Result := IPC_Call (Result_EP);
         Process_Exit;
      end;
   end if;

   if Arg_Ln > 2 and then Arg (1) = 'W' and then Arg (2) = ' ' then
      --  Blocking-pipe writer (milestone 49): the write blocks
      --  server-side until the ring has room.
      declare
         Buf : constant String := "blocked-write-16";
         Cnt : U64;
      begin
         Akernel_User.Files.Bind (5);
         Result := Akernel_User.Files.Write
           (Arg (3 .. Arg_Ln), 0, Buf'Address, 16, Cnt);
         Message.Label := 16#7D3#;
         Message.Words := (0 => Result, 1 => Cnt, others => 0);
         Message.Caps  := (others => 0);
         Result := IPC_Call (Result_EP);
         Process_Exit;
      end;
   end if;

   --  Caller role: park on the service endpoint until it fails,
   --  then report the wake code (+ the reply's word 0, m47).
   Result := IPC_Call (Service_EP);

   declare
      Reply_W0 : constant U64 := Message.Words (0);
   begin
      Message.Label := 16#7D0#;
      Message.Words := (0 => Result, others => 0);
      Message.Words (1) := Reply_W0;
      Message.Caps  := (others => 0);
      Result := IPC_Call (Result_EP);
   end;

   Process_Exit;
end Teardown;
