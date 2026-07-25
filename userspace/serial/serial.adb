with Akernel_User.MMIO;
with Akernel_User.Syscalls;

procedure Serial is
   use type Akernel_User.MMIO.U8;
   use type Akernel_User.Syscalls.U64;

   UART_MMIO_Cap : constant Akernel_User.Syscalls.U64 := 1;
   UART_IRQ_Cap  : constant Akernel_User.Syscalls.U64 := 2;
   UART_Base     : constant Akernel_User.MMIO.U64 := 16#5000_0000#;
   Page_Size     : constant Akernel_User.Syscalls.U64 := 4096;

   RBR : constant Akernel_User.MMIO.U64 := UART_Base + 0;
   THR : constant Akernel_User.MMIO.U64 := UART_Base + 0;
   LSR : constant Akernel_User.MMIO.U64 := UART_Base + 5;

   LSR_DR : constant Akernel_User.MMIO.U8 := 16#01#;

   Result : Akernel_User.Syscalls.U64;
   Status : Akernel_User.MMIO.U8;
   C      : Akernel_User.MMIO.U8;

   procedure Put (S : String) is
   begin
      for Ch of S loop
         Akernel_User.MMIO.Write8 (THR, Character'Pos (Ch));
      end loop;
   end Put;

   procedure Put_Line (S : String) is
   begin
      Put (S);
      Akernel_User.MMIO.Write8 (THR, Character'Pos (Character'Val (10)));
   end Put_Line;

   procedure Drain_RX is
   begin
      loop
         Status := Akernel_User.MMIO.Read8 (LSR);
         exit when (Status and LSR_DR) = 0;

         C := Akernel_User.MMIO.Read8 (RBR);
         Akernel_User.MMIO.Write8 (THR, C);
      end loop;
   end Drain_RX;
begin
   Result := Akernel_User.Syscalls.Map_MMIO
     (Address_Space => Akernel_User.Syscalls.Address_Space_Cap,
      Cap           => UART_MMIO_Cap,
      VA            => Akernel_User.Syscalls.U64 (UART_Base),
      Offset        => 0,
      Length        => Page_Size,
      Flags         => 3);

   if Result = 0 then
      Put_Line ("serial driver online");
      Akernel_User.Syscalls.Yield;
   else
      Akernel_User.Syscalls.Debug_Put_Line ("serial map mmio failed");
   end if;

   loop
      Result := Akernel_User.Syscalls.IRQ_Wait (UART_IRQ_Cap);
      if Result = 0 then
         Drain_RX;
         Result := Akernel_User.Syscalls.IRQ_Ack (UART_IRQ_Cap);
      else
         Akernel_User.Syscalls.Yield;
      end if;
   end loop;
end Serial;
