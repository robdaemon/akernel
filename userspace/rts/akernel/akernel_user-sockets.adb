with System.Machine_Code;
with System.Storage_Elements;

package body Akernel_User.Sockets is
   use type U32;

   package Syscalls renames Akernel_User.Syscalls;

   Op_Socket  : constant U64 := 20;
   Op_Bind    : constant U64 := 21;
   Op_Connect : constant U64 := 22;
   Op_Kick    : constant U64 := 23;
   Op_Poll    : constant U64 := 24;
   Op_Close   : constant U64 := 25;
   Op_Listen  : constant U64 := 26;
   Op_Accept  : constant U64 := 27;

   --  Client-side bookkeeping: the netserv socket cap, the
   --  ring-pair object and the notification live as long as the
   --  socket.  m73: 4 -> 8; a GNAT.Sockets program easily holds a
   --  UDP pair plus a listener, connector and accepted child at
   --  once (gsock_test), four was tight.
   Max_Socks : constant := 8;

   Ring_Pages : constant U64 := 2;
   Ring_Bytes : constant U64 := Ring_Pages * Syscalls.Page_Size;

   --  Fixed VA window (clear of the Files buffer at
   --  16#4400_0000#, the args page at 16#4800_0000#, the link
   --  base at 16#4600_0000# and thread stacks at 16#6F00_0000#).
   Ring_VA_Base : constant U64 := 16#4A00_0000#;
   Ring_VA_Stride : constant U64 := 16#10_0000#;

   Slots        : constant U64 := 4;
   Slot_Size    : constant U64 := 1008;
   Max_Payload  : constant U64 := 996;
   Slot_Base    : constant U64 := 64;

   --  Recv/Send wait slice: 5 ms at the 10 MHz time base.
   Wait_Slice : constant U64 := 50_000;

   subtype U8 is Interfaces.Unsigned_8;
   use type U8;

   type Byte_Span is array (U64 range <>) of U8
     with Volatile_Components;
   type Ring_Words is array (U64 range 0 .. 3) of U64
     with Volatile_Components;

   type Client_Sock is record
      Used     : Boolean := False;
      Sock_Cap : U64 := 0;
      Ring_Cap : U64 := 0;
      Ntfn_Cap : U64 := 0;
      VA       : U64 := 0;
   end record;

   Socks : array (1 .. Max_Socks) of Client_Sock;
   Net_EP : U64 := 0;

   function To_Addr (VA : U64) return System.Address is
     (System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (VA)));

   function Find (Handle : U64) return Natural is
   begin
      for I in Socks'Range loop
         if Socks (I).Used and then Socks (I).Sock_Cap = Handle then
            return I;
         end if;
      end loop;
      return 0;
   end Find;

   procedure Fence is
   begin
      System.Machine_Code.Asm ("fence rw, rw", Volatile => True);
   end Fence;

   ------------------------------------------------------------------

   procedure Attach (Net_Cap : U64) is
   begin
      Net_EP := Net_Cap;
   end Attach;

   ------------------------------------------------------------------

   function Endpoint return U64 is
   begin
      return Net_EP;
   end Endpoint;

   function Socket (Proto : U64; Handle : out U64) return U64 is
      Idx       : Natural := 0;
      Ring_Mint : U64;
      Ntfn_Mint : U64;
      Result    : U64;
   begin
      Handle := 0;
      if Net_EP = 0
        or else (Proto /= IPPROTO_UDP and then Proto /= IPPROTO_ICMP
                 and then Proto /= IPPROTO_TCP)
      then
         return Status_Bad_Args;
      end if;
      for I in Socks'Range loop
         if not Socks (I).Used then
            Idx := I;
            exit;
         end if;
      end loop;
      if Idx = 0 then
         return Status_Not_Ready;
      end if;

      Socks (Idx).VA := Ring_VA_Base
        + U64 (Idx - 1) * Ring_VA_Stride;
      Socks (Idx).Ring_Cap := Syscalls.Mem_Alloc (Ring_Pages);
      Socks (Idx).Ntfn_Cap := Syscalls.Ntfn_Create;
      if Socks (Idx).Ring_Cap = Syscalls.Syscall_Failed
        or else Socks (Idx).Ntfn_Cap = Syscalls.Syscall_Failed
        or else Syscalls.Mem_Map
          (Syscalls.Address_Space_Cap, Socks (Idx).Ring_Cap,
           Socks (Idx).VA, 0, Ring_Bytes, 3) /= 0
      then
         return Status_Error;
      end if;

      --  Fresh pages are zeroed; make the ring reset explicit.
      declare
         Rx_Hdr : Ring_Words with Address => To_Addr (Socks (Idx).VA);
         Tx_Hdr : Ring_Words with Address =>
           To_Addr (Socks (Idx).VA + Syscalls.Page_Size);
      begin
         Rx_Hdr := (others => 0);
         Tx_Hdr := (others => 0);
      end;

      Ring_Mint := Syscalls.Cap_Mint
        (Socks (Idx).Ring_Cap,
         Syscalls.Right_Map + Syscalls.Right_Read
           + Syscalls.Right_Write + Syscalls.Right_Transfer, 0);
      Ntfn_Mint := Syscalls.Cap_Mint
        (Socks (Idx).Ntfn_Cap,
         Syscalls.Right_Write + Syscalls.Right_Transfer, 0);
      if Ring_Mint = Syscalls.Syscall_Failed
        or else Ntfn_Mint = Syscalls.Syscall_Failed
      then
         Result := Status_Error;
      else
         Syscalls.Message.Label := Op_Socket;
         Syscalls.Message.Words := (others => 0);
         Syscalls.Message.Words (0) := AF_INET;
         Syscalls.Message.Words (1) :=
           (if Proto = IPPROTO_TCP then SOCK_STREAM else SOCK_DGRAM);
         Syscalls.Message.Words (2) := Proto;
         Syscalls.Message.Caps := (0 => Ring_Mint, 1 => Ntfn_Mint,
                                   others => 0);
         if Syscalls.IPC_Call (Net_EP) /= Syscalls.IPC_Ok then
            Result := Status_Error;
         else
            Result := Syscalls.Message.Words (0);
         end if;
         if Syscalls.Cap_Delete (Ring_Mint) /= 0
           or else Syscalls.Cap_Delete (Ntfn_Mint) /= 0
         then
            Result := Status_Error;
         end if;
      end if;

      if Result = Status_Ok then
         --  Caps do not travel in replies: the id is the reply
         --  and the socket cap is a LOCAL mint of the service
         --  endpoint with badge = id (the server demultiplexes
         --  on Message.Badge).
         Socks (Idx).Sock_Cap := Syscalls.Cap_Mint
           (Net_EP, Syscalls.Right_Send, Syscalls.Message.Words (1));
         if Socks (Idx).Sock_Cap /= Syscalls.Syscall_Failed then
            Socks (Idx).Used := True;
            Handle := Socks (Idx).Sock_Cap;
            return Status_Ok;
         end if;
         Result := Status_Error;
      end if;

      declare
         Saved : constant U64 := Result;
      begin
         Result := Syscalls.Mem_Unmap
           (Syscalls.Address_Space_Cap, Socks (Idx).VA, Ring_Bytes);
         Result := Syscalls.Cap_Delete (Socks (Idx).Ring_Cap);
         Result := Syscalls.Cap_Delete (Socks (Idx).Ntfn_Cap);
         Socks (Idx).VA := 0;
         Socks (Idx).Ring_Cap := 0;
         Socks (Idx).Ntfn_Cap := 0;
         --  Keep the server's protocol status when there was one.
         return (if Saved = Status_Ok then Status_Error else Saved);
      end;
   end Socket;

   function Bind (Handle : U64; Port : U64; Assigned : out U64)
                  return U64
   is
   begin
      Assigned := 0;
      if Find (Handle) = 0 then
         return Status_Bad_Args;
      end if;
      Syscalls.Message.Label := Op_Bind;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Words (0) := Port;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (Handle) /= Syscalls.IPC_Ok then
         return Status_Error;
      end if;
      Assigned := Syscalls.Message.Words (1);
      return Syscalls.Message.Words (0);
   end Bind;

   function Connect (Handle : U64; IP : U32; Port : U64) return U64
   is
   begin
      if Find (Handle) = 0 then
         return Status_Bad_Args;
      end if;
      Syscalls.Message.Label := Op_Connect;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Words (0) := U64 (IP);
      Syscalls.Message.Words (1) := Port;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (Handle) /= Syscalls.IPC_Ok then
         return Status_Error;
      end if;
      return Syscalls.Message.Words (0);
   end Connect;

   function Listen (Handle : U64; Backlog : U64) return U64 is
   begin
      if Find (Handle) = 0 then
         return Status_Bad_Args;
      end if;
      Syscalls.Message.Label := Op_Listen;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Words (0) := Backlog;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (Handle) /= Syscalls.IPC_Ok then
         return Status_Error;
      end if;
      return Syscalls.Message.Words (0);
   end Listen;

   --  Accept_Connection mirrors Socket's setup: a fresh ring pair + client
   --  ntfn are transferred on the LISTENER's cap and the reply
   --  carries the child id; the child cap is a local mint with
   --  that badge. On any failure the local setup is torn down.
   function Accept_Connection
     (Handle     : U64;
      New_Handle : out U64;
      Peer_IP    : out U32;
      Peer_Port  : out U64) return U64
   is
      Idx       : Natural := 0;
      Ring_Mint : U64;
      Ntfn_Mint : U64;
      Result    : U64;
   begin
      New_Handle := 0;
      Peer_IP := 0;
      Peer_Port := 0;
      if Find (Handle) = 0 then
         return Status_Bad_Args;
      end if;
      for I in Socks'Range loop
         if not Socks (I).Used then
            Idx := I;
            exit;
         end if;
      end loop;
      if Idx = 0 then
         return Status_Not_Ready;
      end if;

      Socks (Idx).VA := Ring_VA_Base
        + U64 (Idx - 1) * Ring_VA_Stride;
      Socks (Idx).Ring_Cap := Syscalls.Mem_Alloc (Ring_Pages);
      Socks (Idx).Ntfn_Cap := Syscalls.Ntfn_Create;
      if Socks (Idx).Ring_Cap = Syscalls.Syscall_Failed
        or else Socks (Idx).Ntfn_Cap = Syscalls.Syscall_Failed
        or else Syscalls.Mem_Map
          (Syscalls.Address_Space_Cap, Socks (Idx).Ring_Cap,
           Socks (Idx).VA, 0, Ring_Bytes, 3) /= 0
      then
         return Status_Error;
      end if;
      declare
         Rx_Hdr : Ring_Words with Address => To_Addr (Socks (Idx).VA);
         Tx_Hdr : Ring_Words with Address =>
           To_Addr (Socks (Idx).VA + Syscalls.Page_Size);
      begin
         Rx_Hdr := (others => 0);
         Tx_Hdr := (others => 0);
      end;

      Ring_Mint := Syscalls.Cap_Mint
        (Socks (Idx).Ring_Cap,
         Syscalls.Right_Map + Syscalls.Right_Read
           + Syscalls.Right_Write + Syscalls.Right_Transfer, 0);
      Ntfn_Mint := Syscalls.Cap_Mint
        (Socks (Idx).Ntfn_Cap,
         Syscalls.Right_Write + Syscalls.Right_Transfer, 0);
      if Ring_Mint = Syscalls.Syscall_Failed
        or else Ntfn_Mint = Syscalls.Syscall_Failed
      then
         Result := Status_Error;
      else
         Syscalls.Message.Label := Op_Accept;
         Syscalls.Message.Words := (others => 0);
         Syscalls.Message.Caps := (0 => Ring_Mint, 1 => Ntfn_Mint,
                                   others => 0);
         if Syscalls.IPC_Call (Handle) /= Syscalls.IPC_Ok then
            Result := Status_Error;
         else
            Result := Syscalls.Message.Words (0);
         end if;
         if Syscalls.Cap_Delete (Ring_Mint) /= 0
           or else Syscalls.Cap_Delete (Ntfn_Mint) /= 0
         then
            Result := Status_Error;
         end if;
      end if;

      if Result = Status_Ok then
         Peer_IP   := U32 (Syscalls.Message.Words (2));
         Peer_Port := Syscalls.Message.Words (3);
         Socks (Idx).Sock_Cap := Syscalls.Cap_Mint
           (Net_EP, Syscalls.Right_Send, Syscalls.Message.Words (1));
         if Socks (Idx).Sock_Cap /= Syscalls.Syscall_Failed then
            Socks (Idx).Used := True;
            New_Handle := Socks (Idx).Sock_Cap;
            return Status_Ok;
         end if;
         Result := Status_Error;
      end if;

      declare
         Saved : constant U64 := Result;
      begin
         Result := Syscalls.Mem_Unmap
           (Syscalls.Address_Space_Cap, Socks (Idx).VA, Ring_Bytes);
         Result := Syscalls.Cap_Delete (Socks (Idx).Ring_Cap);
         Result := Syscalls.Cap_Delete (Socks (Idx).Ntfn_Cap);
         Socks (Idx).VA := 0;
         Socks (Idx).Ring_Cap := 0;
         Socks (Idx).Ntfn_Cap := 0;
         return (if Saved = Status_Ok then Status_Error else Saved);
      end;
   end Accept_Connection;

   function Send_To
     (Handle : U64;
      Data   : System.Address;
      Len    : U64;
      IP     : U32;
      Port   : U64) return U64
   is
      Idx  : constant Natural := Find (Handle);
      Src  : Byte_Span (0 .. Len - 1) with Address => Data;
      Head : U64;
      Tail : U64;
      Base : U64;
      Slot : U64;
      Deadline : U64;
   begin
      if Idx = 0 or else Len = 0 or else Len > Max_Payload then
         return Status_Bad_Args;
      end if;
      Base := Socks (Idx).VA + Syscalls.Page_Size;
      Deadline := Syscalls.Read_Time + Wait_Slice * 100;  --  0.5 s
      loop
         declare
            Hdr : Ring_Words with Address => To_Addr (Base);
         begin
            Head := Hdr (0);
            Tail := Hdr (1);
         end;
         exit when Head - Tail < Slots;
         if Syscalls.Read_Time >= Deadline then
            return Status_Not_Ready;
         end if;
         if Syscalls.Sleep_Until
              (Syscalls.Read_Time + Wait_Slice) /= 0
         then
            return Status_Error;
         end if;
      end loop;

      Slot := Base + Slot_Base + (Head mod Slots) * Slot_Size;
      declare
         Mem : Byte_Span (0 .. Slot_Size - 1)
           with Address => To_Addr (Slot);
      begin
         Mem (0) := U8 (Len mod 256);
         Mem (1) := U8 (Len / 256);
         Mem (2) := 0;
         Mem (3) := 0;
         for I in 0 .. 3 loop
            Mem (4 + U64 (I)) := U8 (Interfaces.Shift_Right (IP, 24 - I * 8)
                                     and 16#FF#);
            Mem (8 + U64 (I)) := U8 (Interfaces.Shift_Right
                                       (Port, 24 - I * 8) and 16#FF#);
         end loop;
         for I in 0 .. Len - 1 loop
            Mem (12 + I) := Src (I);
         end loop;
      end;
      Fence;
      declare
         Hdr : Ring_Words with Address => To_Addr (Base);
      begin
         Hdr (0) := Head + 1;
      end;

      Syscalls.Message.Label := Op_Kick;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Caps := (others => 0);
      --  m72b: the kick rides a Call, not a one-way Send. A Send
      --  queues a message copy that Receive serves AFTER any
      --  pending call, so a client's following Poll could be
      --  serviced before the drain ran (the "udp closed port"
      --  flake whenever a concurrent Op_Ping kept netserv off
      --  its endpoint). Calls are FIFO among themselves.
      if Syscalls.IPC_Call (Handle) /= Syscalls.IPC_Ok then
         return Status_Error;
      end if;
      return Syscalls.Message.Words (0);
   end Send_To;

   function Recv_From
     (Handle   : U64;
      Buf      : System.Address;
      Max      : U64;
      Timeout  : U64;
      Src_IP   : out U32;
      Src_Port : out U64;
      Count    : out U64) return U64
   is
      Idx      : constant Natural := Find (Handle);
      Base     : U64;
      Head     : U64;
      Tail     : U64;
      Slot     : U64;
      Len      : U64;
      Deadline : U64;
      Now      : U64;
   begin
      Src_IP := 0;
      Src_Port := 0;
      Count := 0;
      if Idx = 0 then
         return Status_Bad_Args;
      end if;
      Base := Socks (Idx).VA;
      Deadline := Syscalls.Read_Time + Timeout;
      loop
         declare
            Hdr : Ring_Words with Address => To_Addr (Base);
         begin
            Head := Hdr (0);
            Tail := Hdr (1);
         end;
         if Tail /= Head then
            Fence;
            Slot := Base + Slot_Base + (Tail mod Slots) * Slot_Size;
            declare
               Mem : Byte_Span (0 .. Slot_Size - 1)
                 with Address => To_Addr (Slot);
               Dst : Byte_Span (0 .. Max - 1) with Address => Buf;
               Flags : U64;
            begin
               Len := U64 (Mem (0)) + U64 (Mem (1)) * 256;
               Flags := U64 (Mem (2)) + U64 (Mem (3)) * 256;
               for I in 0 .. 3 loop
                  Src_IP := Src_IP * 256 + U32 (Mem (4 + U64 (I)));
                  Src_Port := Src_Port * 256 + U64 (Mem (8 + U64 (I)));
               end loop;
               Count := U64'Min (Len, Max);
               --  Count may be 0 (m72c EOF marker slot, or an
               --  empty datagram): 0 - 1 would wrap the modular
               --  index and the loop would run off the slot.
               if Count > 0 then
                  for I in 0 .. Count - 1 loop
                     Dst (I) := Mem (12 + I);
                  end loop;
               end if;
               declare
                  Hdr : Ring_Words with Address => To_Addr (Base);
               begin
                  Hdr (1) := Tail + 1;
               end;
               if (Flags and 1) /= 0 then
                  --  m72c EOF marker (peer FIN / reset): report
                  --  Status_Ok with Count = 0.
                  Count := 0;
               end if;
               return Status_Ok;
            end;
         end if;
         Now := Syscalls.Read_Time;
         if Timeout = 0 or else Now >= Deadline then
            return Status_Timeout;
         end if;
         if Syscalls.Sleep_Until
              (U64'Min (Deadline, Now + Wait_Slice)) /= 0
         then
            return Status_Error;
         end if;
      end loop;
   end Recv_From;

   function Poll
     (Handle   : U64;
      Rx_Level : out U64;
      Tx_Free  : out U64;
      Error    : out U64) return U64
   is
   begin
      Rx_Level := 0;
      Tx_Free := 0;
      Error := 0;
      if Find (Handle) = 0 then
         return Status_Bad_Args;
      end if;
      Syscalls.Message.Label := Op_Poll;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (Handle) /= Syscalls.IPC_Ok then
         return Status_Error;
      end if;
      Rx_Level := Syscalls.Message.Words (1);
      Tx_Free := Syscalls.Message.Words (2);
      Error := Syscalls.Message.Words (3);
      return Syscalls.Message.Words (0);
   end Poll;

   function Close (Handle : U64) return U64 is
      Idx    : constant Natural := Find (Handle);
      Status : U64 := Status_Bad_Args;
      Result : U64;
   begin
      if Idx = 0 then
         return Status_Bad_Args;
      end if;
      Syscalls.Message.Label := Op_Close;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (Handle) = Syscalls.IPC_Ok then
         Status := Syscalls.Message.Words (0);
      else
         Status := Status_Error;
      end if;
      Result := Syscalls.Mem_Unmap
        (Syscalls.Address_Space_Cap, Socks (Idx).VA, Ring_Bytes);
      Result := Syscalls.Cap_Delete (Socks (Idx).Ring_Cap);
      Result := Syscalls.Cap_Delete (Socks (Idx).Ntfn_Cap);
      Result := Syscalls.Cap_Delete (Socks (Idx).Sock_Cap);
      Socks (Idx) := (others => <>);
      return Status;
   end Close;

   function Parse_IP (Text : String; IP : out U32) return Boolean is
      Parts : array (0 .. 3) of U32 := (others => 0);
      P     : Natural := 0;
      Dig   : Boolean := False;
   begin
      IP := 0;
      for C of Text loop
         if C = '.' then
            if not Dig or else P = 3 then
               return False;
            end if;
            P := P + 1;
            Dig := False;
         elsif C in '0' .. '9' then
            Parts (P) := Parts (P) * 10
              + U32 (Character'Pos (C) - Character'Pos ('0'));
            if Parts (P) > 255 then
               return False;
            end if;
            Dig := True;
         elsif C = Character'Val (10) or else C = Character'Val (13) then
            exit;
         else
            return False;
         end if;
      end loop;
      if P /= 3 or else not Dig then
         return False;
      end if;
      IP := Parts (0) * 2 ** 24 + Parts (1) * 2 ** 16
        + Parts (2) * 2 ** 8 + Parts (3);
      return True;
   end Parse_IP;

   function Ip_Image (IP : U32) return String is
      function Dec (V : U32) return String is
         Digs : String (1 .. 10);
         Len  : Natural := 0;
         X    : U32 := V;
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
   begin
      return Dec (IP / 2 ** 24) & "." & Dec ((IP / 2 ** 16) mod 256)
        & "." & Dec ((IP / 2 ** 8) mod 256) & "." & Dec (IP mod 256);
   end Ip_Image;

end Akernel_User.Sockets;
