with Interfaces;
with Akernel_User.Console;
with Akernel_User.Syscalls;

--  Net_Test (milestone 71b): end-to-end smoke of System/Netserv
--  through the internal Op_Ping op. Pings the slirp gateway
--  (10.0.2.2 — ARP resolve + ICMP echo round trip), our own
--  address (loopback short-circuit), and an unreachable slirp
--  address (ARP timeout -> status 1, ~2 s).
--
--  Grant layout (manifest "program 11 Tests/Net_Test console
--  net"): 1 = console Send, 2 = netserv Send.

procedure Net_Test is
   subtype U64 is Interfaces.Unsigned_64;
   use type U64;

   package Syscalls renames Akernel_User.Syscalls;
   package Console renames Akernel_User.Console;

   Console_EP : constant U64 := 1;
   Net_EP     : constant U64 := 2;

   Op_Ping : constant U64 := 40;

   --  Read_Time ticks at 10 MHz; a LAN RTT above one second is
   --  never sane.
   Tick_Hz : constant U64 := 10_000_000;

   Failed : Boolean := False;

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

   --  One Op_Ping round trip; returns the status word, RTT in
   --  Rtt (ticks).
   function Ping (Target : U64; Rtt : out U64) return U64 is
   begin
      Syscalls.Message.Label := Op_Ping;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Words (0) := Target;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (Net_EP) /= Syscalls.IPC_Ok then
         return U64'Last;
      end if;
      Rtt := Syscalls.Message.Words (1);
      return Syscalls.Message.Words (0);
   end Ping;

   procedure Expect (Ok : Boolean; Name : String) is
   begin
      if Ok then
         Console.Put_Line ("PASS " & Name);
      else
         Console.Put_Line ("FAIL " & Name);
         Failed := True;
      end if;
   end Expect;

   Rtt    : U64 := 0;
   Status : U64;
begin
   Console.Set_Endpoint (Console_EP);

   Status := Ping (16#0A00_0202#, Rtt);          --  10.0.2.2
   Expect (Status = 0, "net ping gateway ok");
   Expect (Rtt < Tick_Hz, "net ping gateway rtt sane");
   Console.Put_Line ("net ping gateway rtt " & Dec (Rtt) & " ticks");

   Status := Ping (16#0A00_020F#, Rtt);          --  10.0.2.15 (us)
   Expect (Status = 0, "net ping self ok");

   Status := Ping (16#0A00_0263#, Rtt);          --  10.0.2.99 (absent)
   Expect (Status = 1, "net ping unreachable times out");

   Status := Ping (0, Rtt);                      --  bad target
   Expect (Status = 3, "net ping rejects bad args");

   if Failed then
      Syscalls.Process_Exit (1);
   end if;
   Syscalls.Process_Exit (0);
end Net_Test;
