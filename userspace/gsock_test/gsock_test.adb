with Ada.Streams;
with Interfaces;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.Sockets;
with Akernel_User.Syscalls;
with GNAT.Sockets;
with Gsock_Test_Dns;

--  Gsock_Test (milestone 73): smoke of the GNAT.Sockets port over
--  the netserv bridge (vendored g-socket/g-socthi + the
--  akernel_gsocket.c port layer).  Everything is hairpin-
--  deterministic: numeric gethostbyname/getaddrinfo, a UDP round
--  trip (auto-bind, sender address), select expiry / readiness /
--  abort, a TCP listen-connect-accept echo with peer-address and
--  EOF checks, the gethostbyaddr negative, and a DNS A-record
--  lookup answered by the in-process responder task (Net:dns is
--  pointed at our own address, then restored).
--
--  Grant layout (manifest "program 14 Tests/Gsock_Test console fs
--  net"): 1 = console Send, 2 = file server Send, 3 = netserv
--  Send.

procedure Gsock_Test is
   subtype U64 is Interfaces.Unsigned_64;
   subtype U32 is Interfaces.Unsigned_32;
   use type U64;
   use type U32;

   package AS       renames Ada.Streams;
   package Console  renames Akernel_User.Console;
   package Files    renames Akernel_User.Files;
   package Sock     renames Akernel_User.Sockets;
   package Syscalls renames Akernel_User.Syscalls;
   package GS       renames GNAT.Sockets;

   use type AS.Stream_Element_Offset;
   use type GS.Inet_Addr_Type;
   use type GS.Port_Type;
   use type GS.Selector_Status;

   FS_Cap  : constant U64 := 2;
   Net_EP  : constant U64 := 3;
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

   function To_Bytes (S : String) return AS.Stream_Element_Array is
      R : AS.Stream_Element_Array (1 .. S'Length);
   begin
      for I in S'Range loop
         R (AS.Stream_Element_Offset (I - S'First + 1)) :=
            AS.Stream_Element (Character'Pos (S (I)));
      end loop;
      return R;
   end To_Bytes;

   function To_String (A : AS.Stream_Element_Array) return String is
      S : String (1 .. Natural (A'Length));
   begin
      for I in A'Range loop
         S (Natural (I - A'First) + 1) :=
            Character'Val (Natural (A (I)));
      end loop;
      return S;
   end To_String;

   Name_Buf : String (1 .. 64);
   Name_Len : Natural := 0;
   Size     : U64 := 0;
   Got      : U64 := 0;
   St       : U64;
   My_IP    : U32 := 0;

begin
   Files.Bind (FS_Cap);

   --  Our own address, via the Net: volume (2 s registration-
   --  window retry, as in tcp_test).
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
   --  The Net: volume renders with a trailing newline; GNAT's
   --  Inet_Addr insists on a bare dotted string.
   if St = Files.Status_Ok then
      Name_Len := Natural (Got);
      while Name_Len > 0
        and then (Name_Buf (Name_Len) = ' '
                  or else Name_Buf (Name_Len) = ASCII.CR
                  or else Name_Buf (Name_Len) = ASCII.LF)
      loop
         Name_Len := Name_Len - 1;
      end loop;
   end if;
   Expect (St = Files.Status_Ok and then Name_Len > 0
           and then Sock.Parse_IP (Name_Buf (1 .. Name_Len),
                                   My_IP),
           "gsock reads its address from Net:address");

   Sock.Attach (Net_EP);

   declare
      My_Name : constant String := Name_Buf (1 .. Name_Len);
      My_Addr : constant GS.Inet_Addr_Type := GS.Inet_Addr (My_Name);
   begin
      --  Numeric resolution paths (no DNS traffic at all).
      declare
         H : constant GS.Host_Entry_Type :=
           GS.Get_Host_By_Name (My_Name);
      begin
         Expect (GS.Addresses_Length (H) = 1
                 and then GS.Addresses (H) = My_Addr,
                 "gethostbyname resolves a dotted name");
      end;

      declare
         AI : constant GS.Address_Info_Array :=
           GS.Get_Address_Info (My_Name, "21300");
      begin
         Expect (AI'Length > 0
                 and then AI (AI'First).Addr.Addr = My_Addr
                 and then AI (AI'First).Addr.Port = 21300,
                 "getaddrinfo fills a numeric address");
      end;

      --  UDP round trip: sender unbound (auto-bind check),
      --  receiver fixed; From must name the sender.
      declare
         A, B  : GS.Socket_Type;
         Dst   : aliased GS.Sock_Addr_Type :=
           (GS.Family_Inet, My_Addr, 21310);
         Buf   : AS.Stream_Element_Array (1 .. 64);
         Last  : AS.Stream_Element_Offset;
         Sent  : AS.Stream_Element_Offset;
         From  : GS.Sock_Addr_Type;
         Sel   : GS.Selector_Type;
         RSet  : GS.Socket_Set_Type;
         WSet  : GS.Socket_Set_Type;
         Sst   : GS.Selector_Status;
      begin
         GS.Create_Socket (A, GS.Family_Inet, GS.Socket_Datagram);
         GS.Bind_Socket (A, Dst);
         GS.Create_Socket (B, GS.Family_Inet, GS.Socket_Datagram);

         GS.Send_Socket (B, To_Bytes ("gnat udp"), Sent,
                         Dst'Access);
         Expect (Sent = 8, "udp datagram sent");
         Expect (GS.Get_Socket_Name (B).Port /= 0,
                 "udp auto-binds an ephemeral source port");

         GS.Receive_Socket (A, Buf, Last, From);
         Expect (Last = 8
                 and then To_String (Buf (1 .. Last)) = "gnat udp"
                 and then From.Addr = My_Addr
                 and then From.Port = GS.Get_Socket_Name (B).Port,
                 "udp round trip reports the sender");

         --  Selector: expiry on an idle socket, readiness once a
         --  datagram lands, abort via the signalling fds.
         GS.Create_Selector (Sel);
         GS.Empty (RSet);
         GS.Set (RSet, A);
         GS.Empty (WSet);
         GS.Check_Selector (Sel, RSet, WSet, Sst, 0.05);
         Expect (Sst = GS.Expired,
                 "select on an idle socket expires");

         GS.Send_Socket (B, To_Bytes ("gnat udp"), Sent,
                         Dst'Access);
         GS.Empty (RSet);
         GS.Set (RSet, A);
         GS.Empty (WSet);
         GS.Check_Selector (Sel, RSet, WSet, Sst, 2.0);
         Expect (Sst = GS.Completed
                 and then GS.Is_Set (RSet, A),
                 "select reports a readable socket");
         GS.Receive_Socket (A, Buf, Last, From);

         GS.Empty (RSet);
         GS.Set (RSet, A);
         GS.Empty (WSet);
         GS.Abort_Selector (Sel);
         GS.Check_Selector (Sel, RSet, WSet, Sst, 5.0);
         Expect (Sst = GS.Aborted,
                 "abort selector wakes select");
         GS.Close_Selector (Sel);

         GS.Close_Socket (A);
         GS.Close_Socket (B);
      end;

      --  TCP: listen, connect, accept (peer address check),
      --  echo both ways, orderly close reads as EOF.
      declare
         L, C, S : GS.Socket_Type;
         LA      : constant GS.Sock_Addr_Type :=
           (GS.Family_Inet, My_Addr, 21320);
         Peer    : GS.Sock_Addr_Type;
         Buf     : AS.Stream_Element_Array (1 .. 64);
         Last    : AS.Stream_Element_Offset;
         Sent    : AS.Stream_Element_Offset;
      begin
         GS.Create_Socket (L, GS.Family_Inet, GS.Socket_Stream);
         GS.Bind_Socket (L, LA);
         GS.Listen_Socket (L);

         GS.Create_Socket (C, GS.Family_Inet, GS.Socket_Stream);
         GS.Connect_Socket (C, LA);
         GS.Accept_Socket (L, S, Peer);
         Expect (Peer.Addr = My_Addr
                 and then Peer.Port = GS.Get_Socket_Name (C).Port,
                 "tcp accept reports the peer address");

         GS.Send_Socket (C, To_Bytes ("gnat tcp"), Sent);
         GS.Receive_Socket (S, Buf, Last);
         Expect (Last = 8
                 and then To_String (Buf (1 .. Last)) = "gnat tcp",
                 "tcp data through gnat sockets");

         GS.Send_Socket (S, To_Bytes ("tcp reply"), Sent);
         GS.Receive_Socket (C, Buf, Last);
         Expect (Last = 9
                 and then To_String (Buf (1 .. Last)) =
                          "tcp reply",
                 "tcp reply through gnat sockets");

         GS.Close_Socket (C);
         GS.Receive_Socket (S, Buf, Last);
         Expect (Last = Buf'First - 1,
                 "tcp peer close reads as eof");

         GS.Close_Socket (S);
         GS.Close_Socket (L);
      end;

      --  Reverse lookups resolve numerically (no PTR records on
      --  slirp); Get_Host_By_Name on a dotted name relies on this.
      declare
         H : constant GS.Host_Entry_Type :=
           GS.Get_Host_By_Address (My_Addr);
      begin
         Expect (GS.Addresses_Length (H) = 1
                 and then GS.Addresses (H) = My_Addr,
                 "gethostbyaddr resolves numerically");
      end;

      --  DNS: point Net:dns at ourselves and let the responder
      --  task answer the A-record query for test.akernel.
      declare
         Def     : aliased constant String := "10.0.2.3";
         WSt     : U64;
         Written : U64;
         Tries   : Natural;
       begin
          Gsock_Test_Dns.Own_Len :=
           Natural'Min (My_Name'Length, Gsock_Test_Dns.Own_IP'Length);
         Gsock_Test_Dns.Own_IP (1 .. Gsock_Test_Dns.Own_Len) :=
           My_Name (My_Name'First ..
                    My_Name'First + Gsock_Test_Dns.Own_Len - 1);
         Gsock_Test_Dns.Reply_Word := 16#0102_0304#;
         WSt := Files.Write ("Net:dns", 0, My_Name'Address,
                             U64 (My_Name'Length), Written);
         Expect (WSt = Files.Status_Ok,
                 "net:dns pointed at the hairpin responder");

          Gsock_Test_Dns.Go := True;
          Tries := 2000;
          while not Gsock_Test_Dns.Bound and then Tries > 0 loop
             delay 0.001;
             Tries := Tries - 1;
          end loop;
          Expect (Gsock_Test_Dns.Bound,
                  "dns responder bound to port 53");

          declare
            H : constant GS.Host_Entry_Type :=
              GS.Get_Host_By_Name ("test.akernel");
         begin
            Expect (GS.Addresses_Length (H) = 1
                    and then GS.Addresses (H) =
                             GS.Inet_Addr ("1.2.3.4"),
                     "dns a-record through the hairpin");
          end;

          Tries := 2000;
         while not Gsock_Test_Dns.Done and then Tries > 0 loop
            delay 0.001;
            Tries := Tries - 1;
         end loop;
         Expect (Gsock_Test_Dns.Done, "dns responder finished");

         WSt := Files.Write ("Net:dns", 0, Def'Address,
                             U64 (Def'Length), Written);
         Expect (WSt = Files.Status_Ok, "net:dns restored");
      end;
   end;

   if Failed then
      Console.Put_Line ("FAIL gsock_test");
   else
      Console.Put_Line ("PASS gsock_test");
   end if;
end Gsock_Test;
