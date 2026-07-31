with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Console;
with Akernel_User.IPC;
with Akernel_User.Streams;

--  Syscall argument fuzzer.  Exercises every syscall with edge-case and
--  pseudo-random argument values and verifies the kernel stays alive and
--  keeps returning clean status codes.  Runs as a manifest-spawned user
--  process granted the ipc_test endpoint (handle 1, badge 0xEC40), the
--  console endpoint Send cap (handle 2) and the Tests/Echo
--  Boot_File_Object image cap (handle 3).  Test output goes through
--  the console server (Akernel_User.Console over the endpoint stream);
--  the random phase still hits the raw debug_putchar syscall as a
--  fuzz target.
--
--  NOTE: spawn consumes Boot_File_Object image caps (spawn ABI v2).
--  The fuzzer deliberately never forms a valid image cap in the
--  random phase (a0 forced to 0) so it cannot recursively spawn.

procedure Fuzz is
   subtype U64 is Interfaces.Unsigned_64;
   use type U64;

   --  A0..A5 default to 0: named association at call sites states
   --  only the arguments a syscall actually takes.
   function Raw_Ecall
     (Number : U64;
      A0     : U64 := 0;
      A1     : U64 := 0;
      A2     : U64 := 0;
      A3     : U64 := 0;
      A4     : U64 := 0;
      A5     : U64 := 0) return U64
     with Import, Convention => C, External_Name => "fuzz_ecall";

   Last_A1 : U64
     with Import, Convention => C, External_Name => "fuzz_last_a1",
          Volatile;

   Sys_Yield          : constant U64 := 0;
   Sys_Debug_Putchar  : constant U64 := 1;
   Sys_Map_MMIO       : constant U64 := 2;
   Sys_IRQ_Wait       : constant U64 := 3;
   Sys_IRQ_Ack        : constant U64 := 4;
   Sys_Boot_File_Size : constant U64 := 6;
   Sys_Boot_Read_Byte : constant U64 := 7;
   Sys_Spawn          : constant U64 := 8;
   Sys_Exit           : constant U64 := 9;
   Sys_Reap           : constant U64 := 10;
   Sys_EP_Create      : constant U64 := 11;
   Sys_IPC_Call       : constant U64 := 12;
   Sys_IPC_Recv       : constant U64 := 13;
   Sys_IPC_Reply      : constant U64 := 14;
   Sys_Mem_Alloc      : constant U64 := 15;
   Sys_Mem_Map        : constant U64 := 16;
   Sys_Mem_Unmap      : constant U64 := 17;

   Highest_Known      : constant U64 := 17;

   Failed : constant U64 := U64'Last;

   --  xorshift64 PRNG, deterministic seed.
   State : U64 := 16#9E37_79B9_7F4A_7C15#;

   function Next_Random return U64 is
      X : U64 := State;
   begin
      X := X xor Interfaces.Shift_Left (X, 13);
      X := X xor Interfaces.Shift_Right (X, 7);
      X := X xor Interfaces.Shift_Left (X, 17);
      State := X;
      return X;
   end Next_Random;

   procedure Put (S : String) is
   begin
      Akernel_User.Console.Put (S);
   end Put;

   procedure Put_Line (S : String) is
   begin
      Akernel_User.Console.Put_Line (S);
   end Put_Line;

   Hex_Digits : constant String := "0123456789abcdef";

   procedure Put_Hex (Value : U64) is
      S : String (1 .. 18);
   begin
      S (1) := '0';
      S (2) := 'x';
      for Shift in reverse 0 .. 15 loop
         declare
            Nibble : constant U64 :=
              Interfaces.Shift_Right (Value, Shift * 4) and 16#F#;
         begin
            S (3 + (15 - Shift)) := Hex_Digits (Natural (Nibble) + 1);
         end;
      end loop;
      Put (S);
   end Put_Hex;

   --  Edge-case argument pool.
   Edge_Pool : constant array (1 .. 14) of U64 :=
     (0,
      1,
      2,
      16#FF#,               --  cap handle bound / byte bound
      16#100#,              --  first invalid cap handle
      16#FFF#,              --  page - 1
      16#1000#,             --  page
      16#7FFF_FFFF#,        --  low canonical bound
      16#8000_0000#,
      16#FFFF_FFFF#,
      16#1_0000_0000#,
      16#7FFF_FFFF_FFFF_FFFF#,
      16#8000_0000_0000_0000#,
      16#FFFF_FFFF_FFFF_FFFF#);

   function Arg_Value return U64 is
      R : constant U64 := Next_Random;
   begin
      if (R and 3) = 0 then
         return Edge_Pool (Natural (Interfaces.Shift_Right (R, 8)
                                    and 16#F#) mod Edge_Pool'Length + 1);
      else
         return Next_Random;
      end if;
   end Arg_Value;

   Total_Calls   : U64 := 0;
   Unknown_Count : U64 := 0;
   Failures      : U64 := 0;

   procedure Check (Condition : Boolean; Label_Text : String) is
   begin
      if Condition then
         Put ("PASS ");
      else
         Put ("FAIL ");
         Failures := Failures + 1;
      end if;
      Put_Line (Label_Text);
   end Check;

   Status   : U64;
   Number   : U64;
   A0, A1, A2, A3, A4, A5 : U64;

   --  End-to-end IPC state.
   EP, EP2       : U64;
   Echo_Process  : U64;
   Reaped        : Boolean;
   Ignore        : U64;

   --  Granted caps: ipc_test endpoint at handle 1, console Send cap
   --  at handle 2, Tests/Echo image cap at handle 3.
   Console_EP : constant U64 := 2;
   Echo_Image : constant U64 := 3;

   package Console_RPC is new Akernel_User.IPC
     (Akernel_User.Streams.Stream_Request,
      Akernel_User.Streams.Stream_Response);

   Console_Request  : Akernel_User.Streams.Stream_Request;
   Console_Response : Akernel_User.Streams.Stream_Response;
   Reply_Label      : U64;
   Mem_Cap          : U64;

   Iterations : constant U64 := 4096;
begin
   Akernel_User.Console.Set_Endpoint (Console_EP);
   Put_Line ("fuzz online");

   --  Directed cases first.

   --  Unknown syscall numbers must return Failed.
   Status := Raw_Ecall (Number => 18);
   Check (Status = Failed, "unknown syscall 18 rejected");
   Status := Raw_Ecall
     (Number => 255, A0 => 1, A1 => 2, A2 => 3,
      A3 => 4, A4 => 5, A5 => 6);
   Check (Status = Failed, "unknown syscall 255 rejected");
   Status := Raw_Ecall (Number => U64'Last);
   Check (Status = Failed, "unknown syscall max rejected");

   --  ep_create returns fresh distinct endpoint cap handles.
   Status := Raw_Ecall (Number => Sys_EP_Create);
   Check (Status /= Failed and then Status < 256, "ep_create returns handle");
   A0 := Raw_Ecall (Number => Sys_EP_Create);
   Check (A0 /= Failed and then A0 /= Status, "ep_create distinct handles");

   --  IPC syscall argument validation (non-blocking cases only).
   Status := Raw_Ecall (Number => Sys_IPC_Call, A0 => 16#100#);
   Check (Status = 1, "ipc_call invalid cap rejected");
   Status := Raw_Ecall (Number => Sys_IPC_Recv, A0 => U64'Last);
   Check (Status = 1, "ipc_recv invalid cap rejected");
   Status := Raw_Ecall (Number => Sys_IPC_Reply, A0 => 254);
   Check (Status = 1, "ipc_reply without reply cap rejected");
   Status := Raw_Ecall (Number => Sys_IPC_Reply, A0 => 200);
   Check (Status = 1, "ipc_reply wrong handle rejected");

   --  Console stream RPC: a write op must round-trip through the
   --  console server and report the byte count consumed.
   Console_Request := (Count => 1, Data => (others => 0));
   Console_Request.Data (1) := Character'Pos ('.');
   Status := Console_RPC.Call
     (Console_EP, Akernel_User.Streams.Op_Write, Console_Request,
      Console_RPC.No_Caps, Reply_Label, Console_Response);
   Check (Status = 0 and then Console_Response.Count = 1,
          "console write rpc round-trips");
   --  A read op on the output-only console yields EOF (count 0).
   Console_Request := (Count => 4, Data => (others => 0));
   Status := Console_RPC.Call
     (Console_EP, Akernel_User.Streams.Op_Read, Console_Request,
      Console_RPC.No_Caps, Reply_Label, Console_Response);
   Check (Status = 0 and then Console_Response.Count = 0,
          "console read reports eof");

   --  Memory objects: alloc/map/touch/unmap of borrowed frames.
   --  The object stays allocated until this process exits, which
   --  also exercises the refcounted frame teardown path.
   declare
      Mem_VA : constant U64 := 16#5000_0000#;
      AS     : constant U64 := Akernel_User.Syscalls.Address_Space_Cap;

      type Page_Words is array (0 .. 511) of U64;
      Mapped : Page_Words
        with Volatile, Address =>
          System'To_Address
            (System.Storage_Elements.Integer_Address (Mem_VA));
   begin
      Mem_Cap := Raw_Ecall (Number => Sys_Mem_Alloc, A0 => 1);
      Check (Mem_Cap /= U64'Last, "mem_alloc returns handle");
      Check (Raw_Ecall (Number => Sys_Mem_Alloc, A0 => 0) = U64'Last,
             "mem_alloc zero pages rejected");
      Check (Raw_Ecall (Number => Sys_Mem_Alloc, A0 => 65) = U64'Last,
             "mem_alloc over max pages rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Map, A0 => AS, A1 => 200,
                A2 => Mem_VA, A3 => 0, A4 => 4096, A5 => 3) = 1,
             "mem_map invalid cap rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Map, A0 => AS, A1 => Mem_Cap,
                A2 => Mem_VA + 1, A3 => 0, A4 => 4096, A5 => 3) = 1,
             "mem_map unaligned va rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Map, A0 => AS, A1 => Mem_Cap,
                A2 => Mem_VA, A3 => 4096, A4 => 4096, A5 => 3) = 1,
             "mem_map beyond object rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Map, A0 => AS, A1 => Mem_Cap,
                A2 => Mem_VA, A3 => 0, A4 => 4096, A5 => 2) = 1,
             "mem_map write-only rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Map, A0 => AS, A1 => Mem_Cap,
                A2 => Mem_VA, A3 => 0, A4 => 4096, A5 => 3) = 0,
             "mem_map rw page maps");
      Mapped (0) := 16#DEAD_BEEF#;
      Check (Mapped (0) = 16#DEAD_BEEF# and then Mapped (511) = 0,
             "memory object page writable and zeroed");
      Check (Raw_Ecall
               (Number => Sys_Mem_Unmap, A0 => AS,
                A1 => Mem_VA, A2 => 4096) = 0,
             "mem_unmap drops mapping");
      Check (Raw_Ecall
               (Number => Sys_Mem_Unmap, A0 => AS,
                A1 => Mem_VA, A2 => 4096) = 1,
             "mem_unmap twice rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Unmap, A0 => AS,
                A1 => Akernel_User.Syscalls.IPC_Buffer_VA,
                A2 => 4096) = 1,
             "mem_unmap refuses owned pages");
   end;

   --  Boot byte API probes: valid image cap, huge offset, invalid
   --  handle, wrong-kind cap (handle 1 is the granted endpoint).
   Status := Raw_Ecall (Number => Sys_Boot_File_Size, A0 => Echo_Image);
   Check (Status /= Failed, "image cap size query works");
   Status := Raw_Ecall
     (Number => Sys_Boot_Read_Byte, A0 => Echo_Image, A1 => U64'Last);
   Check (Status = 256 or else Status = Failed, "huge read offset safe");
   Status := Raw_Ecall (Number => Sys_Boot_File_Size, A0 => U64'Last);
   Check (Status = Failed, "invalid boot cap rejected");
   Status := Raw_Ecall (Number => Sys_Boot_File_Size, A0 => 1);
   Check (Status = Failed, "boot byte api wrong-kind cap rejected");

   --  Invalid cap handles on cap-taking syscalls.
   Status := Raw_Ecall (Number => Sys_IRQ_Wait, A0 => 16#100#);
   Check (Status /= 0, "irq_wait invalid cap rejected");
   Status := Raw_Ecall (Number => Sys_IRQ_Ack, A0 => U64'Last);
   Check (Status /= 0, "irq_ack invalid cap rejected");
   Status := Raw_Ecall (Number => Sys_Reap, A0 => 16#FEED_BEEF#);
   Check (Status /= 0, "reap invalid cap rejected");
   Status := Raw_Ecall
     (Number => Sys_Map_MMIO, A0 => 255, A1 => U64'Last,
      A4 => 16#1000#, A5 => 3);
   Check (Status /= 0, "map_mmio invalid mmio cap rejected");
   Status := Raw_Ecall
     (Number => Sys_Map_MMIO, A0 => 16#100#, A1 => 1,
      A4 => 16#1000#, A5 => 3);
   Check (Status /= 0, "map_mmio invalid as cap rejected");

   --  Spawn with invalid image caps (spawn ABI v2: a0 = image cap).
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => 0);
   Check (Status /= 0, "spawn null image cap rejected");
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => U64'Last);
   Check (Status /= 0, "spawn huge image cap rejected");
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => 1);
   Check (Status /= 0, "spawn wrong-kind image cap rejected");

   ----------------------------------------------------------------
   --  End-to-end IPC: spawn the echo server with a granted
   --  endpoint, ping-pong three rounds (badge, round-trip, one-shot
   --  reply cap, cap transfer), then reap the exited child.
   ----------------------------------------------------------------

   --  Endpoint granted by init at handle 1 with badge 0xEC40
   --  (session-manager badge pattern); messages sent through it
   --  arrive at echo stamped with that badge.
   EP := 1;

   --  Grant-list validation: unopened source handle.
   Akernel_User.Syscalls.Set_Grant (0, 250, 0, 0);
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => Echo_Image, A1 => 1);
   Check (Status = 4, "spawn grant of unopened cap rejected");

   --  Rights escalation: endpoints carry no Read right.
   Akernel_User.Syscalls.Set_Grant
     (0, EP, Akernel_User.Syscalls.Right_Read, 0);
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => Echo_Image, A1 => 1);
   Check (Status = 4, "spawn grant rights escalation rejected");

   --  Rights mask bits outside the valid set.
   Akernel_User.Syscalls.Set_Grant (0, EP, 16#400#, 0);
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => Echo_Image, A1 => 1);
   Check (Status = 4, "spawn grant unknown rights bits rejected");

   --  Grant count above the ABI limit.
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => Echo_Image, A1 => 33);
   Check (Status = 4, "spawn grant count over limit rejected");

   --  Valid grant: endpoint with Send+Receive (badged cap stays
   --  with the fuzzer; echo's own badge is irrelevant) plus the
   --  console Send cap so echo can print.
   Akernel_User.Syscalls.Set_Grant
     (0, EP,
      Akernel_User.Syscalls.Right_Send + Akernel_User.Syscalls.Right_Receive,
      0);
   Akernel_User.Syscalls.Set_Grant
     (1, Console_EP, Akernel_User.Syscalls.Right_Send, 0);
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => Echo_Image, A1 => 2);
   --  fuzz_last_a1 is rewritten by every ecall: capture the process
   --  cap before Check (or anything else) makes another syscall.
   Echo_Process := Last_A1;
   Check (Status = 0 and then Echo_Process /= 0,
          "echo spawned with granted endpoint");

   --  Round 1: badge + round-trip + first double-reply marker.
   --  NB: the reply is copied out of the IPC buffer before any
   --  Check, because Check prints through the console stream, which
   --  itself round-trips through this thread's message buffer.
   Akernel_User.Syscalls.Message.Label := 16#AB#;
   Akernel_User.Syscalls.Message.Words := (1, 2, 3, 4, 5, 6);
   Akernel_User.Syscalls.Message.Caps := (others => 0);
   Status := Raw_Ecall (Number => Sys_IPC_Call, A0 => EP);
   declare
      R_Label : constant U64 := Akernel_User.Syscalls.Message.Label;
      R_Words : constant Akernel_User.Syscalls.IPC_Word_Array :=
        Akernel_User.Syscalls.Message.Words;
   begin
      Check (Status = 0, "echo call round 1 returned ok");
      Check (R_Label = 16#AB#, "echo round 1 label round-trips");
      Check (R_Words (0) = 16#EC40#, "echo round 1 badge delivered");
      Check (R_Words (1) = 1 and then R_Words (4) = 4,
             "echo round 1 words round-trip");
      Check (R_Words (5) = 0, "echo round 1 first-reply marker");
   end;

   --  Round 2: word 5 must carry the failed double-reply code (1).
   Akernel_User.Syscalls.Message.Label := 16#CD#;
   Akernel_User.Syscalls.Message.Words := (6, 5, 4, 3, 2, 1);
   Akernel_User.Syscalls.Message.Caps := (others => 0);
   Status := Raw_Ecall (Number => Sys_IPC_Call, A0 => EP);
   declare
      R_Words : constant Akernel_User.Syscalls.IPC_Word_Array :=
        Akernel_User.Syscalls.Message.Words;
   begin
      Check (Status = 0, "echo call round 2 returned ok");
      Check (R_Words (0) = 16#EC40# and then R_Words (1) = 6,
             "echo round 2 payload");
      Check (R_Words (5) = 1,
             "echo double reply rejected (one-shot cap)");
   end;

   --  Round 3: cap transfer. EP2's handle is rewritten into echo's
   --  table (first free handle there = 3: endpoint at 1, console at
   --  2); echo reports it.
   EP2 := Raw_Ecall (Number => Sys_EP_Create);
   Check (EP2 < 256 and then EP2 /= EP, "second endpoint created");
   Akernel_User.Syscalls.Message.Label := 16#EF#;
   Akernel_User.Syscalls.Message.Words := (others => 0);
   Akernel_User.Syscalls.Message.Caps := (EP2, 0, 0, 0);
   Status := Raw_Ecall (Number => Sys_IPC_Call, A0 => EP);
   declare
      R_Words : constant Akernel_User.Syscalls.IPC_Word_Array :=
        Akernel_User.Syscalls.Message.Words;
   begin
      Check (Status = 0, "echo call round 3 returned ok");
      Check (R_Words (0) = 16#EC40#, "echo round 3 badge delivered");
      Check (R_Words (1) = 3,
             "cap transferred and rewritten to echo handle 3");
   end;

   --  Echo exits after three rounds; reap it once it has exited.
   Reaped := False;
   for Try in 1 .. 128 loop
      Status := Raw_Ecall (Number => Sys_Reap, A0 => Echo_Process);
      if Status = 0 then
         Reaped := True;
         exit;
      end if;
      Ignore := Raw_Ecall (Number => Sys_Yield);
   end loop;
   Check (Reaped, "echo reaped after exit");

   --  Random phase: every syscall except exit (9).  Spawn's image
   --  cap forced to 0 so no spawn can succeed.  debug_putchar bytes
   --  constrained to printable to keep the log readable.
   while Total_Calls < Iterations loop
      Number := Next_Random mod 16;
      if (Next_Random and 16#F#) = 0 then
         Number := Next_Random;  --  occasionally a huge syscall number
      end if;

      --  Skip exit (9) and the blocking IPC trio (12-14): a random
      --  call/recv with no peer would block this thread forever.
      --  Directed IPC coverage is a separate milestone.
      if Number /= Sys_Exit
        and then Number /= Sys_IPC_Call
        and then Number /= Sys_IPC_Recv
        and then Number /= Sys_IPC_Reply
      then
         A0 := Arg_Value;
         A1 := Arg_Value;
         A2 := Arg_Value;
         A3 := Arg_Value;
         A4 := Arg_Value;
         A5 := Arg_Value;

         if Number = Sys_Debug_Putchar then
            A0 := 16#20# + (A0 mod 16#5F#);
         elsif Number = Sys_Spawn then
            A0 := 0;
         end if;

         Status := Raw_Ecall
           (Number => Number, A0 => A0, A1 => A1, A2 => A2,
            A3 => A3, A4 => A4, A5 => A5);
         Total_Calls := Total_Calls + 1;
         if Number > Highest_Known and then Status = Failed then
            Unknown_Count := Unknown_Count + 1;
         end if;

         if (Total_Calls mod 1024) = 0 then
            Put ("fuzz ");
            Put_Hex (Total_Calls);
            Put_Line ("");
         end if;
      end if;
   end loop;

   --  Kernel still answers correctly after the random phase.
   Status := Raw_Ecall (Number => Sys_Boot_File_Size, A0 => Echo_Image);
   Check (Status /= Failed, "kernel alive after random phase");

   Put ("fuzz complete: calls=");
   Put_Hex (Total_Calls);
   Put (" unknowns=");
   Put_Hex (Unknown_Count);
   Put (" failures=");
   Put_Hex (Failures);
   Put_Line ("");

   --  Exit path is the final test: this thread must die cleanly and the
   --  system (init, serial driver, timer) must keep running.
   Put_Line ("fuzz exit test");
   Status := Raw_Ecall (Number => Sys_Exit);

   --  Reaching here means exit returned, which it never should.
   Put_Line ("FAIL exit returned");
end Fuzz;
