with Interfaces;
with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Sockets;
with Akernel_User.Syscalls;

--  Ping (milestone 71c): ICMP echo over a netserv ping socket —
--  the Amiga C:Ping analog:
--
--    ping [-c N] <ipv4|hostname>
--
--  A non-dotted target is resolved to an IPv4 address through the
--  netserv-resident resolver (Op_Resolve / lwIP dns.c) before the
--  echo probes start. Each probe is a 16-byte ICMP echo request
--  (seq + an 8-byte big-endian send timestamp the reply echoes
--  back; RTT is computed from that payload). Default count is 4,
--  interval 1 s, per-probe timeout 1 s. Amiga return codes:
--  RC_Ok when every probe was answered, RC_Warn on partial loss,
--  RC_Error on total loss or a usage/socket/resolution failure.

procedure Ping is
   subtype U64 is Interfaces.Unsigned_64;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U8  is Interfaces.Unsigned_8;
   use type U64;
   use type U32;
   use type U8;

   package CLI  renames Akernel_User.CLI;
   package Sock renames Akernel_User.Sockets;
   package Syscalls renames Akernel_User.Syscalls;
   package Console renames Akernel_User.Console;

   --  Uniform command ABI handle 6 (Scripting.Net_EP): the
   --  netserv client endpoint every command spawner grants.
   Net_EP : constant U64 := 6;

   Tick_Hz : constant U64 := 10_000_000;

   function Dec (V : U64) return String is
      Digs : String (1 .. 20);
      Len  : Natural := 0;
      X    : U64 := V;
   begin
      if X = 0 then
         return "0";
      end if;
      while X /= 0 loop
         Len := Len + 1;
         Digs (Len) := Character'Val
           (Character'Pos ('0') + Natural (X mod 10));
         X := X / 10;
      end loop;
      return R : String (1 .. Len) do
         for I in 1 .. Len loop
            R (I) := Digs (Len - I + 1);
         end loop;
      end return;
   end Dec;

   function Parse_Count (S : String; V : out U64) return Boolean is
   begin
      V := 0;
      if S'Length = 0 then
         return False;
      end if;
      for C of S loop
         if C not in '0' .. '9' then
            return False;
         end if;
         V := V * 10 + U64 (Character'Pos (C) - Character'Pos ('0'));
         if V > 1000 then
            return False;
         end if;
      end loop;
      return V > 0;
   end Parse_Count;

   Count      : U64 := 4;
   Ip_Arg     : Natural := 1;
   Target     : U32;
   S          : U64 := 0;
   St         : U64;
   Sent       : U64 := 0;
   Received   : U64 := 0;
   Src_IP     : U32;
   Src_Port   : U64;
   Got        : U64;
   T0         : U64;
   Rtt        : U64;
   Reply_T0   : U64;
   Out_Buf    : array (0 .. 15) of U8;
   In_Buf     : array (0 .. 63) of U8;
begin
   CLI.Init;

   if CLI.Argument (1) = "-c" then
      if not Parse_Count (CLI.Argument (2), Count) then
         Console.Put_Line ("usage: ping [-c N] <ipv4|hostname>");
         CLI.Exit_With (CLI.RC_Error);
      end if;
      Ip_Arg := 3;
   end if;

   declare
      Raw    : constant String := CLI.Argument (Ip_Arg);
      Is_Name : constant Boolean := not Sock.Parse_IP (Raw, Target);
   begin
      if Raw'Length = 0 then
         Console.Put_Line ("usage: ping [-c N] <ipv4|hostname>");
         CLI.Exit_With (CLI.RC_Error);
      end if;

      Sock.Attach (Net_EP);

      if Is_Name then
         --  Hostname target: ask the netserv-resident resolver
         --  (Op_Resolve / lwIP dns.c) for the address first. The
         --  numeric path above never reaches this branch.
         St := Sock.Resolve (Raw, Target);
         if St /= Sock.Status_Ok then
            declare
               Why : constant String :=
                 (if St = Sock.Status_Timeout
                  then "name not found"
                  elsif St = Sock.Status_Not_Ready
                  then "resolver busy"
                  elsif St = Sock.Status_Bad_Args
                  then "malformed name"
                  else "resolver error");
            begin
               Console.Put_Line ("ping: " & Raw & ": " & Why);
            end;
            CLI.Exit_With (CLI.RC_Error);
         end if;
      end if;
   end;

   St := Sock.Socket (Sock.IPPROTO_ICMP, S);
   if St /= Sock.Status_Ok then
      Console.Put_Line ("ping: socket failed (" & Dec (St) & ")");
      CLI.Exit_With (CLI.RC_Error);
   end if;
   St := Sock.Connect (S, Target, 0);
   if St /= Sock.Status_Ok then
      Console.Put_Line ("ping: connect failed (" & Dec (St) & ")");
      CLI.Exit_With (CLI.RC_Error);
   end if;

   for I in 1 .. Count loop
      --  Echo request: type 8, code 0, cksum/ident owned by
      --  netserv, seq = I, payload = send timestamp (BE).
      T0 := Syscalls.Read_Time;
      Out_Buf := (others => 0);
      Out_Buf (0) := 8;
      Out_Buf (6) := U8 (I / 256);
      Out_Buf (7) := U8 (I mod 256);
      for B in 0 .. 7 loop
         Out_Buf (8 + B) :=
           U8 (Interfaces.Shift_Right (T0, (7 - B) * 8) and 16#FF#);
      end loop;

      St := Sock.Send_To (S, Out_Buf'Address, 16, Target, 0);
      if St = Sock.Status_Ok then
         Sent := Sent + 1;
         St := Sock.Recv_From
           (S, In_Buf'Address, 64, Tick_Hz, Src_IP, Src_Port, Got);
      end if;
      if St = Sock.Status_Ok
        and then Got >= 16
        and then In_Buf (0) = 0
        and then In_Buf (6) = U8 (I / 256)
        and then In_Buf (7) = U8 (I mod 256)
      then
         Reply_T0 := 0;
         for B in 0 .. 7 loop
            Reply_T0 := Reply_T0 * 256 + U64 (In_Buf (8 + B));
         end loop;
         Rtt := Syscalls.Read_Time - Reply_T0;
         Received := Received + 1;
         Console.Put_Line
           ("reply from " & Sock.Ip_Image (Src_IP)
            & ": icmp_seq=" & Dec (I)
            & " time=" & Dec (Rtt / 10_000) & " ms");
      else
         Console.Put_Line ("request timeout for icmp_seq " & Dec (I));
      end if;

      if I < Count then
         St := Syscalls.Sleep_Until (Syscalls.Read_Time + Tick_Hz);
      end if;
   end loop;

   Console.Put_Line
     ("sent=" & Dec (Sent) & " received=" & Dec (Received));
   St := Sock.Close (S);

   if Received = Count then
      CLI.Exit_With (CLI.RC_Ok);
   elsif Received > 0 then
      CLI.Exit_With (CLI.RC_Warn);
   else
      CLI.Exit_With (CLI.RC_Error);
   end if;
end Ping;
