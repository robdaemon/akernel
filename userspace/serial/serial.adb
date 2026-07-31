with Ada.Streams;
with Akernel_User.MMIO;
with Akernel_User.Syscalls;
with Akernel_User.IPC;
with Akernel_User.Streams;

--  Console server: holds the UART MMIO cap and the Receive cap on
--  the init-minted console endpoint; clients print through
--  Akernel_User.Streams / Akernel_User.Console (write ops arrive as
--  stream-protocol messages). Writes are line-atomic: bytes
--  accumulate in a per-client buffer (keyed by the console cap
--  badge, which init sets to the manifest program id) and only hit
--  the UART on newline or a full buffer, so concurrent clients'
--  lines never interleave. Partial lines flush lazily (a full
--  buffer) or not at all if a client exits mid-line.
--  UART RX is IRQ-driven through a thread-bound notification:
--  the UART IRQ line signals it (irq_bind_ntfn), the server's
--  IPC_Recv wakes with a synthetic message (Notification_Label),
--  the server drains and acks.

procedure Serial is
   use Akernel_User.Syscalls;
   use type U64;
   use type Akernel_User.MMIO.U8;

   --  Grant order follows the manifest token order.
   UART_MMIO_Cap : constant U64 := 1;
   UART_IRQ_Cap  : constant U64 := 2;
   Console_EP    : constant U64 := 3;
   UART_Base     : constant Akernel_User.MMIO.U64 := 16#5000_0000#;
   Page_Size     : constant U64 := 4096;

   RBR : constant Akernel_User.MMIO.U64 := UART_Base + 0;
   THR : constant Akernel_User.MMIO.U64 := UART_Base + 0;
   LSR : constant Akernel_User.MMIO.U64 := UART_Base + 5;

   LSR_DR : constant Akernel_User.MMIO.U8 := 16#01#;

   package RPC is new Akernel_User.IPC
     (Akernel_User.Streams.Stream_Request,
      Akernel_User.Streams.Stream_Response);

   Result : U64;
   Status : U64;
   Label  : U64;
   Badge  : U64;
   Reg    : Akernel_User.MMIO.U8;
   Ntfn   : U64;

   Request  : Akernel_User.Streams.Stream_Request;
   Response : Akernel_User.Streams.Stream_Response;
   Caps     : RPC.Cap_Array;

   procedure UART_Put (S : String) is
   begin
      for Ch of S loop
         Akernel_User.MMIO.Write8 (THR, Character'Pos (Ch));
      end loop;
   end UART_Put;

   procedure UART_Put_Line (S : String) is
   begin
      UART_Put (S);
      Akernel_User.MMIO.Write8 (THR, Character'Pos (Character'Val (10)));
   end UART_Put_Line;

   --  Drain input (echo back); interrupt clears once RBR is empty.
   procedure Drain_RX is
   begin
      loop
         Reg := Akernel_User.MMIO.Read8 (LSR);
         exit when (Reg and LSR_DR) = 0;
         Reg := Akernel_User.MMIO.Read8 (RBR);
         Akernel_User.MMIO.Write8 (THR, Reg);
      end loop;
   end Drain_RX;

   --  Per-client line buffers (line-atomic writes): a client's
   --  bytes only reach the UART on newline or a full buffer.
   Max_Clients : constant := 8;
   Line_Max    : constant := 160;

   type Client_Line is record
      Badge : U64 := U64'Last;
      Buf   : String (1 .. Line_Max);
      Len   : Natural := 0;
   end record;

   Lines : array (1 .. Max_Clients) of Client_Line;

   procedure Flush_Line (Slot : Positive) is
   begin
      if Lines (Slot).Len > 0 then
         UART_Put (Lines (Slot).Buf (1 .. Lines (Slot).Len));
         Lines (Slot).Len := 0;
      end if;
   end Flush_Line;

   procedure Buffer_Write (Badge : U64; Ch : Character) is
      Slot : Natural := 0;
      Free : Natural := 0;
   begin
      for I in Lines'Range loop
         if Lines (I).Badge = Badge then
            Slot := I;
            exit;
         elsif Lines (I).Badge = U64'Last and then Free = 0 then
            Free := I;
         end if;
      end loop;

      if Slot = 0 then
         if Free = 0 then
            --  Table full: bypass buffering rather than drop bytes.
            Akernel_User.MMIO.Write8 (THR, Character'Pos (Ch));
            return;
         end if;
         Slot := Free;
         Lines (Slot).Badge := Badge;
         Lines (Slot).Len := 0;
      end if;

      if Lines (Slot).Len = Line_Max then
         Flush_Line (Slot);
      end if;

      Lines (Slot).Len := Lines (Slot).Len + 1;
      Lines (Slot).Buf (Lines (Slot).Len) := Ch;

      if Ch = Character'Val (10) then
         Flush_Line (Slot);
      end if;
   end Buffer_Write;
begin
   Result := Map_MMIO
     (Address_Space => Address_Space_Cap,
      Cap           => UART_MMIO_Cap,
      VA            => Akernel_User.Syscalls.U64 (UART_Base),
      Offset        => 0,
      Length        => Page_Size,
      Flags         => 3);

   if Result /= 0 then
      Debug_Put_Line ("serial map mmio failed");
      Process_Exit;
   end if;

   UART_Put_Line ("console server online");

   --  IRQ-driven RX: a thread-bound notification signaled by the
   --  UART IRQ line; IPC_Recv delivers it as a synthetic message.
   Ntfn := Ntfn_Create;
   if Ntfn = Syscall_Failed
     or else Ntfn_Bind_Thread (Ntfn) /= 0
     or else IRQ_Bind_Ntfn (UART_IRQ_Cap, Ntfn, 1) /= 0
   then
      Debug_Put_Line ("serial ntfn setup failed");
      Process_Exit;
   end if;

   loop
      Status := RPC.Receive (Console_EP, Label, Request, Badge, Caps);
      exit when Status /= IPC_Ok;

      if Label = Notification_Label then
         --  UART RX interrupt: input waiting in RBR. No reply cap
         --  rides a synthetic message, so nothing to reply to.
         Drain_RX;
         Result := IRQ_Ack (UART_IRQ_Cap);
      else
         Drain_RX;

         if Label = Akernel_User.Streams.Op_Write then
            for I in 1 .. Ada.Streams.Stream_Element_Offset (Request.Count) loop
               Buffer_Write
                 (Badge, Character'Val (Natural (Request.Data (I))));
            end loop;
            Response := (Count => Request.Count, Data => (others => 0));
         else
            --  Op_Read and unknown ops: console is output-only, no data.
            Response := (Count => 0, Data => (others => 0));
         end if;

         Status := RPC.Reply (Label, Response);
         exit when Status /= IPC_Ok;
      end if;
   end loop;

   Debug_Put_Line ("console server error exit");
   Process_Exit;
end Serial;
