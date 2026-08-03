with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Files;
with Akernel_User.Console;

--  FAT32 filesystem driver (read-only): an independent fs process
--  behind the file server's VFS layer. Holds the virtio-blk service
--  endpoint (Send, handle 2), probes sector 0 for a FAT32 BPB at
--  startup, then serves the client file protocol (Op_Stat/Op_Open/
--  Op_Read by 8.3 path, flat root directory — no subdirectories or
--  LFN entries yet) on its own service endpoint (Receive, handle 3,
--  granted by init's fat32_server manifest token). The VFS forwards
--  volume-qualified ops verbatim; Op_Read carries the client's
--  buffer memory-object cap in slot 0, which this driver maps,
--  fills from its blk bounce buffer, and cap_deletes after the
--  request (one slot per transfer otherwise).

procedure Fat32 is
   use type Akernel_User.Syscalls.U64;
   use type Interfaces.Unsigned_8;
   use System.Storage_Elements;

   package Syscalls renames Akernel_User.Syscalls;
   package Files renames Akernel_User.Files;

   subtype U64 is Syscalls.U64;
   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of Byte;

   Console_EP : constant U64 := 1;
   Blk_EP     : constant U64 := 2;
   Svc_EP     : constant U64 := 3;

   --  One-page bounce for blk RPCs (the block protocol caps a
   --  request at 8 sectors = 4 KiB); client read buffers map into
   --  an 8-page window above it.
   Bounce_VA   : constant U64 := 16#5000_0000#;
   Buf_Win_VA  : constant U64 := 16#5400_0000#;
   Buf_Bytes   : constant U64 := Files.Buf_Pages * Syscalls.Page_Size;

   Bounce : Byte_Array (0 .. 4095)
     with Address => To_Address (Integer_Address (Bounce_VA));

   Bounce_Cap : U64 := 0;

   --  Volume geometry (from the BPB at sector 0).
   Capacity    : U64 := 0;  --  sectors
   Sec_Per_Clus : U64 := 0;
   FAT_Start   : U64 := 0;  --  first FAT sector
   Data_Start  : U64 := 0;  --  first data sector
   Root_Clus   : U64 := 0;

   EOC_Mark : constant U64 := 16#0FFF_FFF8#;

   function Shr (Value : U64; Amount : Natural) return U64
     renames Interfaces.Shift_Right;

   function LE16 (Off : U64) return U64 is
     (U64 (Bounce (Off)) + U64 (Bounce (Off + 1)) * 16#100#);

   function LE32 (Off : U64) return U64 is
     (U64 (Bounce (Off))
      + U64 (Bounce (Off + 1)) * 16#100#
      + U64 (Bounce (Off + 2)) * 16#1_0000#
      + U64 (Bounce (Off + 3)) * 16#100_0000#);

   function To_Lower (C : Character) return Character
   is (if C in 'A' .. 'Z'
       then Character'Val (Character'Pos (C) + 32)
       else C);

   function Match
     (Text        : String;
      Against     : String;
      Insensitive : Boolean) return Boolean
   is
   begin
      if Text'Length /= Against'Length then
         return False;
      end if;

      for I in Text'Range loop
         if Insensitive then
            if To_Lower (Text (I))
              /= To_Lower (Against (I - Text'First + Against'First))
            then
               return False;
            end if;
         elsif Text (I) /= Against (I - Text'First + Against'First) then
            return False;
         end if;
      end loop;
      return True;
   end Match;

   function Unpack_Char (First : Natural; Pos : Natural) return Character
   is (Character'Val
         (Natural (Shr (Syscalls.Message.Words (First + Pos / 8),
                        (Pos mod 8) * 8)
                   and 16#FF#)));

   --  NUL/space-terminated wire name from message words.
   function Name_Of
     (First : Natural;
      Last  : Natural;
      S     : out String;
      Len   : out Natural) return Boolean
   is
      C : Character;
   begin
      Len := 0;
      S := (others => Character'Val (0));
      for Pos in 0 .. (Last - First + 1) * 8 - 1 loop
         C := Unpack_Char (First, Pos);
         exit when C = Character'Val (0);
         if Len >= S'Length then
            return False;
         end if;
         Len := Len + 1;
         S (Len) := C;
      end loop;
      return Len > 0;
   end Name_Of;

   ------------------------------------------------------------------
   --  Block access
   ------------------------------------------------------------------

   function Ensure_Bounce return Boolean is
   begin
      if Bounce_Cap /= 0 then
         return True;
      end if;

      Bounce_Cap := Syscalls.Mem_Alloc (1);
      if Bounce_Cap = Syscalls.Syscall_Failed
        or else Syscalls.Mem_Map
          (Address_Space => Syscalls.Address_Space_Cap,
           Cap           => Bounce_Cap,
           VA            => Bounce_VA,
           Offset        => 0,
           Length        => Syscalls.Page_Size,
           Flags         => 3) /= 0
      then
         Bounce_Cap := 0;
         return False;
      end if;
      return True;
   end Ensure_Bounce;

   --  Read Count sectors starting at First into the bounce buffer.
   function Blk_Read_Sectors (First : U64; Count : U64) return Boolean is
   begin
      if First + Count > Capacity then
         return False;
      end if;

      Syscalls.Message.Label := Files.Blk_Read;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Words (0) := First;
      Syscalls.Message.Words (1) := Count;
      Syscalls.Message.Caps := (0 => Bounce_Cap, others => 0);
      return Syscalls.IPC_Call (Blk_EP) = Syscalls.IPC_Ok
        and then Syscalls.Message.Words (0) = 0;
   end Blk_Read_Sectors;

   ------------------------------------------------------------------
   --  FAT32
   ------------------------------------------------------------------

   function Cluster_Sector (C : U64) return U64 is
     (Data_Start + (C - 2) * Sec_Per_Clus);

   --  Follow the FAT: Value is the next cluster; EOC when the chain
   --  ends (or on an io error — callers treat it as end-of-data).
   procedure Next_Cluster (C : U64; Value : out U64; EOC : out Boolean) is
      Off : constant U64 := C * 4;
      V   : U64;
   begin
      Value := 0;
      EOC := True;
      if not Blk_Read_Sectors (FAT_Start + Off / 512, 1) then
         return;
      end if;

      V := LE32 (Off mod 512) and 16#0FFF_FFFF#;
      if V = 0 or else V >= EOC_Mark then
         return;
      end if;

      Value := V;
      EOC := False;
   end Next_Cluster;

   --  Flat-root directory lookup by 8.3 name. Paths with directory
   --  separators never match (no subdirectory support yet). LFN,
   --  volume-label and directory entries are skipped.
   function Lookup
     (Path         : String;
      Start_Cluster : out U64;
      Size          : out U64) return Boolean
   is
      C     : U64 := Root_Clus;
      Next  : U64;
      EOC   : Boolean;
      B0    : Byte;
      Attr  : Byte;
      Dotted : String (1 .. 12);
      Dot_Len : Natural;
   begin
      Start_Cluster := 0;
      Size := 0;

      for Ch of Path loop
         if Ch = '/' or else Ch = '\' then
            return False;
         end if;
      end loop;

      loop
         if not Blk_Read_Sectors (Cluster_Sector (C), Sec_Per_Clus) then
            return False;
         end if;

         for Ent in 0 .. Sec_Per_Clus * 16 - 1 loop
            B0 := Bounce (Ent * 32);
            exit when B0 = 0;  --  end of directory

            Attr := Bounce (Ent * 32 + 11);
            if B0 /= 16#E5#
              and then Attr /= 16#0F#          --  not LFN
              and then (Attr and 16#18#) = 0   --  not volume label/dir
            then
               --  8.3 -> "NAME.EXT" (spaces stripped).
               Dot_Len := 0;
               for J in 0 .. 7 loop
                  exit when Bounce (Ent * 32 + U64 (J)) = 16#20#;
                  Dot_Len := Dot_Len + 1;
                  Dotted (Dot_Len) :=
                    Character'Val (Natural (Bounce (Ent * 32 + U64 (J))));
               end loop;
               if Bounce (Ent * 32 + 8) /= 16#20# then
                  Dot_Len := Dot_Len + 1;
                  Dotted (Dot_Len) := '.';
                  for J in 8 .. 10 loop
                     exit when Bounce (Ent * 32 + U64 (J)) = 16#20#;
                     Dot_Len := Dot_Len + 1;
                     Dotted (Dot_Len) :=
                       Character'Val (Natural (Bounce (Ent * 32 + U64 (J))));
                  end loop;
               end if;

               --  FAT 8.3 names are uppercase on disk; compare
               --  case-insensitively regardless of the wire case.
               if Match (Dotted (1 .. Dot_Len), Path, True) then
                  Start_Cluster :=
                    LE16 (Ent * 32 + 20) * 16#1_0000#
                      + LE16 (Ent * 32 + 26);
                  Size := LE32 (Ent * 32 + 28);
                  return True;
               end if;
            end if;
         end loop;

         Next_Cluster (C, Next, EOC);
         exit when EOC;
         C := Next;
      end loop;

      return False;
   end Lookup;

   ------------------------------------------------------------------
   --  Client buffer window (mapped per Op_Read)
   ------------------------------------------------------------------

   function Map_Client_Buf (Buf : U64) return Boolean is
   begin
      if Syscalls.Mem_Map
        (Address_Space => Syscalls.Address_Space_Cap,
         Cap           => Buf,
         VA            => Buf_Win_VA,
         Offset        => 0,
         Length        => Buf_Bytes,
         Flags         => 3) /= 0
      then
         return False;
      end if;
      return True;
   end Map_Client_Buf;

   procedure Reply2 (Status : U64; Value : U64) is
   begin
      Syscalls.Message.Label := 0;
      Syscalls.Message.Words (0) := Status;
      Syscalls.Message.Words (1) := Value;
      if Syscalls.IPC_Reply /= Syscalls.IPC_Ok then
         Akernel_User.Console.Put_Line ("fat32: reply failed");
      end if;
   end Reply2;

   ------------------------------------------------------------------
   --  Ops
   ------------------------------------------------------------------

   procedure Handle_Stat_Or_Open is
      Name : String (1 .. 48);
      Len  : Natural;
      Start_Cluster : U64;
      Size : U64;
   begin
      if not Name_Of (0, 5, Name, Len) then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      if Lookup (Name (1 .. Len), Start_Cluster, Size) then
         Reply2 (Files.Status_Ok, Size);
      else
         Reply2 (Files.Status_Not_Found, 0);
      end if;
   end Handle_Stat_Or_Open;

   procedure Handle_Read is
      Offset : constant U64 := Syscalls.Message.Words (0);
      Length : constant U64 := Syscalls.Message.Words (1);
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      Name   : String (1 .. 32);
      Len    : Natural;
      Start_Cluster : U64;
      Size   : U64;
      Count  : U64;
      Done   : U64 := 0;
      C      : U64;
      Next   : U64;
      EOC    : Boolean := False;
      Skip   : U64;
      Chunk  : U64;
      To_Skip : U64;
      Status : U64 := Files.Status_Ok;
   begin
      if Buf = 0
        or else Length = 0
        or else not Name_Of (2, 5, Name, Len)
      then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      if not Lookup (Name (1 .. Len), Start_Cluster, Size) then
         Reply2 (Files.Status_Not_Found, 0);
         return;
      end if;

      if Offset >= Size then
         Reply2 (Files.Status_Out_Of_Range, 0);
         return;
      end if;

      if not Map_Client_Buf (Buf) then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      Count := U64'Min (Length, Size - Offset);
      Count := U64'Min (Count, Buf_Bytes);

      --  Skip whole clusters before the offset, then stream
      --  cluster-by-cluster through the bounce buffer.
      C := Start_Cluster;
      To_Skip := Offset / (Sec_Per_Clus * 512);
      while To_Skip > 0 loop
         Next_Cluster (C, Next, EOC);
         exit when EOC;
         C := Next;
         To_Skip := To_Skip - 1;
      end loop;

      Skip := Offset mod (Sec_Per_Clus * 512);
      while Done < Count and then not EOC loop
         if not Blk_Read_Sectors (Cluster_Sector (C), Sec_Per_Clus) then
            Status := Files.Status_Not_Found;
            exit;
         end if;

         Chunk := U64'Min (Sec_Per_Clus * 512 - Skip, Count - Done);
         declare
            Src : Byte_Array (0 .. Chunk - 1)
              with Address => To_Address (Integer_Address
                (Bounce_VA + Skip));
            Dst : Byte_Array (0 .. Chunk - 1)
              with Address => To_Address (Integer_Address
                (Buf_Win_VA + Done));
         begin
            Dst := Src;
         end;

         Done := Done + Chunk;
         Skip := 0;

         if Done < Count then
            Next_Cluster (C, Next, EOC);
            C := Next;
         end if;
      end loop;

      --  Drop the client buffer mapping and the transferred cap:
      --  each transfer would otherwise leak a cap-table slot.
      if Syscalls.Mem_Unmap
        (Address_Space => Syscalls.Address_Space_Cap,
         VA            => Buf_Win_VA,
         Length        => Buf_Bytes) /= 0
      then
         Akernel_User.Console.Put_Line ("fat32: buffer unmap failed");
      end if;
      if Syscalls.Cap_Delete (Buf) /= 0 then
         Akernel_User.Console.Put_Line ("fat32: buffer cap delete failed");
      end if;

      if Status = Files.Status_Ok then
         Reply2 (Files.Status_Ok, Done);
      else
         Reply2 (Status, 0);
      end if;
   end Handle_Read;

   ------------------------------------------------------------------
   --  Probe
   ------------------------------------------------------------------

   procedure Probe (Ok : out Boolean) is
   begin
      Ok := False;

      if not Ensure_Bounce then
         Syscalls.Debug_Put_Line ("fat32 bounce alloc failed");
         return;
      end if;

      Syscalls.Message.Label := Files.Blk_Info;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (Blk_EP) /= Syscalls.IPC_Ok
        or else Syscalls.Message.Words (0) /= 0
      then
         Syscalls.Debug_Put_Line ("fat32 blk info failed");
         return;
      end if;
      Capacity := Syscalls.Message.Words (1);

      if not Blk_Read_Sectors (0, 1) then
         Syscalls.Debug_Put_Line ("fat32 boot sector read failed");
         return;
      end if;

      --  BPB validation: 0x55AA trailer, 512-byte sectors, the
      --  FAT32 type string, sane cluster size (<= 8 sectors so one
      --  cluster fits the bounce buffer).
      if Bounce (510) /= 16#55# or else Bounce (511) /= 16#AA#
        or else LE16 (11) /= 512
        or else Bounce (82) /= 16#46#  --  'F'
        or else Bounce (83) /= 16#41#  --  'A'
        or else Bounce (84) /= 16#54#  --  'T'
        or else Bounce (85) /= 16#33#  --  '3'
        or else Bounce (86) /= 16#32#  --  '2'
        or else Bounce (13) = 0
        or else Bounce (13) > 8
        or else (Bounce (13) and (Bounce (13) - 1)) /= 0
      then
         Syscalls.Debug_Put_Line ("fat32 no fat32 bpb");
         return;
      end if;

      Sec_Per_Clus := U64 (Bounce (13));
      FAT_Start := LE16 (14);
      Data_Start := FAT_Start + U64 (Bounce (16)) * LE32 (36);
      Root_Clus := LE32 (44);
      Ok := True;
   end Probe;

   Probe_Ok : Boolean;
begin
   Akernel_User.Console.Set_Endpoint (Console_EP);

   Probe (Probe_Ok);
   if not Probe_Ok then
      Syscalls.Debug_Put_Line ("fat32 probe failed");
      Syscalls.Process_Exit;
   end if;

   Akernel_User.Console.Put_Line ("fat32 online");

   loop
      if Syscalls.IPC_Recv (Svc_EP) /= Syscalls.IPC_Ok then
         Akernel_User.Console.Put_Line ("fat32: recv failed");
         exit;
      end if;

      if Syscalls.Message.Label = Files.Op_Stat
        or else Syscalls.Message.Label = Files.Op_Open
      then
         Handle_Stat_Or_Open;
      elsif Syscalls.Message.Label = Files.Op_Read then
         Handle_Read;
      else
         Reply2 (Files.Status_Bad_Args, 0);
      end if;
   end loop;

   Syscalls.Process_Exit;
end Fat32;
