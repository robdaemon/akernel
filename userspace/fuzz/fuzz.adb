with Interfaces;
with Akernel_User.Syscalls;

--  Syscall argument fuzzer.  Exercises every syscall with edge-case and
--  pseudo-random argument values and verifies the kernel stays alive and
--  keeps returning clean status codes.  Runs as a manifest-spawned user
--  process with no grants.
--
--  NOTE: spawn_boot_path/boot_file_* target the temporary boot-manifest
--  ABI; both go away when the VFS lands.  The fuzzer deliberately never
--  forms a resolvable boot path (random-phase path length is forced to
--  0) so it cannot recursively spawn itself.

procedure Fuzz is
   subtype U64 is Interfaces.Unsigned_64;
   use type U64;

   function Raw_Ecall
     (Number : U64;
      A0     : U64;
      A1     : U64;
      A2     : U64;
      A3     : U64;
      A4     : U64;
      A5     : U64) return U64
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

   Highest_Known      : constant U64 := 14;

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
      for C of S loop
         declare
            Ignore : U64;
         begin
            Ignore := Raw_Ecall
              (Sys_Debug_Putchar, U64 (Character'Pos (C)), 0, 0, 0, 0, 0);
         end;
      end loop;
   end Put;

   procedure Put_Line (S : String) is
   begin
      Put (S);
      declare
         Ignore : U64;
      begin
         Ignore := Raw_Ecall
           (Sys_Debug_Putchar, U64 (Character'Pos (Character'Val (10))),
            0, 0, 0, 0, 0);
      end;
   end Put_Line;

   Hex_Digits : constant String := "0123456789abcdef";

   procedure Put_Hex (Value : U64) is
      Ignore : U64;
   begin
      Put ("0x");
      for Shift in reverse 0 .. 15 loop
         declare
            Nibble : constant U64 :=
              Interfaces.Shift_Right (Value, Shift * 4) and 16#F#;
         begin
            Ignore := Raw_Ecall
              (Sys_Debug_Putchar,
               U64 (Character'Pos (Hex_Digits (Natural (Nibble) + 1))),
               0, 0, 0, 0, 0);
         end;
      end loop;
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
   Echo_Offset   : U64;
   Echo_Process  : U64;
   Manifest_Size : U64;
   Match         : Natural;
   Reaped        : Boolean;
   Ignore        : U64;

   Echo_Path : constant String := "Tests/Echo";

   Iterations : constant U64 := 4096;
begin
   Put_Line ("fuzz online");

   --  Directed cases first.

   --  Unknown syscall numbers must return Failed.
   Status := Raw_Ecall (15, 0, 0, 0, 0, 0, 0);
   Check (Status = Failed, "unknown syscall 15 rejected");
   Status := Raw_Ecall (255, 1, 2, 3, 4, 5, 6);
   Check (Status = Failed, "unknown syscall 255 rejected");
   Status := Raw_Ecall (U64'Last, 0, 0, 0, 0, 0, 0);
   Check (Status = Failed, "unknown syscall max rejected");

   --  ep_create returns fresh distinct endpoint cap handles.
   Status := Raw_Ecall (Sys_EP_Create, 0, 0, 0, 0, 0, 0);
   Check (Status /= Failed and then Status < 256, "ep_create returns handle");
   A0 := Raw_Ecall (Sys_EP_Create, 0, 0, 0, 0, 0, 0);
   Check (A0 /= Failed and then A0 /= Status, "ep_create distinct handles");

   --  IPC syscall argument validation (non-blocking cases only).
   Status := Raw_Ecall (Sys_IPC_Call, 16#100#, 0, 0, 0, 0, 0);
   Check (Status = 1, "ipc_call invalid cap rejected");
   Status := Raw_Ecall (Sys_IPC_Recv, U64'Last, 0, 0, 0, 0, 0);
   Check (Status = 1, "ipc_recv invalid cap rejected");
   Status := Raw_Ecall (Sys_IPC_Reply, 254, 0, 0, 0, 0, 0);
   Check (Status = 1, "ipc_reply without reply cap rejected");
   Status := Raw_Ecall (Sys_IPC_Reply, 200, 0, 0, 0, 0, 0);
   Check (Status = 1, "ipc_reply wrong handle rejected");

   --  Boot file probes: valid file, past-EOF and huge offsets.
   Status := Raw_Ecall (Sys_Boot_File_Size, 1, 0, 0, 0, 0, 0);
   Check (Status /= Failed, "manifest size query works");
   Status := Raw_Ecall (Sys_Boot_Read_Byte, 1, U64'Last, 0, 0, 0, 0);
   Check (Status = 256 or else Status = Failed, "huge read offset safe");
   Status := Raw_Ecall (Sys_Boot_File_Size, U64'Last, 0, 0, 0, 0, 0);
   Check (Status = Failed, "invalid file id rejected");

   --  Invalid cap handles on cap-taking syscalls.
   Status := Raw_Ecall (Sys_IRQ_Wait, 16#100#, 0, 0, 0, 0, 0);
   Check (Status /= 0, "irq_wait invalid cap rejected");
   Status := Raw_Ecall (Sys_IRQ_Ack, U64'Last, 0, 0, 0, 0, 0);
   Check (Status /= 0, "irq_ack invalid cap rejected");
   Status := Raw_Ecall (Sys_Reap, 16#FEED_BEEF#, 0, 0, 0, 0, 0);
   Check (Status /= 0, "reap invalid cap rejected");
   Status := Raw_Ecall
     (Sys_Map_MMIO, 255, U64'Last, 0, 0, 16#1000#, 3);
   Check (Status /= 0, "map_mmio invalid mmio cap rejected");
   Status := Raw_Ecall
     (Sys_Map_MMIO, 16#100#, 1, 0, 0, 16#1000#, 3);
   Check (Status /= 0, "map_mmio invalid as cap rejected");

   --  Spawn with unresolvable boot paths (bootstrap ABI).
   Status := Raw_Ecall (Sys_Spawn, 0, 0, 0, 0, 0, 0);
   Check (Status /= 0, "spawn empty path rejected");
   Status := Raw_Ecall (Sys_Spawn, U64'Last - 8, 16, 0, 0, 0, 0);
   Check (Status /= 0, "spawn past-eof path rejected");
   Status := Raw_Ecall (Sys_Spawn, 10, 12, 3, 0, 0, 0);
   Check (Status /= 0, "spawn truncated path rejected");

   ----------------------------------------------------------------
   --  End-to-end IPC: spawn the echo server with a granted
   --  endpoint, ping-pong three rounds (badge, round-trip, one-shot
   --  reply cap, cap transfer), then reap the exited child.
   ----------------------------------------------------------------

   --  Locate "Tests/Echo" inside the boot manifest file.
   Manifest_Size := Raw_Ecall (Sys_Boot_File_Size, 1, 0, 0, 0, 0, 0);
   Echo_Offset := Failed;
   if Manifest_Size /= Failed
     and then Manifest_Size >= U64 (Echo_Path'Length)
   then
      A0 := 0;
      while A0 + U64 (Echo_Path'Length) <= Manifest_Size loop
         Match := 0;
         for J in Echo_Path'Range loop
            A1 := Raw_Ecall
              (Sys_Boot_Read_Byte, 1,
               A0 + U64 (J - Echo_Path'First), 0, 0, 0, 0);
            exit when A1 > 255
              or else Character'Val (Natural (A1)) /= Echo_Path (J);
            Match := Match + 1;
         end loop;
         if Match = Echo_Path'Length then
            Echo_Offset := A0;
            exit;
         end if;
         A0 := A0 + 1;
      end loop;
   end if;
   Check (Echo_Offset /= Failed, "echo path found in manifest");

   --  Endpoint granted by init at handle 1 with badge 0xEC40
   --  (session-manager badge pattern); messages sent through it
   --  arrive at echo stamped with that badge.
   EP := 1;

   --  Grant-list validation: unopened source handle.
   Akernel_User.Syscalls.Set_Grant (0, 250, 0, 0);
   Status := Raw_Ecall
     (Sys_Spawn, Echo_Offset, U64 (Echo_Path'Length), 1, 0, 0, 0);
   Check (Status = 4, "spawn grant of unopened cap rejected");

   --  Rights escalation: endpoints carry no Read right.
   Akernel_User.Syscalls.Set_Grant
     (0, EP, Akernel_User.Syscalls.Right_Read, 0);
   Status := Raw_Ecall
     (Sys_Spawn, Echo_Offset, U64 (Echo_Path'Length), 1, 0, 0, 0);
   Check (Status = 4, "spawn grant rights escalation rejected");

   --  Rights mask bits outside the valid set.
   Akernel_User.Syscalls.Set_Grant (0, EP, 16#400#, 0);
   Status := Raw_Ecall
     (Sys_Spawn, Echo_Offset, U64 (Echo_Path'Length), 1, 0, 0, 0);
   Check (Status = 4, "spawn grant unknown rights bits rejected");

   --  Grant count above the ABI limit.
   Status := Raw_Ecall
     (Sys_Spawn, Echo_Offset, U64 (Echo_Path'Length), 33, 0, 0, 0);
   Check (Status = 4, "spawn grant count over limit rejected");

   --  Valid grant: endpoint with Send+Receive (badged cap stays
   --  with the fuzzer; echo's own badge is irrelevant).
   Akernel_User.Syscalls.Set_Grant
     (0, EP,
      Akernel_User.Syscalls.Right_Send + Akernel_User.Syscalls.Right_Receive,
      0);
   Status := Raw_Ecall
     (Sys_Spawn, Echo_Offset, U64 (Echo_Path'Length), 1, 0, 0, 0);
   --  fuzz_last_a1 is rewritten by every ecall: capture the process
   --  cap before Check (or anything else) makes another syscall.
   Echo_Process := Last_A1;
   Check (Status = 0 and then Echo_Process /= 0,
          "echo spawned with granted endpoint");

   --  Round 1: badge + round-trip + first double-reply marker.
   Akernel_User.Syscalls.Message.Label := 16#AB#;
   Akernel_User.Syscalls.Message.Words := (1, 2, 3, 4, 5, 6);
   Akernel_User.Syscalls.Message.Caps := (others => 0);
   Status := Raw_Ecall (Sys_IPC_Call, EP, 0, 0, 0, 0, 0);
   Check (Status = 0, "echo call round 1 returned ok");
   Check (Akernel_User.Syscalls.Message.Label = 16#AB#,
          "echo round 1 label round-trips");
   Check (Akernel_User.Syscalls.Message.Words (0) = 16#EC40#,
          "echo round 1 badge delivered");
   Check (Akernel_User.Syscalls.Message.Words (1) = 1
          and then Akernel_User.Syscalls.Message.Words (4) = 4,
          "echo round 1 words round-trip");
   Check (Akernel_User.Syscalls.Message.Words (5) = 0,
          "echo round 1 first-reply marker");

   --  Round 2: word 5 must carry the failed double-reply code (1).
   Akernel_User.Syscalls.Message.Label := 16#CD#;
   Akernel_User.Syscalls.Message.Words := (6, 5, 4, 3, 2, 1);
   Akernel_User.Syscalls.Message.Caps := (others => 0);
   Status := Raw_Ecall (Sys_IPC_Call, EP, 0, 0, 0, 0, 0);
   Check (Status = 0, "echo call round 2 returned ok");
   Check (Akernel_User.Syscalls.Message.Words (0) = 16#EC40#
          and then Akernel_User.Syscalls.Message.Words (1) = 6,
          "echo round 2 payload");
   Check (Akernel_User.Syscalls.Message.Words (5) = 1,
          "echo double reply rejected (one-shot cap)");

   --  Round 3: cap transfer. EP2's handle is rewritten into echo's
   --  table (first free handle there = 2); echo reports it.
   EP2 := Raw_Ecall (Sys_EP_Create, 0, 0, 0, 0, 0, 0);
   Check (EP2 < 256 and then EP2 /= EP, "second endpoint created");
   Akernel_User.Syscalls.Message.Label := 16#EF#;
   Akernel_User.Syscalls.Message.Words := (others => 0);
   Akernel_User.Syscalls.Message.Caps := (EP2, 0, 0, 0);
   Status := Raw_Ecall (Sys_IPC_Call, EP, 0, 0, 0, 0, 0);
   Check (Status = 0, "echo call round 3 returned ok");
   Check (Akernel_User.Syscalls.Message.Words (0) = 16#EC40#,
          "echo round 3 badge delivered");
   Check (Akernel_User.Syscalls.Message.Words (1) = 2,
          "cap transferred and rewritten to echo handle 2");

   --  Echo exits after three rounds; reap it once it has exited.
   Reaped := False;
   for Try in 1 .. 128 loop
      Status := Raw_Ecall (Sys_Reap, Echo_Process, 0, 0, 0, 0, 0);
      if Status = 0 then
         Reaped := True;
         exit;
      end if;
      Ignore := Raw_Ecall (Sys_Yield, 0, 0, 0, 0, 0, 0);
   end loop;
   Check (Reaped, "echo reaped after exit");

   --  Random phase: every syscall except exit (9).  Spawn path length
   --  forced to 0 so no resolvable path can form.  debug_putchar bytes
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
            A1 := 0;
         end if;

         Status := Raw_Ecall (Number, A0, A1, A2, A3, A4, A5);
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
   Status := Raw_Ecall (Sys_Boot_File_Size, 1, 0, 0, 0, 0, 0);
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
   Status := Raw_Ecall (Sys_Exit, 0, 0, 0, 0, 0, 0);

   --  Reaching here means exit returned, which it never should.
   Put_Line ("FAIL exit returned");
end Fuzz;
