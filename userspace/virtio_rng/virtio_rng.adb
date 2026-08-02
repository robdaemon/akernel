with System;
with System.Storage_Elements;
with Interfaces;
with Akernel_User.Console;
with Akernel_User.Syscalls;
with Virtio;
with Virtio.MMIO;
with Virtio.Queues;

--  Virtio RNG driver (device id 4 over the MMIO transport). Spawned
--  by init's device manager when a virtio,mmio DTB node probes to
--  class 4. Handle ABI (grant order): 1 = console endpoint (Send),
--  2 = device MMIO cap, 3 = IRQ cap (unused; entropy polls the used
--  ring). Requests the default 16 bytes of entropy at boot and
--  proves the full pipeline (io_map -> probe -> spawn -> DMA ->
--  doorbell -> completion), then stays resident as the future
--  entropy server.

procedure Virtio_RNG is
   use Akernel_User.Syscalls;
   use type U64;
   use type Virtio.U16;
   use type Virtio.U32;

   subtype U8 is Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_8;

   Console_EP : constant U64 := 1;
   MMIO_Cap   : constant U64 := 2;

   MMIO_VA : constant U64 := 16#5000_0000#;
   DMA_VA  : constant U64 := 16#5004_0000#;
   --  DMA object layout: page 0 descriptors, page 1 avail ring,
   --  page 2 used ring, page 3 entropy buffer.
   DMA_Pages : constant U64 := 4;

   Entropy_Len : constant Virtio.U32 := 16;

   ------------------------------------------------------------------
   --  Device register access over the mapped MMIO page
   ------------------------------------------------------------------

   type Reg_File is array (U64 range 0 .. 1023) of Virtio.U32
     with Volatile_Components;

   Regs : Reg_File
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (MMIO_VA));

   function Reg_Read (Offset : U64) return Virtio.U32 is
   begin
      return Regs (Offset / 4);
   end Reg_Read;

   procedure Reg_Write (Offset : U64; Value : Virtio.U32) is
   begin
      Regs (Offset / 4) := Value;
   end Reg_Write;

   package Dev is new Virtio.MMIO (Reg_Read, Reg_Write);

   ------------------------------------------------------------------

   type Byte_Array is array (Natural range 0 .. 4095) of U8
     with Volatile_Components;

   Data_Page : Byte_Array
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (DMA_VA + 3 * 4096));

   Hex : constant String := "0123456789abcdef";

   Result   : U64;
   DMA_Cap  : U64;
   Desc_PA  : U64;
   Avail_PA : U64;
   Used_PA  : U64;
   Data_PA  : U64;
   Q        : Virtio.Queues.Queue;
   D        : Virtio.U16;
   Head     : Virtio.U16;
   Written  : Virtio.U32;
   Spins    : Natural;
   All_Zero : Boolean;
   Line     : String (1 .. 34);
begin
   Akernel_User.Console.Set_Endpoint (Console_EP);

   Result := Map_MMIO
     (Address_Space => Address_Space_Cap,
      Cap           => MMIO_Cap,
      VA            => MMIO_VA,
      Offset        => 0,
      Length        => 4096,
      Flags         => 3);

   if Result /= 0 then
      Debug_Put_Line ("virtio-rng map mmio failed");
      Process_Exit;
   end if;

   if not Dev.Magic_Ok then
      Debug_Put_Line ("virtio-rng bad magic");
      Process_Exit;
   end if;

   if Dev.Version = 1 then
      Debug_Put_Line ("virtio-rng version 1 (legacy)");
      Process_Exit;
   end if;

   if Dev.Version /= 2 then
      Debug_Put_Line ("virtio-rng bad version");
      Process_Exit;
   end if;

   if Dev.Device_ID /= Virtio.Device_RNG then
      Debug_Put_Line ("virtio-rng bad device id");
      Process_Exit;
   end if;

   Dev.Reset;
   Dev.Set_Status (Virtio.Status_Acknowledge);
   Dev.Add_Status (Virtio.Status_Driver);
   Dev.Set_Driver_Features (0);
   Dev.Add_Status (Virtio.Status_Features_Ok);

   if (Dev.Status and Virtio.Status_Features_Ok) = 0 then
      Debug_Put_Line ("virtio-rng features rejected");
      Process_Exit;
   end if;

   --  DMA memory: one 4-page object, mapped locally, PAs queried
   --  per page for the device-side addresses.
   DMA_Cap := Mem_Alloc (DMA_Pages);
   if DMA_Cap = Syscall_Failed then
      Debug_Put_Line ("virtio-rng dma alloc failed");
      Process_Exit;
   end if;

   Result := Mem_Map
     (Address_Space => Address_Space_Cap,
      Cap           => DMA_Cap,
      VA            => DMA_VA,
      Offset        => 0,
      Length        => DMA_Pages * 4096,
      Flags         => 3);
   if Result /= 0 then
      Debug_Put_Line ("virtio-rng dma map failed");
      Process_Exit;
   end if;

   Desc_PA  := Mem_Object_PA (DMA_Cap, 0);
   Avail_PA := Mem_Object_PA (DMA_Cap, 1);
   Used_PA  := Mem_Object_PA (DMA_Cap, 2);
   Data_PA  := Mem_Object_PA (DMA_Cap, 3);
   if Desc_PA = 0 or else Avail_PA = 0
     or else Used_PA = 0 or else Data_PA = 0
   then
      Debug_Put_Line ("virtio-rng dma pa query failed");
      Process_Exit;
   end if;

   Virtio.Queues.Initialize
     (Q     => Q,
      Desc  => System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address (DMA_VA)),
      Avail => System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address (DMA_VA + 4096)),
      Used  => System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address (DMA_VA + 2 * 4096)),
      Num   => 8);

   Dev.Queue_Select (0);
   Dev.Queue_Setup
     (Num      => 8,
      Desc_PA  => Desc_PA,
      Avail_PA => Avail_PA,
      Used_PA  => Used_PA);
   Dev.Add_Status (Virtio.Status_Driver_Ok);

   --  One entropy request: a single device-writable descriptor
   --  covering 16 bytes of the data page.
   D := Virtio.Queues.Alloc (Q);
   Virtio.Queues.Set_Buffer
     (Q, D, Data_PA, Entropy_Len, Device_Writes => True);
   Virtio.Queues.Submit (Q, D);
   Dev.Notify (0);

   Spins := 0;
   while not Virtio.Queues.Has_Completed (Q) loop
      Spins := Spins + 1;
      if Spins > 10_000 then
         Debug_Put_Line ("virtio-rng completion timeout");
         Process_Exit;
      end if;
      Yield;
   end loop;

   Virtio.Queues.Pop (Q, Head, Written);

   All_Zero := True;
   for I in 0 .. Natural (Entropy_Len) - 1 loop
      if Data_Page (I) /= 0 then
         All_Zero := False;
         exit;
      end if;
   end loop;

   if Written = Entropy_Len and then not All_Zero then
      Akernel_User.Console.Put_Line ("PASS virtio-rng entropy ok");
   else
      Akernel_User.Console.Put_Line ("FAIL virtio-rng entropy bad data");
   end if;

   Line (1 .. 2) := "  ";
   for I in 0 .. Natural (Entropy_Len) - 1 loop
      Line (3 + I * 2) :=
        Hex (1 + Natural (Data_Page (I) / 16));
      Line (4 + I * 2) :=
        Hex (1 + Natural (Data_Page (I) mod 16));
   end loop;
   Akernel_User.Console.Put_Line ("virtio-rng entropy: " & Line);

   Virtio.Queues.Free (Q, D);

   --  Resident as the future entropy server.
   loop
      Yield;
   end loop;
end Virtio_RNG;
