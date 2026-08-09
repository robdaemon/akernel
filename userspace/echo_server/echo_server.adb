with Akernel_User.Syscalls;
with Akernel_User.IPC;
with Akernel_User.Console;

--  Echo test server for the fuzzer's end-to-end IPC checks, granted
--  an endpoint cap at handle 1 and the console Send cap at handle 2.
--  Written against the typed RPC wrappers; the fuzzer drives the
--  same wire protocol with raw ecalls. Three rounds:
--    rounds 1-2: reply carries the badge, the request's words 0..3
--      echoed into reply words 1..4, and the previous round's
--      double-reply status in word 5 (0 first);
--    round 3: reply carries the badge and the transferred cap handle
--      (as rewritten into echo's own table).
--  After each reply it immediately replies again, which must fail
--  (one-shot reply cap). Then exits so the fuzzer can reap it.
procedure Echo_Server is
   use Akernel_User.Syscalls;
   use type U64;

   --  Wire protocol: request occupies message words 0..3, reply
   --  fills all six words.
   type Echo_Request is record
      A, B, C, D : U64;
   end record;

   type Echo_Response is record
      Badge       : U64;  --  word 0
      A, B, C, D  : U64;  --  words 1..4
      Prev_Status : U64;  --  word 5
   end record;

   package RPC is new Akernel_User.IPC (Echo_Request, Echo_Response);

   Status            : U64;
   Label             : U64;
   Request           : Echo_Request;
   Response          : Echo_Response;
   Badge             : U64;
   Caps              : RPC.Cap_Array;
   Prev_Double_Reply : U64 := 0;
   Rounds            : Natural := 0;
begin
   Akernel_User.Console.Set_Endpoint (2);
   Akernel_User.Console.Put_Line ("echo online");

   loop
      Status := RPC.Receive (1, Label, Request, Badge, Caps);
      exit when Status /= IPC_Ok;

      if Rounds = 2 then
         Response := (Badge => Badge, A => Caps (0), others => 0);
      else
         Response := (Badge       => Badge,
                      A           => Request.A,
                      B           => Request.B,
                      C           => Request.C,
                      D           => Request.D,
                      Prev_Status => Prev_Double_Reply);
      end if;

      Status := RPC.Reply (Label, Response);
      exit when Status /= IPC_Ok;

      --  One-shot check: replying again with no pending caller must
      --  fail; surfaced to the fuzzer in the next round's word 5.
      --  Raw reply is fine here: the kernel rejects it before
      --  touching the buffer.
      Prev_Double_Reply := IPC_Reply;

      Rounds := Rounds + 1;
      exit when Rounds = 3;
   end loop;

   if Status = IPC_Ok then
      Akernel_User.Console.Put_Line ("echo done");
   else
      Akernel_User.Console.Put_Line ("echo error exit");
   end if;

   Process_Exit;
end Echo_Server;
