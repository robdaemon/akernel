with Akernel_User.Console;
with Akernel_User.Syscalls;
with Interfaces;
with System.Storage_Elements;

--  System/Partmgr: GPT partition layer between the virtio-blk
--  driver and the filesystem drivers. Holds the blk service
--  endpoint (Send) and one partition service endpoint (Receive);
--  clients select the partition by the badge on their Send cap
--  (init grants `partN` tokens with badge 16#1000#+N).
--
--  Serves the same block protocol as the blk driver (0 info,
--  1 read, 2 write) with sector offset translation and bounds
--  checks; request buffer caps are forwarded zero-copy to the blk
--  driver and the local copy is cap_delete'd after each op.
--
--  Probe: GPT header at LBA 1 ("EFI PART", entry array walk, up
--  to 8 non-empty entries become slots in order). Without a GPT
--  header slot 0 maps the whole device (legacy superfloppy
--  images keep working).
--
--  Handles: 1 = console endpoint, 2 = blk service EP, 3 = part
--  service EP.

procedure Partmgr is
   package Syscalls renames Akernel_User.Syscalls;
   subtype U64 is Syscalls.U64;
   use type U64;
   use type Interfaces.Unsigned_8;
   use System.Storage_Elements;

   Console_Cap : constant U64 := 1;
   Blk_EP      : constant U64 := 2;
   Svc_EP      : constant U64 := 3;

   Blk_Info  : constant U64 := 0;
   Blk_Read  : constant U64 := 1;
   Blk_Write : constant U64 := 2;

   Max_Parts   : constant := 8;
   Badge_Base  : constant U64 := 16#1000#;

   Blk_Buf_VA : constant U64 := 16#5000_0000#;

   type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;
   Bounce : Byte_Array (0 .. Syscalls.Page_Size - 1)
     with Address => To_Address (Integer_Address (Blk_Buf_VA));

   Blk_Buf_Cap : U64 := 0;
   Capacity    : U64 := 0;  --  whole device, sectors

   First_LBA : array (0 .. Max_Parts - 1) of U64 := (others => 0);
   Part_Size : array (0 .. Max_Parts - 1) of U64 := (others => 0);

   function LE16 (Off : U64) return U64 is
     (U64 (Bounce (Off)) + U64 (Bounce (Off + 1)) * 256);

   function LE32 (Off : U64) return U64 is
     (LE16 (Off) + LE16 (Off + 2) * 16#1_0000#);

   function LE64 (Off : U64) return U64 is
     (LE32 (Off) + LE32 (Off + 4) * 16#1_0000_0000#);

   procedure Fail (Msg : String) is
   begin
      Akernel_User.Console.Put_Line (Msg);
      Syscalls.Process_Exit;
   end Fail;

   function Blk_Read_Sectors (Sector : U64; Count : U64) return Boolean is
   begin
      Syscalls.Message.Label := Blk_Read;
      Syscalls.Message.Words (0) := Sector;
      Syscalls.Message.Words (1) := Count;
      Syscalls.Message.Caps := (0 => Blk_Buf_Cap, others => 0);
      return Syscalls.IPC_Call (Blk_EP) = Syscalls.IPC_Ok
        and then Syscalls.Message.Words (0) = 0;
   end Blk_Read_Sectors;

   --  GPT probe: LBA 1 header, entry array walk, first 8 non-empty
   --  entries become slots. Without a valid header slot 0 covers
   --  the whole device.
   procedure Probe is
      Num_Entries : U64;
      Entry_Size  : U64;
      Array_LBA   : U64;
      Slot        : Natural := 0;
      Ent         : U64;
      Sector      : U64;
      Off         : U64;
      Empty       : Boolean;
   begin
      if not Blk_Read_Sectors (1, 1) then
         Fail ("partmgr gpt probe read failed");
      end if;

      if Bounce (0) = 16#45#    --  'E'
        and then Bounce (1) = 16#46#  --  'F'
        and then Bounce (2) = 16#49#  --  'I'
        and then Bounce (3) = 16#20#  --  ' '
        and then Bounce (4) = 16#50#  --  'P'
        and then Bounce (5) = 16#41#  --  'A'
        and then Bounce (6) = 16#52#  --  'R'
        and then Bounce (7) = 16#54#  --  'T'
      then
         Array_LBA := LE64 (72);
         Num_Entries := LE32 (80);
         Entry_Size := LE32 (84);
         if Num_Entries > 512 or else Entry_Size /= 128 then
            Fail ("partmgr unsupported gpt layout");
         end if;

         Ent := 0;
         while Ent < Num_Entries and then Slot < Max_Parts loop
            Sector := Array_LBA + (Ent * Entry_Size) / 512;
            Off := (Ent * Entry_Size) mod 512;

            if not Blk_Read_Sectors (Sector, 1) then
               Fail ("partmgr gpt entry read failed");
            end if;

            Empty := True;
            for J in 0 .. 15 loop
               if Bounce (Off + U64 (J)) /= 0 then
                  Empty := False;
                  exit;
               end if;
            end loop;

            if not Empty then
               First_LBA (Slot) := LE64 (Off + 32);
               Part_Size (Slot) := LE64 (Off + 40) - LE64 (Off + 32) + 1;
               Slot := Slot + 1;
            end if;
            Ent := Ent + 1;
         end loop;

         Akernel_User.Console.Put_Line ("partmgr gpt online");
      else
         --  No GPT: whole device as slot 0 (superfloppy images).
         First_LBA (0) := 0;
         Part_Size (0) := Capacity;
         Akernel_User.Console.Put_Line ("partmgr raw online");
      end if;
   end Probe;

   procedure Reply2 (Status : U64; Value : U64) is
   begin
      Syscalls.Message.Words (0) := Status;
      Syscalls.Message.Words (1) := Value;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply /= Syscalls.IPC_Ok then
         Fail ("partmgr reply failed");
      end if;
   end Reply2;

begin
   Akernel_User.Console.Set_Endpoint (Console_Cap);
   Akernel_User.Console.Put_Line ("partmgr starting");

   Blk_Buf_Cap := Syscalls.Mem_Alloc (1);
   if Blk_Buf_Cap = Syscalls.Syscall_Failed
     or else Syscalls.Mem_Map
       (Address_Space => Syscalls.Address_Space_Cap,
        Cap           => Blk_Buf_Cap,
        VA            => Blk_Buf_VA,
        Offset        => 0,
        Length        => Syscalls.Page_Size,
        Flags         => 3) /= 0
   then
      Fail ("partmgr bounce alloc failed");
   end if;

   Syscalls.Message.Label := Blk_Info;
   Syscalls.Message.Caps := (others => 0);
   if Syscalls.IPC_Call (Blk_EP) /= Syscalls.IPC_Ok
     or else Syscalls.Message.Words (0) /= 0
   then
      Fail ("partmgr blk info failed");
   end if;
   Capacity := Syscalls.Message.Words (1);

   Probe;

   loop
      if Syscalls.IPC_Recv (Svc_EP) /= Syscalls.IPC_Ok then
         Fail ("partmgr recv failed");
      end if;

      declare
         Badge : constant U64 := Syscalls.Message.Badge;
         P     : constant U64 := Badge - Badge_Base;
         Op    : constant U64 := Syscalls.Message.Label;
         Sector : constant U64 := Syscalls.Message.Words (0);
         Count  : constant U64 := Syscalls.Message.Words (1);
         Buf    : constant U64 := Syscalls.Message.Caps (0);
      begin
         if Badge < Badge_Base
           or else Badge >= Badge_Base + U64 (Max_Parts)
           or else Part_Size (Natural (P)) = 0
         then
            Reply2 (1, 0);
         elsif Op = Blk_Info then
            Reply2 (0, Part_Size (Natural (P)));
         elsif Op = Blk_Read or else Op = Blk_Write then
            if Buf = 0
              or else Count = 0
              or else Count > 8
              or else Sector >= Part_Size (Natural (P))
              or else Count > Part_Size (Natural (P)) - Sector
            then
               Reply2 (1, 0);
            else
               --  Offset-translate and forward; the buffer cap rides
               --  through zero-copy, our copy is deleted after.
               Syscalls.Message.Words (0) :=
                 Sector + First_LBA (Natural (P));
               Syscalls.Message.Caps := (0 => Buf, others => 0);

               if Syscalls.IPC_Call (Blk_EP) /= Syscalls.IPC_Ok then
                  if Syscalls.Cap_Delete (Buf) /= 0 then
                     Akernel_User.Console.Put_Line
                       ("partmgr buffer cap delete failed");
                  end if;
                  Reply2 (1, 0);
               else
                  declare
                     Status : constant U64 := Syscalls.Message.Words (0);
                  begin
                     if Syscalls.Cap_Delete (Buf) /= 0 then
                        Akernel_User.Console.Put_Line
                          ("partmgr buffer cap delete failed");
                     end if;
                     Reply2 (Status, 0);
                  end;
               end if;
            end if;
         else
            Reply2 (1, 0);
         end if;
      end;
   end loop;
end Partmgr;
