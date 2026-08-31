with Interfaces;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.Syscalls;

--  Dhcp_Test (milestone 78b): the opt-in DHCP client end to end.
--  Static config is the default; the test starts the client via
--  the writable Net:dhcp file, waits for slirp's lease (always
--  10.0.2.15 / gateway 10.0.2.2 for this MAC), proves static
--  writes are rejected while the client runs and that the wire
--  works on the lease, renews, then stops and checks the stashed
--  static config is restored.
--
--  Grant layout (manifest "program 15 Tests/Dhcp_Test console fs
--  net"): 1 = console Send, 2 = file server Send, 3 = netserv
--  Send.

procedure Dhcp_Test is
   subtype U64 is Interfaces.Unsigned_64;
   use type U64;

   package Syscalls renames Akernel_User.Syscalls;
   package Console  renames Akernel_User.Console;
   package Files    renames Akernel_User.Files;

   Console_EP : constant U64 := 1;
   FS_Cap     : constant U64 := 2;
   Net_EP     : constant U64 := 3;

   Op_Ping : constant U64 := 40;

   --  Read_Time ticks at 10 MHz.
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

   Buf    : String (1 .. 128);
   Got    : U64 := 0;
   Len    : Natural := 0;
   St     : U64;
   Size   : U64 := 0;
   Written : U64 := 0;

   --  Whole-file read of a small Net: file; Buf/Len carry the
   --  content (Len = 0 on failure).
   procedure Read_Net (Path : String) is
   begin
      Len := 0;
      if Files.Open (Path, Size) /= Files.Status_Ok then
         return;
      end if;
      Size := U64'Min (Size, U64 (Buf'Length));
      if Files.Read (Path, 0, Buf'Address, Size, Got)
           /= Files.Status_Ok
      then
         return;
      end if;
      Len := Natural (Got);
   end Read_Net;

   function Write_Net (Path : String; Text : String) return U64 is
   begin
      return Files.Write (Path, 0, Text'Address,
                          U64 (Text'Length), Written);
   end Write_Net;

   --  The Net: volume renders with a trailing newline; compare the
   --  trimmed content.
   function Renders (Text : String) return Boolean is
      Last : Natural := Len;
   begin
      while Last > 0
        and then (Buf (Last) = ' '
                  or else Buf (Last) = ASCII.CR
                  or else Buf (Last) = ASCII.LF)
      loop
         Last := Last - 1;
      end loop;
      return Last = Text'Length
        and then Buf (1 .. Last) = Text;
   end Renders;

   --  Net:dhcp's first line is "state <name>".
   function State_Is (Name : String) return Boolean is
      Prefix : constant String := "state " & Name;
   begin
      return Len >= Prefix'Length
        and then Buf (1 .. Prefix'Length) = Prefix
        and then (Len = Prefix'Length
                  or else Buf (Prefix'Length + 1) = ASCII.LF);
   end State_Is;

   --  Poll Net:dhcp until the state is Name or the deadline
   --  (seconds) passes.
   function Wait_State (Name : String; Seconds : Natural)
                        return Boolean is
      Deadline : constant U64 :=
        Syscalls.Read_Time + U64 (Seconds) * Tick_Hz;
   begin
      loop
         Read_Net ("Net:dhcp");
         if State_Is (Name) then
            return True;
         elsif Syscalls.Read_Time >= Deadline then
            return False;
         end if;
         delay 0.05;
      end loop;
   end Wait_State;

   --  Op_Ping allows ONE outstanding request (a second caller
   --  draws status 2 = not ready); net_test's unreachable-target
   --  ping holds it for ~2 s and may overlap us. Retry through
   --  that window.
   function Ping (Target : U64) return U64 is
      Tries : Natural := 50;
   begin
      loop
         Syscalls.Message.Label := Op_Ping;
         Syscalls.Message.Words := (others => 0);
         Syscalls.Message.Words (0) := Target;
         Syscalls.Message.Caps := (others => 0);
         if Syscalls.IPC_Call (Net_EP) /= Syscalls.IPC_Ok then
            return U64'Last;
         end if;
         exit when Syscalls.Message.Words (0) /= 2
           or else Tries = 0;
         Tries := Tries - 1;
         delay 0.1;
      end loop;
      return Syscalls.Message.Words (0);
   end Ping;

begin
   Console.Set_Endpoint (Console_EP);
   Files.Bind (FS_Cap);

   --  Static default (2 s registration-window retry, as in
   --  gsock_test).
   declare
      Deadline : constant U64 := Syscalls.Read_Time + 2 * Tick_Hz;
   begin
      Read_Net ("Net:address");
      while Len = 0 and then Syscalls.Read_Time < Deadline loop
         delay 0.005;
         Read_Net ("Net:address");
      end loop;
   end;
   Expect (Renders ("10.0.2.15"), "static default address");

   Read_Net ("Net:dhcp");
   Expect (State_Is ("off"), "dhcp off by default");

   St := Write_Net ("Net:dhcp", "start");
   Expect (St = Files.Status_Ok, "dhcp start accepted");

   Expect (Wait_State ("bound", 5), "dhcp bound via slirp");

   Read_Net ("Net:address");
   Expect (Renders ("10.0.2.15"), "lease address 10.0.2.15");
   Read_Net ("Net:gateway");
   Expect (Renders ("10.0.2.2"), "lease gateway 10.0.2.2");

   St := Write_Net ("Net:address", "10.0.2.99");
   Expect (St /= Files.Status_Ok,
           "static write rejected while dhcp on");
   Read_Net ("Net:address");
   Expect (Renders ("10.0.2.15"), "lease kept after rejected write");

   Expect (Ping (16#0A00_0202#) = 0, "ping gateway on the lease");

   St := Write_Net ("Net:dhcp", "renew");
   Expect (St = Files.Status_Ok, "dhcp renew accepted");
   Expect (Wait_State ("bound", 3), "lease bound after renew");

   St := Write_Net ("Net:dhcp", "stop");
   Expect (St = Files.Status_Ok, "dhcp stop accepted");

   Read_Net ("Net:dhcp");
   Expect (State_Is ("off"), "dhcp off after stop");
   Read_Net ("Net:address");
   Expect (Renders ("10.0.2.15"), "static address restored");

   St := Write_Net ("Net:address", "10.0.2.15");
   Expect (St = Files.Status_Ok, "static write allowed after stop");

   Expect (Ping (16#0A00_0202#) = 0, "ping gateway after stop");

   if Failed then
      Console.Put_Line ("FAIL dhcp_test");
      Syscalls.Process_Exit (1);
   end if;
   Console.Put_Line ("PASS dhcp_test");
   Syscalls.Process_Exit (0);
end Dhcp_Test;
