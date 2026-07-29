with Akernel_User.Syscalls;

--  handle 1. Three rounds:
--    rounds 1-2: reply badge in word 0, received words 0..3 in words
--      1..4, previous round's double-reply status in word 5 (0 first);
--    round 3: reply badge in word 0 and the transferred cap handle
--      (as rewritten into echo's own table) in word 1.
--  After each reply it immediately replies again, which must fail
--  (one-shot reply cap). Then exits so the fuzzer can reap it.
procedure Echo is
   use Akernel_User.Syscalls;
   use type U64;

   Status            : U64;
   Got_Label         : U64;
   Got_Badge         : U64;
   Got_Words         : IPC_Word_Array;
   Got_Caps          : IPC_Cap_Array;
   Prev_Double_Reply : U64 := 0;
   Rounds            : Natural := 0;
begin
   Debug_Put_Line ("echo online");

   loop
      Status := IPC_Recv (1);
      exit when Status /= IPC_Ok;

      Got_Label := Message.Label;
      Got_Words := Message.Words;
      Got_Caps  := Message.Caps;
      Got_Badge := Message.Badge;

      Message.Label := Got_Label;
      if Rounds = 2 then
         Message.Words := (others => 0);
         Message.Words (0) := Got_Badge;
         Message.Words (1) := Got_Caps (0);
      else
         Message.Words (0) := Got_Badge;
         for Index in 1 .. 4 loop
            Message.Words (Index) := Got_Words (Index - 1);
         end loop;
         Message.Words (5) := Prev_Double_Reply;
      end if;
      Message.Caps := (others => 0);

      Status := IPC_Reply;
      exit when Status /= IPC_Ok;

      --  One-shot check: replying again with no pending caller must
      --  fail; surfaced to the fuzzer in the next round's word 5.
      Prev_Double_Reply := IPC_Reply;

      Rounds := Rounds + 1;
      exit when Rounds = 3;
   end loop;

   if Status = IPC_Ok then
      Debug_Put_Line ("echo done");
   else
      Debug_Put_Line ("echo error exit");
   end if;

   Process_Exit;
end Echo;
