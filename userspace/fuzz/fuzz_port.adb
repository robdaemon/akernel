with Ada.Real_Time;
with System;
with System.Machine_Code;
with System.Storage_Elements;
with Akernel_User.Console;
with Akernel_User.Syscalls;

package body Fuzz_Port is
   use Akernel_User.Syscalls;
   use type U64;

   Port_VA : constant U64 := 16#5070_0000#;  --  free fuzz window
   Msgs_Per_Worker : constant U64 := 50;

   --  All state is static: workers are library-level tasks and the
   --  fuzz main frame is stack-constrained.
   Sink_EP   : U64 := 0;
   Page_Cap  : U64 := 0;
   P         : Trinket.App_Port.Port;

   --  Gates: each worker creates its own gate notification at task
   --  start (caps are process-wide), publishes the handle, then
   --  blocks in Ntfn_Wait — workers burn no CPU while idle, which
   --  keeps the rest of the suite's timing untouched. The main
   --  thread signals a gate to release a phase: bit 1 = first
   --  batch, bit 2 = second batch (worker A only).
   Gate_A    : U64 := 0 with Volatile;
   Gate_B    : U64 := 0 with Volatile;
   Done_A    : U64 := 0 with Volatile;  --  batches completed
   Done_B    : U64 := 0 with Volatile;
   Post_Fail_A : U64 := 0 with Volatile;
   Post_Fail_B : U64 := 0 with Volatile;

   --  Watchdog: while armed, ticks every 0.5 s and signals the
   --  bound ntfn with bit 8, so a main thread blocked in IPC_Recv
   --  wakes, finds nothing new, and re-checks its deadline. Turns
   --  a broken wake path into FAILs instead of a suite hang.
   Watchdog_Ntfn : U64 := 0 with Volatile;
   Watchdog_Arm  : Boolean := False with Volatile;
   Watchdog_Done : Boolean := False with Volatile;

   --  Main-thread-only collection state (Drain is single-consumer).
   Got      : array (1 .. 2) of U64 := (others => 0);
   Next_Seq : array (1 .. 2) of U64 := (others => 0);
   Bad      : U64 := 0;

   function Pattern (Tag, Seq : U64) return U64 is
     (Tag * 16#A500_0000# + Seq);

   procedure Collect (Code, A0, A1, A2 : U64) is
   begin
      if Code /= 1 or else A0 not in 1 .. 2 then
         Bad := Bad + 1;
         return;
      end if;
      if A1 /= Next_Seq (Integer (A0))
        or else A2 /= Pattern (A0, A1)
      then
         Bad := Bad + 1;
      end if;
      Next_Seq (Integer (A0)) := A1 + 1;
      Got (Integer (A0)) := Got (Integer (A0)) + 1;
   end Collect;

   procedure Post_Batch (Tag : U64; Fail_Count : in out U64) is
   begin
      for I in 0 .. Msgs_Per_Worker - 1 loop
         if not Trinket.App_Port.Post
                  (P, 1, Tag, I, Pattern (Tag, I))
         then
            Fail_Count := Fail_Count + 1;
         end if;
      end loop;
   end Post_Batch;

   task Worker_A;
   task Worker_B;

   task body Worker_A is
      Bits : U64;
   begin
      Gate_A := Ntfn_Create;
      loop
         Bits := Ntfn_Wait (Gate_A);
         if Bits = Syscall_Failed then
            Post_Fail_A := Post_Fail_A + 16#FFFF#;  --  gate broken
            exit;
         end if;
         if (Bits and 1) /= 0 then
            Post_Batch (1, Post_Fail_A);
         end if;
         if (Bits and 2) /= 0 then
            Post_Batch (1, Post_Fail_A);
         end if;
         System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
         Done_A := Done_A + 1;
         exit when (Bits and 2) /= 0;
      end loop;
   end Worker_A;

   task body Worker_B is
      Bits : U64;
   begin
      Gate_B := Ntfn_Create;
      Bits := Ntfn_Wait (Gate_B);
      if Bits = Syscall_Failed then
         Post_Fail_B := Post_Fail_B + 16#FFFF#;
      else
         Post_Batch (2, Post_Fail_B);
      end if;
      System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
      Done_B := 1;
   end Worker_B;

   task Watchdog;

   task body Watchdog is
      Ignore : U64;
   begin
      loop
         Ignore := Sleep_Until (Read_Time + 5_000_000);  --  0.5 s
         exit when not Watchdog_Arm;
         if Watchdog_Ntfn /= 0 then
            Ignore := Ntfn_Signal (Watchdog_Ntfn, 8);
         end if;
      end loop;
      System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
      Watchdog_Done := True;
   end Watchdog;

   Drained : U64 := 0;

   procedure Count_Only (Code, A0, A1, A2 : U64) is
      pragma Unreferenced (Code, A0, A1, A2);
   begin
      Drained := Drained + 1;
   end Count_Only;

   procedure Check (Condition : Boolean; Label_Text : String) is
   begin
      if Condition then
         Akernel_User.Console.Put ("PASS ");
      else
         Akernel_User.Console.Put ("FAIL ");
      end if;
      Akernel_User.Console.Put_Line (Label_Text);
   end Check;

   --  Drain once per wake until Want messages collected (or the
   --  deadline passes). Returns False on timeout — a missed wake
   --  would show up here.
   function Collect_Until (Want : U64) return Boolean is
      use Ada.Real_Time;
      Deadline  : constant Time := Clock + Seconds (10);
      Reply_H   : U64;
      Quit_Seen : Boolean;
      Woke_With_Bit : Boolean := False;
   begin
      while Got (1) + Got (2) < Want and then Clock <= Deadline loop
         if IPC_Recv (Sink_EP, Reply_H) /= IPC_Ok then
            return False;
         end if;
         if Message.Label = Notification_Label
           and then (Message.Words (0)
                     and Trinket.App_Port.App_Signal_Bit) /= 0
         then
            Woke_With_Bit := True;
         end if;
         Trinket.App_Port.Drain (P, Collect'Access, Quit_Seen);
      end loop;
      Check (Woke_With_Bit, "app port wakes recv with app bit");
      Check (not Quit_Seen, "app port no stray quit");
      return Got (1) + Got (2) >= Want;
   end Collect_Until;

   procedure Await_Count (N : U64; Label_Text : String) is
      use Ada.Real_Time;
      Deadline : constant Time := Clock + Seconds (10);
   begin
      while Done_A + Done_B < N and then Clock <= Deadline loop
         System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
         Yield;
      end loop;
      Check (Done_A + Done_B >= N, Label_Text);
   end Await_Count;

   procedure Run_Tests (Bound_Ntfn : U64) is
      use System.Storage_Elements;
      use Ada.Real_Time;
      Result     : U64;
      Quit_Seen  : Boolean;
      Posts_Ok   : U64 := 0;
      Gate_Deadline : Time;

   begin
      Sink_EP := EP_Create;
      Check (Sink_EP /= Syscall_Failed, "app port endpoint created");
      Check (Bound_Ntfn /= 0, "app port reuses bound ntfn");

      Page_Cap := Mem_Alloc (1);
      Check (Page_Cap /= Syscall_Failed, "app port page allocated");
      Result := Mem_Map
        (Address_Space => Address_Space_Cap,
         Cap           => Page_Cap,
         VA            => Port_VA,
         Offset        => 0,
         Length        => 4096,
         Flags         => 3);
      Check (Result = 0, "app port page mapped");
      Trinket.App_Port.Setup
        (P, System.Storage_Elements.To_Address
           (Integer_Address (Port_VA)), Bound_Ntfn);

      --  Arm the watchdog so a broken wake path yields FAILs
      --  instead of hanging the suite.
      Watchdog_Ntfn := Bound_Ntfn;
      System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
      Watchdog_Arm := True;

      --  Workers publish their gate caps at task start; they may
      --  not have been scheduled yet (SMP).
      Gate_Deadline := Clock + Seconds (10);
      while (Gate_A = 0 or else Gate_B = 0)
        and then Clock <= Gate_Deadline
      loop
         System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
         Yield;
      end loop;
      Check (Gate_A /= 0 and then Gate_B /= 0,
             "app port worker gates ready");

      --  Phase 1: single worker, exercises the wake path.
      Result := Ntfn_Signal (Gate_A, 1);
      Check (Collect_Until (Msgs_Per_Worker),
             "app port single producer delivered");
      Check (Bad = 0, "app port single producer in order");
      Check (Post_Fail_A = 0, "app port single producer no drops");
      Await_Count (1, "app port worker A finished");

      --  Phase 2: two concurrent workers.
      Got      := (others => 0);
      Next_Seq := (others => 0);
      Bad      := 0;
      Result := Ntfn_Signal (Gate_A, 2);
      Result := Ntfn_Signal (Gate_B, 1);
      Check (Collect_Until (2 * Msgs_Per_Worker),
             "app port two producers delivered");
      Check (Bad = 0, "app port two producers per-sender order");
      Check (Post_Fail_A + Post_Fail_B = 0,
             "app port two producers no drops");
      Await_Count (2, "app port worker B finished");

      --  Phase 3: same-thread posts fill the ring; drop-new past
      --  capacity (workers are done, no concurrent producers).
      Got      := (others => 0);
      Next_Seq := (others => 0);
      Bad      := 0;
      for I in 1 .. Trinket.App_Port.Max_Events + 10 loop
         if Trinket.App_Port.Post (P, 1, 1, I, Pattern (1, I)) then
            Posts_Ok := Posts_Ok + 1;
         end if;
      end loop;
      Check (Posts_Ok = Trinket.App_Port.Max_Events,
             "app port full ring drops new");
      Trinket.App_Port.Drain (P, Count_Only'Access, Quit_Seen);
      Check (Drained = Trinket.App_Port.Max_Events,
             "app port full ring drains all");
      Check (not Quit_Seen, "app port full ring no quit");

      --  Phase 4: reserved quit code reaches Drain as Quit_Seen,
      --  not as a callback message.
      Drained := 0;
      Check (Trinket.App_Port.Post
               (P, Trinket.App_Port.App_Code_Quit, 0, 0, 0),
             "app port quit posted");
      Trinket.App_Port.Drain (P, Count_Only'Access, Quit_Seen);
      Check (Quit_Seen, "app port quit seen");
      Check (Drained = 0, "app port quit not dispatched");

      --  Teardown: stop the watchdog first so no signal is in
      --  flight, then clear pending bits: posts signalled the
      --  bound ntfn with App_Signal_Bit and a later section's
      --  IPC_Recv must not see a stray synthetic wake. The bound
      --  ntfn itself is NOT deleted (the main thread stays bound).
      Watchdog_Arm := False;
      System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
      declare
         WD_Deadline : constant Time := Clock + Seconds (5);
      begin
         while not Watchdog_Done and then Clock <= WD_Deadline loop
            Yield;
         end loop;
      end;
      Check (Watchdog_Done, "app port watchdog stopped");
      Result := Ntfn_Signal (Bound_Ntfn, 8);
      Result := Ntfn_Wait (Bound_Ntfn);
      Check (Result /= Syscall_Failed, "app port ntfn bits drained");
      Result := Mem_Unmap (Address_Space_Cap, Port_VA, 4096);
      Result := Cap_Delete (Page_Cap);
      Result := Cap_Delete (Sink_EP);
   end Run_Tests;

end Fuzz_Port;
