with Akernel_User.Syscalls;

procedure Init is
   use type Akernel_User.Syscalls.U64;

   Result : Akernel_User.Syscalls.U64;
begin
   Akernel_User.Syscalls.Debug_Put_Line ("init online from Ada");
   Result := Akernel_User.Syscalls.Boot_File_Size
     (Akernel_User.Syscalls.Boot_Manifest_File);
   if Result /= Akernel_User.Syscalls.Syscall_Failed then
      Akernel_User.Syscalls.Debug_Put_Line ("boot manifest visible");
   end if;
   Akernel_User.Syscalls.Debug_Put_Line ("launching serial driver");

   Result := Akernel_User.Syscalls.Spawn_Program
     (1,
      Akernel_User.Syscalls.UART_MMIO_Grant_Bit
        or Akernel_User.Syscalls.UART_IRQ_Grant_Bit);
   if Result /= 0 then
      Akernel_User.Syscalls.Debug_Put_Line ("serial spawned");
      Akernel_User.Syscalls.Yield;
      Akernel_User.Syscalls.Debug_Put_Line ("init resumed");
   else
      Akernel_User.Syscalls.Debug_Put_Line ("serial spawn failed");
   end if;

   loop
      Akernel_User.Syscalls.Yield;
   end loop;
end Init;
