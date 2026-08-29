with Interfaces;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.Sockets;
with Akernel_User.Syscalls;

--  Tcp_Test (milestone 72c): end-to-end smoke of the netserv TCP
--  socket layer. Deterministic hairpin half (no wire traffic): a
--  listener, a connect to our own address, accept, a small
--  bidirectional echo, an 8 KiB patterned stream through the
--  4-slot rings (exercises lwIP's windowing + the refused-data
--  backpressure), a refused connect and an orderly close (EOF
--  marker). Wire half: an echo round trip to the host through
--  QEMU slirp (10.0.2.2 = host loopback; tools/tcp_echo.py is
--  started by `make test`).
--
--  Grant layout (manifest "program 13 Tests/Tcp_Test console fs
--  net"): 1 = console Send, 2 = file server Send, 3 = netserv
--  Send.

procedure Tcp_Test is
   subtype U64 is Interfaces.Unsigned_64;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U8  is Interfaces.Unsigned_8;
   use type U64;
   use type U32;
   use type U8;

   package Console  renames Akernel_User.Console;
   package Files    renames Akernel_User.Files;
   package Sock     renames Akernel_User.Sockets;
   package Syscalls renames Akernel_User.Syscalls;

   Console_EP : constant U64 := 1;
   FS_Cap     : constant U64 := 2;
   Net_EP     : constant U64 := 3;

   Tick_Hz : constant U64 := 10_000_000;

   --  tools/tcp_echo.py on the host (reached through slirp's
   --  10.0.2.2 host-loopback alias).
   Host_IP    : constant U32 := 16#0A00_0202#;
   Echo_Port  : constant U64 := 10007;

   Failed : Boolean := False;

   procedure Expect (Ok : Boolean; Name : String) is
   begin
      if Ok then
         Console.Put_Line ("PASS " & Name);
      else
         Console.Put_Line ("FAIL " & Name);
         Failed := True;
      end if;
   end Expect;

   My_IP  : U32 := 0;
   St     : U64;
   Size   : U64 := 0;
   Got    : U64 := 0;
   A      : U64 := 0;   --  listener
   B      : U64 := 0;   --  connector
   C      : U64 := 0;   --  accepted child
   D      : U64 := 0;   --  refused
   E      : U64 := 0;   --  slirp echo
   Bound  : U64;
   Rx_Lvl : U64;
   Tx_Free : U64;
   Err    : U64;
   Src_IP : U32;
   Src_Port : U64;
   Name_Buf : String (1 .. 32);
   Out_Buf  : array (0 .. 995) of U8;
   In_Buf   : array (0 .. 995) of U8;

   --  Fill Len bytes of Out_Buf with the BIG.BIN pattern starting
   --  at stream offset Pos: byte i = (i*7+3) mod 256.
   procedure Fill_Pattern (Pos : U64; Len : U64) is
   begin
      for I in 0 .. Len - 1 loop
         Out_Buf (Natural (I)) := U8 (((Pos + I) * 7 + 3) mod 256);
      end loop;
   end Fill_Pattern;

   --  Send a counted string as one slot.
   procedure Put (S : String) is
   begin
      for I in S'Range loop
         Out_Buf (I - S'First) := U8 (Character'Pos (S (I)));
      end loop;
   end Put;
begin
   Console.Set_Endpoint (Console_EP);
   Files.Bind (FS_Cap);

   --  Our own address, via the Net: volume (same 2 s
   --  registration-window retry as udp_test, m72a).
   St := Files.Open ("Net:address", Size);
   declare
      Deadline : constant U64 := Syscalls.Read_Time + 2 * Tick_Hz;
   begin
      while St /= Files.Status_Ok
        and then Syscalls.Read_Time < Deadline
      loop
         St := Syscalls.Sleep_Until
           (Syscalls.Read_Time + Tick_Hz / 200);  --  5 ms
         St := Files.Open ("Net:address", Size);
      end loop;
   end;
   if St = Files.Status_Ok then
      Size := U64'Min (Size, U64 (Name_Buf'Length));
      St := Files.Read ("Net:address", 0, Name_Buf'Address,
                        Size, Got);
   end if;
   Expect (St = Files.Status_Ok and then Got > 0
           and then Sock.Parse_IP (Name_Buf (1 .. Natural (Got)),
                                   My_IP),
           "tcp reads its address from Net:address");

   Sock.Attach (Net_EP);

   --  Listener on a fixed port.
   St := Sock.Socket (Sock.IPPROTO_TCP, A);
   Expect (St = Sock.Status_Ok, "tcp listener socket created");
   St := Sock.Bind (A, 21000, Bound);
   Expect (St = Sock.Status_Ok and then Bound = 21000,
           "tcp listener bound");
   St := Sock.Listen (A, 4);
   Expect (St = Sock.Status_Ok, "tcp listener listening");

   --  Hairpin connect: SYN/SYN-ACK/ACK loop back through the
   --  stack; the reply is deferred but completes synchronously.
   St := Sock.Socket (Sock.IPPROTO_TCP, B);
   Expect (St = Sock.Status_Ok, "tcp connector socket created");
   St := Sock.Connect (B, My_IP, 21000);
   Expect (St = Sock.Status_Ok, "tcp hairpin connect ok");

   St := Sock.Poll (A, Rx_Lvl, Tx_Free, Err);
   Expect (St = Sock.Status_Ok and then Rx_Lvl = 1,
           "tcp listener backlog reports one pending");

   St := Sock.Accept_Connection (A, C);
   Expect (St = Sock.Status_Ok and then C /= 0,
           "tcp accept returns the child");

   --  Small echo both ways.
   Put ("hello tcp");
   St := Sock.Send_To (B, Out_Buf'Address, 9, 0, 0);
   Expect (St = Sock.Status_Ok, "tcp client send ok");
   St := Sock.Recv_From (C, In_Buf'Address, 996, 2 * Tick_Hz,
                         Src_IP, Src_Port, Got);
   Expect (St = Sock.Status_Ok and then Got = 9,
           "tcp server recv got the bytes");
   declare
      Back : String (1 .. 9);
   begin
      for I in 1 .. 9 loop
         Back (I) := Character'Val (Natural (In_Buf (I - 1)));
      end loop;
      Expect (Back = "hello tcp", "tcp payload intact");
   end;

   Put ("and back!");
   St := Sock.Send_To (C, Out_Buf'Address, 9, 0, 0);
   Expect (St = Sock.Status_Ok, "tcp server send ok");
   St := Sock.Recv_From (B, In_Buf'Address, 996, 2 * Tick_Hz,
                         Src_IP, Src_Port, Got);
   declare
      Back : String (1 .. 9);
   begin
      for I in 1 .. 9 loop
         Back (I) := Character'Val (Natural (In_Buf (I - 1)));
      end loop;
      Expect (St = Sock.Status_Ok and then Got = 9
              and then Back = "and back!",
              "tcp echo back intact");
   end;

   --  Multi-KB stream: 8192 patterned bytes B -> C, sender and
   --  receiver interleaved so the 4-slot rings and the lwIP
   --  window engage (chunk boundaries on RX are arbitrary — the
   --  receiver accumulates by count).
   declare
      Total  : constant U64 := 8192;
      Pos    : U64 := 0;
      Got_N  : U64;
      Chunk  : U64;
      Ok     : Boolean := True;
   begin
      Got := 0;
      while Ok and then (Pos < Total or else Got < Total) loop
         if Pos < Total then
            Chunk := U64'Min (996, Total - Pos);
            Fill_Pattern (Pos, Chunk);
            if Sock.Send_To (B, Out_Buf'Address, Chunk, 0, 0)
                 /= Sock.Status_Ok
            then
               Ok := False;
            else
               Pos := Pos + Chunk;
            end if;
         end if;
         if Ok and then Got < Total then
            if Sock.Recv_From (C, In_Buf'Address, 996, 2 * Tick_Hz,
                               Src_IP, Src_Port, Got_N)
                 /= Sock.Status_Ok
              or else Got_N = 0
            then
               Ok := False;
            else
               for I in 0 .. Got_N - 1 loop
                  if In_Buf (Natural (I))
                       /= U8 (((Got + I) * 7 + 3) mod 256)
                  then
                     Ok := False;
                  end if;
               end loop;
               Got := Got + Got_N;
            end if;
         end if;
      end loop;
      Expect (Ok and then Pos = Total and then Got = Total,
              "tcp 8k stream transferred intact");
   end;

   --  Connect to a closed local port: refused (sticky code 4).
   St := Sock.Socket (Sock.IPPROTO_TCP, D);
   Expect (St = Sock.Status_Ok, "tcp refused-test socket created");
   St := Sock.Connect (D, My_IP, 29999);
   Expect (St = 4, "tcp connect to a closed port refused");
   St := Sock.Close (D);
   Expect (St = Sock.Status_Ok, "tcp refused socket closed");

   --  Orderly close: closing B sends FIN; C's reader sees the
   --  EOF marker (Count = 0) with a clean error word.
   St := Sock.Close (B);
   Expect (St = Sock.Status_Ok, "tcp client closed");
   St := Sock.Recv_From (C, In_Buf'Address, 996, 2 * Tick_Hz,
                         Src_IP, Src_Port, Got);
   Expect (St = Sock.Status_Ok and then Got = 0,
           "tcp server sees the eof marker");
   St := Sock.Poll (C, Rx_Lvl, Tx_Free, Err);
   Expect (St = Sock.Status_Ok and then Err = 0,
           "tcp orderly close keeps the error word clean");
   St := Sock.Close (C);
   Expect (St = Sock.Status_Ok, "tcp child closed");
   St := Sock.Close (A);
   Expect (St = Sock.Status_Ok, "tcp listener closed");

   --  Wire side: echo through slirp to the host tcp_echo server.
   St := Sock.Socket (Sock.IPPROTO_TCP, E);
   Expect (St = Sock.Status_Ok, "tcp echo socket created");
   St := Sock.Connect (E, Host_IP, Echo_Port);
   Expect (St = Sock.Status_Ok, "tcp slirp connect ok");
   if St = Sock.Status_Ok then
      Put ("echo via slirp");
      St := Sock.Send_To (E, Out_Buf'Address, 14, 0, 0);
      Expect (St = Sock.Status_Ok, "tcp slirp send ok");
      St := Sock.Recv_From (E, In_Buf'Address, 996, 3 * Tick_Hz,
                            Src_IP, Src_Port, Got);
      declare
         Back : String (1 .. 14);
      begin
         for I in 1 .. 14 loop
            Back (I) := Character'Val (Natural (In_Buf (I - 1)));
         end loop;
         Expect (St = Sock.Status_Ok and then Got = 14
                 and then Back = "echo via slirp",
                 "tcp slirp echo round trip");
      end;
   end if;
   St := Sock.Close (E);
   Expect (St = Sock.Status_Ok, "tcp echo socket closed");

   if Failed then
      Syscalls.Process_Exit (1);
   end if;
   Syscalls.Process_Exit (0);
end Tcp_Test;
