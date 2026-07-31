with Ada.Streams;
with Akernel_User.MMIO;
with Akernel_User.Syscalls;
with Akernel_User.IPC;
with Akernel_User.Streams;

--  Console server: holds the UART MMIO cap and the Receive cap on
--  the init-minted console endpoint; clients print through
--  Akernel_User.Streams / Akernel_User.Console (write ops arrive as
--  stream-protocol messages). UART RX is drained opportunistically
--  on each write (single thread cannot wait on both the IRQ line and
--  the endpoint); IRQ-driven RX waits on notification objects.

procedure Serial is
   use Akernel_User.Syscalls;
   use type U64;
   use type Akernel_User.MMIO.U8;

   UART_MMIO_Cap : constant U64 := 1;
   Console_EP    : constant U64 := 2;
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

   --  Echo any pending input; opportunistic (no IRQ wait).
   procedure Drain_RX is
   begin
      loop
         Reg := Akernel_User.MMIO.Read8 (LSR);
         exit when (Reg and LSR_DR) = 0;
         Reg := Akernel_User.MMIO.Read8 (RBR);
         Akernel_User.MMIO.Write8 (THR, Reg);
      end loop;
   end Drain_RX;
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

   loop
      Status := RPC.Receive (Console_EP, Label, Request, Badge, Caps);
      exit when Status /= IPC_Ok;

      Drain_RX;

      if Label = Akernel_User.Streams.Op_Write then
         for I in 1 .. Ada.Streams.Stream_Element_Offset (Request.Count) loop
            Akernel_User.MMIO.Write8
              (THR, Akernel_User.MMIO.U8 (Request.Data (I)));
         end loop;
         Response := (Count => Request.Count, Data => (others => 0));
      else
         --  Op_Read and unknown ops: console is output-only, no data.
         Response := (Count => 0, Data => (others => 0));
      end if;

      Status := RPC.Reply (Label, Response);
      exit when Status /= IPC_Ok;
   end loop;

   Debug_Put_Line ("console server error exit");
   Process_Exit;
end Serial;
