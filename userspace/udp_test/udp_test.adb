with Interfaces;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.Sockets;
with Akernel_User.Syscalls;

--  Udp_Test (milestone 71c): end-to-end smoke of the netserv
--  socket layer over the hairpin (no wire traffic needed):
--  two bound UDP sockets, a datagram A->B via our own address,
--  source address/port reported back, and the closed-port
--  sticky error. The target address is read from Net:address,
--  which also exercises the Net: volume's read path.
--
--  Grant layout (manifest "program 12 Tests/Udp_Test console fs
--  net"): 1 = console Send, 2 = file server Send, 3 = netserv
--  Send.

procedure Udp_Test is
   subtype U64 is Interfaces.Unsigned_64;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U8  is Interfaces.Unsigned_8;
   use type U64;
   use type U32;

   package Console  renames Akernel_User.Console;
   package Files    renames Akernel_User.Files;
   package Sock     renames Akernel_User.Sockets;
   package Syscalls renames Akernel_User.Syscalls;

   Console_EP : constant U64 := 1;
   FS_Cap     : constant U64 := 2;
   Net_EP     : constant U64 := 3;

   Tick_Hz : constant U64 := 10_000_000;

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
   A      : U64 := 0;
   B      : U64 := 0;
   Bound  : U64;
   Src_IP : U32;
   Src_Port : U64;
   Rx_Lvl : U64;
   Tx_Free : U64;
   Err    : U64;
   Name_Buf : String (1 .. 32);
   Out_Buf  : array (0 .. 12) of U8;
   In_Buf   : array (0 .. 63) of U8;
begin
   Console.Set_Endpoint (Console_EP);
   Files.Bind (FS_Cap);

   --  Our own address, via the Net: volume. Netserv registers
   --  Net: at the END of its bring-up (m72a: self-registration
   --  closes the fs<->netserv bring-up deadlock), so this open
   --  can race the registration — retry for up to 2 s before
   --  declaring failure.
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
           "udp reads its address from Net:address");

   Sock.Attach (Net_EP);

   St := Sock.Socket (Sock.IPPROTO_UDP, A);
   Expect (St = Sock.Status_Ok, "udp socket a created");
   St := Sock.Socket (Sock.IPPROTO_UDP, B);
   Expect (St = Sock.Status_Ok, "udp socket b created");

   St := Sock.Bind (A, 20000, Bound);
   Expect (St = Sock.Status_Ok and then Bound = 20000,
           "udp socket a bound");
   St := Sock.Bind (B, 20001, Bound);
   Expect (St = Sock.Status_Ok and then Bound = 20001,
           "udp socket b bound");

   --  Hairpin A -> B: 13 payload bytes.
   declare
      Msg : constant String := "hairpin hello";
   begin
      for I in Msg'Range loop
         Out_Buf (I - Msg'First) := U8 (Character'Pos (Msg (I)));
      end loop;
   end;
   St := Sock.Send_To (A, Out_Buf'Address, 13, My_IP, 20001);
   Expect (St = Sock.Status_Ok, "udp hairpin send queued");

   St := Sock.Recv_From (B, In_Buf'Address, 64, 2 * Tick_Hz,
                         Src_IP, Src_Port, Got);
   Expect (St = Sock.Status_Ok and then Got = 13,
           "udp hairpin delivers ok");
   Expect (Src_IP = My_IP and then Src_Port = 20000,
           "udp hairpin reports the source");
   declare
      Back : String (1 .. 13);
   begin
      for I in 1 .. 13 loop
         Back (I) := Character'Val (Natural (In_Buf (I - 1)));
      end loop;
      Expect (Back = "hairpin hello", "udp hairpin payload intact");
   end;

   --  A datagram to a closed local port sets the sender's
   --  sticky error word (the implicit hairpin port-unreachable).
   St := Sock.Send_To (A, Out_Buf'Address, 1, My_IP, 29999);
   Expect (St = Sock.Status_Ok, "udp closed-port send queued");
   St := Syscalls.Sleep_Until
     (Syscalls.Read_Time + Tick_Hz / 10);   --  let the kick land
   St := Sock.Poll (A, Rx_Lvl, Tx_Free, Err);
   Expect (St = Sock.Status_Ok and then Err = 1,
           "udp closed port reports error");

   St := Sock.Close (A);
   Expect (St = Sock.Status_Ok, "udp socket a closed");
   St := Sock.Close (B);
   Expect (St = Sock.Status_Ok, "udp socket b closed");

   if Failed then
      Syscalls.Process_Exit (1);
   end if;
   Syscalls.Process_Exit (0);
end Udp_Test;
