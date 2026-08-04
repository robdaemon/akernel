with System;
with System.Storage_Elements;
with Interfaces;
with Akernel_User.Syscalls;
with Akernel_User.Files;
with Akernel_User.Console;

--  File server (docs/IPC.md "file protocol"): holds every boot-file
--  cap (granted via the boot_files manifest token at handles 3..N)
--  and the Receive side of the fs endpoint (handle 1). Init first
--  sends Op_Mount (from the manifest's volume directive) binding a
--  device name (RD0) and volume label (Initrd) plus a
--  case-sensitivity flag to the boot-file set, then pushes the
--  (handle -> path) table as Op_Set_Name messages; until the table
--  is complete Stat/Open/Read answer Status_Not_Ready.
--
--  Wire names are volume-qualified (VOL:path or LABEL:path);
--  unqualified names are rejected (client-side PATH resolution
--  prepends the default volume). Volume prefixes always compare
--  case-insensitively; path comparison uses the volume's flag.
--
--  Boot files are mapped as borrowed read-only pages (mem_map on a
--  Boot_File_Object cap) into per-file windows; file data starts
--  Lead_In bytes into the first page (cpio alignment). Op_Read
--  copies bytes into the client-owned buffer whose cap arrives in
--  cap slot 0; the most recent buffer stays mapped.

procedure Fileserver is
   use type Akernel_User.Syscalls.U64;
   use System.Storage_Elements;

   package Syscalls renames Akernel_User.Syscalls;
   package Files renames Akernel_User.Files;

   subtype U64 is Syscalls.U64;
   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of Byte;

   EP : constant U64 := 1;  --  fs_server grant: Receive side

   Max_Files : constant := 16;
   Max_Name  : constant := 32;

   type File_Entry is record
      Valid   : Boolean := False;
      Handle  : U64 := 0;
      Name    : String (1 .. Max_Name) := (others => Character'Val (0));
      Name_Len : Natural := 0;
      Size    : U64 := 0;
      Mapped  : Boolean := False;
      Lead_In : U64 := 0;
      Win_VA  : U64 := 0;
   end record;

   File_Table : array (1 .. Max_Files) of File_Entry;
   Names_Done : Boolean := False;

   --  Volumes (Amiga-style device/label mounts): the boot-file set
   --  is mounted under a device name and a volume label, either
   --  resolves on the wire.
   Max_Volumes : constant := 4;

   type Volume_Entry is record
      Valid   : Boolean := False;
      Device  : String (1 .. 16) := (others => Character'Val (0));
      Dev_Len : Natural := 0;
      Label   : String (1 .. 16) := (others => Character'Val (0));
      Lab_Len : Natural := 0;
      Case_Insensitive : Boolean := False;
      --  Block-backed volume (Op_Add_Block): the single file
      --  "disk" is the raw device, Blk_Size bytes, served by the
      --  block driver at Blk_EP (block protocol, see
      --  Akernel_User.Files).
      Is_Block : Boolean := False;
      Blk_EP   : U64 := 0;
      Blk_Size : U64 := 0;
      --  FS-driver volume (Op_Add_FS): stat/open/read for its
      --  paths are forwarded verbatim to the fs driver at FS_EP
      --  (this server is the VFS layer; filesystems are
      --  independent driver processes).
      Is_FS    : Boolean := False;
      FS_EP    : U64 := 0;
   end record;

   Volumes : array (1 .. Max_Volumes) of Volume_Entry;

   --  VA windows: per-file slots above the client-buffer window.
   File_Win_Base : constant U64 := 16#4400_0000#;
   Slot_Stride   : constant U64 := 64 * Syscalls.Page_Size;
   Buf_Win_VA    : constant U64 :=
     File_Win_Base + Max_Files * Slot_Stride;

   --  Bounce buffer for block-driver calls: one page (the block
   --  protocol caps a request at 8 sectors = 4 KiB), transferred
   --  with each read so the driver can DMA straight into it.
   Blk_Buf_Cap : U64 := 0;
   Blk_Buf_VA  : constant U64 := Buf_Win_VA + 8 * Syscalls.Page_Size;
   Buf_Bytes      : constant U64 := Files.Buf_Pages * Syscalls.Page_Size;

   function Shift_Right
     (Value : U64; Amount : Natural) return U64
     renames Interfaces.Shift_Right;

   function Shl (Value : U64; Amount : Natural) return U64
     renames Interfaces.Shift_Left;

   function Unpack_Char (First : Natural; Pos : Natural) return Character
   is (Character'Val
         (Natural (Shift_Right
                     (Syscalls.Message.Words (First + Pos / 8),
                      (Pos mod 8) * 8)
                   and 16#FF#)));

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

   function To_Lower (C : Character) return Character
   is (if C in 'A' .. 'Z'
       then Character'Val (Character'Pos (C) + 32)
       else C);

   function Match
     (Text       : String;
      Text_Len   : Natural;
      Against    : String;
      Insensitive : Boolean) return Boolean
   is
   begin
      if Text_Len /= Against'Length then
         return False;
      end if;

      for I in 1 .. Text_Len loop
         if Insensitive then
            if To_Lower (Text (Text'First + I - 1))
              /= To_Lower (Against (Against'First + I - 1))
            then
               return False;
            end if;
         elsif Text (Text'First + I - 1)
           /= Against (Against'First + I - 1)
         then
            return False;
         end if;
      end loop;
      return True;
   end Match;

   --  Resolve a wire name: split VOL:path, match the prefix against
   --  every volume's device and label (always case-insensitive).
   --  Returns the volume index, or 0 when unqualified/unknown.
   function Resolve_Volume
     (Name     : String;
      Len      : Natural;
      Path_Pos : out Natural) return Natural
   is
      Colon : Natural := 0;
   begin
      Path_Pos := 1;
      for I in 1 .. Len loop
         if Name (I) = ':' then
            Colon := I;
            exit;
         end if;
      end loop;

      if Colon = 0 or else Colon = Len then
         return 0;  --  unqualified or empty path
      end if;

      for V in Volumes'Range loop
         if Volumes (V).Valid then
            if Match (Name, Colon - 1,
                      Volumes (V).Device (1 .. Volumes (V).Dev_Len),
                      True)
              or else Match (Name, Colon - 1,
                             Volumes (V).Label (1 .. Volumes (V).Lab_Len),
                             True)
            then
               Path_Pos := Colon + 1;
               return V;
            end if;
         end if;
      end loop;
      return 0;
   end Resolve_Volume;

   function Find
     (Path   : String;
      Volume : Natural) return Natural
   is
      CI : constant Boolean := Volumes (Volume).Case_Insensitive;
   begin
      for I in File_Table'Range loop
         if File_Table (I).Valid
           and then Match
             (File_Table (I).Name (1 .. File_Table (I).Name_Len),
              File_Table (I).Name_Len,
              Path,
              CI)
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find;

   procedure Reply2 (Status : U64; Value : U64) is
   begin
      Syscalls.Message.Label := 0;
      Syscalls.Message.Words (0) := Status;
      Syscalls.Message.Words (1) := Value;
      if Syscalls.IPC_Reply /= Syscalls.IPC_Ok then
         Akernel_User.Console.Put_Line ("fileserver: reply failed");
      end if;
   end Reply2;

   procedure Ensure_Mapped (Index : Natural; Ok : out Boolean) is
      F  : File_Entry renames File_Table (Index);
      Pages  : U64;
      Dummy  : U64;
   begin
      Ok := True;
      if F.Mapped then
         return;
      end if;

      --  First page: learn the lead-in, then map the rest of the
      --  file's true page span.
      if Syscalls.Mem_Map_File
        (Address_Space => Syscalls.Address_Space_Cap,
         Cap           => F.Handle,
         VA            => F.Win_VA,
         Offset        => 0,
         Length        => Syscalls.Page_Size,
         Lead_In       => F.Lead_In) /= 0
      then
         Ok := False;
         return;
      end if;

      Pages := (F.Lead_In + F.Size + Syscalls.Page_Size - 1)
        / Syscalls.Page_Size;
      if Pages > 1
        and then Syscalls.Mem_Map_File
          (Address_Space => Syscalls.Address_Space_Cap,
           Cap           => F.Handle,
           VA            => F.Win_VA + Syscalls.Page_Size,
           Offset        => Syscalls.Page_Size,
           Length        => (Pages - 1) * Syscalls.Page_Size,
           Lead_In       => Dummy) /= 0
      then
         Ok := False;
         return;
      end if;

      F.Mapped := True;
   end Ensure_Mapped;

   procedure Handle_Mount is
      Dev_Len : constant Natural := Natural (Syscalls.Message.Words (0));
      Lab_Len : constant Natural := Natural (Syscalls.Message.Words (1));
      CI      : constant Boolean := Syscalls.Message.Words (2) /= 0;
   begin
      if Dev_Len = 0 or else Dev_Len > 16
        or else Lab_Len = 0 or else Lab_Len > 16
        or else Dev_Len + Lab_Len > 24
      then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      for V in Volumes'Range loop
         if not Volumes (V).Valid then
            Volumes (V).Valid := True;
            Volumes (V).Dev_Len := Dev_Len;
            Volumes (V).Lab_Len := Lab_Len;
            Volumes (V).Case_Insensitive := CI;
            for Pos in 0 .. Dev_Len - 1 loop
               Volumes (V).Device (Pos + 1) := Unpack_Char (3, Pos);
            end loop;
            for Pos in 0 .. Lab_Len - 1 loop
               Volumes (V).Label (Pos + 1) :=
                 Unpack_Char (3, Dev_Len + Pos);
            end loop;
            Reply2 (Files.Status_Ok, 0);
            return;
         end if;
      end loop;

      Reply2 (Files.Status_Bad_Args, 0);
   end Handle_Mount;

   --  Op_Add_Block: like Op_Mount plus the block driver's service
   --  endpoint cap in slot 0. Registers a block-backed volume
   --  (single file "disk") and learns the device capacity from the
   --  driver (Blk_Info).
   procedure Handle_Add_Block is
      Dev_Len : constant Natural := Natural (Syscalls.Message.Words (0));
      Lab_Len : constant Natural := Natural (Syscalls.Message.Words (1));
      CI      : constant Boolean := Syscalls.Message.Words (2) /= 0;
      EP      : constant U64 := Syscalls.Message.Caps (0);
   begin
      if Dev_Len = 0 or else Dev_Len > 16
        or else Lab_Len = 0 or else Lab_Len > 16
        or else Dev_Len + Lab_Len > 24
        or else EP = 0
      then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      for V in Volumes'Range loop
         if not Volumes (V).Valid then
            Volumes (V).Valid := True;
            Volumes (V).Dev_Len := Dev_Len;
            Volumes (V).Lab_Len := Lab_Len;
            Volumes (V).Case_Insensitive := CI;
            for Pos in 0 .. Dev_Len - 1 loop
               Volumes (V).Device (Pos + 1) := Unpack_Char (3, Pos);
            end loop;
            for Pos in 0 .. Lab_Len - 1 loop
               Volumes (V).Label (Pos + 1) :=
                 Unpack_Char (3, Dev_Len + Pos);
            end loop;
            Volumes (V).Is_Block := True;
            Volumes (V).Blk_EP := EP;
            Volumes (V).Blk_Size := 0;

            --  Device capacity in sectors (one page = 8 sectors).
            Syscalls.Message.Label := Files.Blk_Info;
            Syscalls.Message.Words := (others => 0);
            Syscalls.Message.Caps := (others => 0);
            if Syscalls.IPC_Call (EP) = Syscalls.IPC_Ok
              and then Syscalls.Message.Words (0) = 0
            then
               Volumes (V).Blk_Size := Syscalls.Message.Words (1) * 512;
            end if;

            Reply2 (Files.Status_Ok, 0);
            return;
         end if;
      end loop;

      Reply2 (Files.Status_Bad_Args, 0);
   end Handle_Add_Block;


   --  Op_Add_FS: like Op_Add_Block but the endpoint speaks the
   --  client file protocol (stat/open/read by path) instead of the
   --  block protocol — the fs driver probed and mounted the
   --  filesystem itself. Registers a VFS-forwarded volume.
   procedure Handle_Add_FS is
      Dev_Len : constant Natural := Natural (Syscalls.Message.Words (0));
      Lab_Len : constant Natural := Natural (Syscalls.Message.Words (1));
      CI      : constant Boolean := Syscalls.Message.Words (2) /= 0;
      EP      : constant U64 := Syscalls.Message.Caps (0);
   begin
      if Dev_Len = 0 or else Dev_Len > 16
        or else Lab_Len = 0 or else Lab_Len > 16
        or else Dev_Len + Lab_Len > 24
        or else EP = 0
      then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      for V in Volumes'Range loop
         if not Volumes (V).Valid then
            Volumes (V).Valid := True;
            Volumes (V).Dev_Len := Dev_Len;
            Volumes (V).Lab_Len := Lab_Len;
            Volumes (V).Case_Insensitive := CI;
            for Pos in 0 .. Dev_Len - 1 loop
               Volumes (V).Device (Pos + 1) := Unpack_Char (3, Pos);
            end loop;
            for Pos in 0 .. Lab_Len - 1 loop
               Volumes (V).Label (Pos + 1) :=
                 Unpack_Char (3, Dev_Len + Pos);
            end loop;
            Volumes (V).Is_FS := True;
            Volumes (V).FS_EP := EP;

            Reply2 (Files.Status_Ok, 0);
            return;
         end if;
      end loop;

      Reply2 (Files.Status_Bad_Args, 0);
   end Handle_Add_FS;

   procedure Handle_Set_Name is
      Handle : constant U64 := Syscalls.Message.Words (0);
      Len    : constant Natural := Natural (Syscalls.Message.Words (1));
   begin
      if Len = 0 or else Len > Max_Name then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      for I in File_Table'Range loop
         if not File_Table (I).Valid then
            File_Table (I).Valid := True;
            File_Table (I).Handle := Handle;
            File_Table (I).Name_Len := Len;
            for Pos in 0 .. Len - 1 loop
               File_Table (I).Name (Pos + 1) :=
                 Unpack_Char (2, Pos);
            end loop;
            File_Table (I).Size :=
              Syscalls.Boot_File_Size (Handle);
            File_Table (I).Win_VA :=
              File_Win_Base + U64 (I - 1) * Slot_Stride;
            Reply2 (Files.Status_Ok, 0);
            return;
         end if;
      end loop;

      Reply2 (Files.Status_Bad_Args, 0);
   end Handle_Set_Name;

   --  Pack Name (Pos .. Len) into the outgoing message words
   --  First_Word .. 5 (NUL-padded): the VFS forwards the path
   --  portion of a volume-qualified name to the fs driver.
   procedure Pack_Path
     (Name : String; Pos : Natural; Len : Natural; First_Word : Natural)
   is
      W : Natural;
   begin
      for I in First_Word .. 5 loop
         Syscalls.Message.Words (I) := 0;
      end loop;
      for P in Pos .. Len loop
         W := First_Word + (P - Pos) / 8;
         exit when W > 5;
         Syscalls.Message.Words (W) :=
           Syscalls.Message.Words (W)
             or Shl (U64 (Character'Pos (Name (Name'First + P - 1))),
                     ((P - Pos) mod 8) * 8);
      end loop;
   end Pack_Path;

   procedure Handle_Stat_Or_Open is
      Name : String (1 .. 48);
      Len  : Natural;
      Pos  : Natural;
      V    : Natural;
      I    : Natural;
   begin
      if not Name_Of (0, 5, Name, Len) then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      V := Resolve_Volume (Name, Len, Pos);
      if V = 0 then
         Reply2 (Files.Status_Not_Found, 0);
         return;
      end if;

      if Volumes (V).Is_FS then
         --  VFS forwarding: the fs driver speaks the same client
         --  protocol; the path portion rides words 0..5.
         Pack_Path (Name, Pos, Len, 0);
         Syscalls.Message.Caps := (others => 0);
         if Syscalls.IPC_Call (Volumes (V).FS_EP) = Syscalls.IPC_Ok then
            Reply2 (Syscalls.Message.Words (0),
                    Syscalls.Message.Words (1));
         else
            Reply2 (Files.Status_Not_Found, 0);
         end if;
         return;
      end if;

      if Volumes (V).Is_Block then
         --  Block volumes expose the raw device as "disk".
         if Match ("disk", 4, Name (Pos .. Len),
                   Volumes (V).Case_Insensitive)
         then
            Reply2 (Files.Status_Ok, Volumes (V).Blk_Size);
         else
            Reply2 (Files.Status_Not_Found, 0);
         end if;
         return;
      end if;

      I := Find (Name (Pos .. Len), V);
      if I = 0 then
         Reply2 (Files.Status_Not_Found, 0);
         return;
      end if;

      Reply2 (Files.Status_Ok, File_Table (I).Size);
   end Handle_Stat_Or_Open;

   --  Map the client read buffer for this op (unmapped +
   --  cap_delete'd at op end; a per-op transferred cap must not
   --  linger or every read leaks a cap-table slot).
   function Map_Buf (Buf : U64) return Boolean is
   begin
      return Syscalls.Mem_Map
        (Address_Space => Syscalls.Address_Space_Cap,
         Cap           => Buf,
         VA            => Buf_Win_VA,
         Offset        => 0,
         Length        => Buf_Bytes,
         Flags         => 3) = 0;
   end Map_Buf;

   --  Bounce buffer for block-driver calls, allocated lazily.
   function Ensure_Blk_Buf return Boolean is
   begin
      if Blk_Buf_Cap /= 0 then
         return True;
      end if;

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
         Blk_Buf_Cap := 0;
         return False;
      end if;
      return True;
   end Ensure_Blk_Buf;

   --  Block-volume read: sector RPCs to the driver through the
   --  bounce buffer, copied into the client buffer window. Sets
   --  Mapped when the client buffer got mapped (caller unmaps).
   procedure Handle_Block_Read
     (V      : Natural;
      Buf    : U64;
      Offset : U64;
      Length : U64;
      Status : out U64;
      Count  : out U64;
      Mapped : in out Boolean)
   is
      Done  : U64 := 0;
      Pos   : U64;
      Chunk : U64;
      Skip  : U64;
      NSec  : U64;
   begin
      Status := Files.Status_Ok;
      Count := 0;

      if Volumes (V).Blk_Size = 0 or else Offset >= Volumes (V).Blk_Size then
         Status := Files.Status_Out_Of_Range;
         return;
      end if;

      Count := U64'Min (Length, Volumes (V).Blk_Size - Offset);
      Count := U64'Min (Count, Buf_Bytes);

      if not Ensure_Blk_Buf then
         Status := Files.Status_Bad_Args;
         Count := 0;
         return;
      end if;

      if not Map_Buf (Buf) then
         Status := Files.Status_Not_Found;
         Count := 0;
         return;
      end if;
      Mapped := True;

      while Done < Count loop
         Pos := Offset + Done;
         Skip := Pos mod 512;
         NSec := U64'Min (8, (Count - Done + Skip + 511) / 512);

         Syscalls.Message.Label := Files.Blk_Read;
         Syscalls.Message.Words (0) := Pos / 512;
         Syscalls.Message.Words (1) := NSec;
         Syscalls.Message.Caps := (0 => Blk_Buf_Cap, others => 0);

         if Syscalls.IPC_Call (Volumes (V).Blk_EP) /= Syscalls.IPC_Ok
           or else Syscalls.Message.Words (0) /= 0
         then
            Status := Files.Status_Not_Found;
            Count := 0;
            return;
         end if;

         Chunk := U64'Min (NSec * 512 - Skip, Count - Done);

         declare
            Src : Byte_Array (0 .. Chunk - 1)
              with Address => To_Address (Integer_Address
                (Blk_Buf_VA + Skip));
            Dst : Byte_Array (0 .. Chunk - 1)
              with Address => To_Address (Integer_Address
                (Buf_Win_VA + Done));
         begin
            Dst := Src;
         end;

         Done := Done + Chunk;
      end loop;
   end Handle_Block_Read;
   --  Block-volume write: read-modify-write through the bounce
   --  buffer (partial first/last sectors), full sectors direct.
   procedure Handle_Block_Write
     (V      : Natural;
      Buf    : U64;
      Offset : U64;
      Length : U64;
      Status : out U64;
      Count  : out U64;
      Mapped : in out Boolean)
   is
      Done  : U64 := 0;
      Pos   : U64;
      Chunk : U64;
      Skip  : U64;
      NSec  : U64;
   begin
      Status := Files.Status_Ok;
      Count := 0;

      if Volumes (V).Blk_Size = 0 or else Offset >= Volumes (V).Blk_Size then
         Status := Files.Status_Out_Of_Range;
         return;
      end if;

      Count := U64'Min (Length, Volumes (V).Blk_Size - Offset);
      Count := U64'Min (Count, Buf_Bytes);

      if not Ensure_Blk_Buf then
         Status := Files.Status_Bad_Args;
         Count := 0;
         return;
      end if;

      if not Map_Buf (Buf) then
         Status := Files.Status_Not_Found;
         Count := 0;
         return;
      end if;
      Mapped := True;

      while Done < Count loop
         Pos := Offset + Done;
         Skip := Pos mod 512;
         NSec := U64'Min (8, (Count - Done + Skip + 511) / 512);

         --  Partial head/tail: read the sector range first so the
         --  untouched bytes survive the writeback.
         if Skip /= 0
           or else (Count - Done + Skip) mod 512 /= 0
         then
            Syscalls.Message.Label := Files.Blk_Read;
            Syscalls.Message.Words (0) := Pos / 512;
            Syscalls.Message.Words (1) := NSec;
            Syscalls.Message.Caps := (0 => Blk_Buf_Cap, others => 0);

            if Syscalls.IPC_Call (Volumes (V).Blk_EP) /= Syscalls.IPC_Ok
              or else Syscalls.Message.Words (0) /= 0
            then
               Status := Files.Status_Not_Found;
               Count := 0;
               return;
            end if;
         end if;

         Chunk := U64'Min (NSec * 512 - Skip, Count - Done);

         declare
            Dst : Byte_Array (0 .. Chunk - 1)
              with Address => To_Address (Integer_Address
                (Blk_Buf_VA + Skip));
            Src : Byte_Array (0 .. Chunk - 1)
              with Address => To_Address (Integer_Address
                (Buf_Win_VA + Done));
         begin
            Dst := Src;
         end;

         Syscalls.Message.Label := Files.Blk_Write;
         Syscalls.Message.Words (0) := Pos / 512;
         Syscalls.Message.Words (1) := NSec;
         Syscalls.Message.Caps := (0 => Blk_Buf_Cap, others => 0);

         if Syscalls.IPC_Call (Volumes (V).Blk_EP) /= Syscalls.IPC_Ok
           or else Syscalls.Message.Words (0) /= 0
         then
            Status := Files.Status_Not_Found;
            Count := 0;
            return;
         end if;

         Done := Done + Chunk;
      end loop;
   end Handle_Block_Write;

   --  Op_Write: boot-file volumes are read-only; block "disk"
   --  files write through the bounce buffer; fs-driver volumes
   --  get the op forwarded verbatim. Same per-op buffer-cap
   --  discipline as Op_Read (unmap + cap_delete below).
   procedure Handle_Write is
      Offset : constant U64 := Syscalls.Message.Words (0);
      Length : constant U64 := Syscalls.Message.Words (1);
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      Name   : String (1 .. 32);
      Len    : Natural := 0;
      Pos    : Natural := 1;
      V      : Natural := 0;
      Count  : U64 := 0;
      Status : U64 := Files.Status_Ok;
      Mapped : Boolean := False;

      procedure Process is
      begin
         if not Names_Done then
            Status := Files.Status_Not_Ready;
            return;
         end if;

         if Buf = 0
           or else Length = 0
           or else not Name_Of (2, 5, Name, Len)
         then
            Status := Files.Status_Bad_Args;
            return;
         end if;

         V := Resolve_Volume (Name, Len, Pos);
         if V = 0 then
            Status := Files.Status_Not_Found;
            return;
         end if;

         if Volumes (V).Is_FS then
            Syscalls.Message.Words (0) := Offset;
            Syscalls.Message.Words (1) := Length;
            Pack_Path (Name, Pos, Len, 2);
            Syscalls.Message.Label := Files.Op_Write;
            Syscalls.Message.Caps := (0 => Buf, others => 0);
            if Syscalls.IPC_Call (Volumes (V).FS_EP) = Syscalls.IPC_Ok then
               Status := Syscalls.Message.Words (0);
               Count := Syscalls.Message.Words (1);
            else
               Status := Files.Status_Not_Found;
            end if;
            return;
         end if;

         if Volumes (V).Is_Block then
            if not Match ("disk", 4, Name (Pos .. Len),
                          Volumes (V).Case_Insensitive)
            then
               Status := Files.Status_Not_Found;
               return;
            end if;

            Handle_Block_Write (V, Buf, Offset, Length,
                                Status, Count, Mapped);
            return;
         end if;

         Status := Files.Status_Bad_Args;  --  boot files read-only
      end Process;
   begin
      Process;

      if Buf /= 0 then
         if Mapped
           and then Syscalls.Mem_Unmap
             (Address_Space => Syscalls.Address_Space_Cap,
              VA            => Buf_Win_VA,
              Length        => Buf_Bytes) /= 0
         then
            Akernel_User.Console.Put_Line
              ("fileserver: buffer unmap failed");
         end if;
         if Syscalls.Cap_Delete (Buf) /= 0 then
            Akernel_User.Console.Put_Line
              ("fileserver: buffer cap delete failed");
         end if;
      end if;

      Reply2 (Status, Count);
   end Handle_Write;

   procedure Handle_Read is
      Offset : constant U64 := Syscalls.Message.Words (0);
      Length : constant U64 := Syscalls.Message.Words (1);
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      Name   : String (1 .. 32);
      Len    : Natural := 0;
      Pos    : Natural := 1;
      V      : Natural := 0;
      I      : Natural := 0;
      Count  : U64 := 0;
      Status : U64 := Files.Status_Ok;
      Mapped : Boolean := False;
      Ok     : Boolean;

      procedure Process is
      begin
         if not Names_Done then
            Status := Files.Status_Not_Ready;
            return;
         end if;

         if Buf = 0
           or else Length = 0
           or else not Name_Of (2, 5, Name, Len)
         then
            Status := Files.Status_Bad_Args;
            return;
         end if;

         V := Resolve_Volume (Name, Len, Pos);
         if V = 0 then
            Status := Files.Status_Not_Found;
            return;
         end if;

         if Volumes (V).Is_FS then
            --  VFS forwarding: offset/length in words 0..1, path
            --  in words 2..5, the client's buffer cap forwarded in
            --  slot 0 (the fs driver maps, fills and cap_deletes
            --  its own copy; ours is deleted below).
            Syscalls.Message.Words (0) := Offset;
            Syscalls.Message.Words (1) := Length;
            Pack_Path (Name, Pos, Len, 2);
            Syscalls.Message.Label := Files.Op_Read;
            Syscalls.Message.Caps := (0 => Buf, others => 0);
            if Syscalls.IPC_Call (Volumes (V).FS_EP) = Syscalls.IPC_Ok then
               Status := Syscalls.Message.Words (0);
               Count := Syscalls.Message.Words (1);
            else
               Status := Files.Status_Not_Found;
            end if;
            return;
         end if;

         if Volumes (V).Is_Block then
            if not Match ("disk", 4, Name (Pos .. Len),
                          Volumes (V).Case_Insensitive)
            then
               Status := Files.Status_Not_Found;
               return;
            end if;

            Handle_Block_Read (V, Buf, Offset, Length,
                               Status, Count, Mapped);
            return;
         end if;

         I := Find (Name (Pos .. Len), V);
         if I = 0 then
            Status := Files.Status_Not_Found;
            return;
         end if;

         if Offset >= File_Table (I).Size then
            Status := Files.Status_Out_Of_Range;
            return;
         end if;

         Ensure_Mapped (I, Ok);
         if not Ok then
            Status := Files.Status_Not_Found;
            return;
         end if;

         if not Map_Buf (Buf) then
            Status := Files.Status_Not_Found;
            return;
         end if;
         Mapped := True;

         Count := U64'Min (Length, File_Table (I).Size - Offset);
         Count := U64'Min (Count, Buf_Bytes);

         declare
            Src : Byte_Array (0 .. Count - 1)
              with Address => To_Address (Integer_Address
                (File_Table (I).Win_VA + File_Table (I).Lead_In + Offset));
            Dst : Byte_Array (0 .. Count - 1)
              with Address => To_Address (Integer_Address (Buf_Win_VA));
         begin
            Dst := Src;
         end;
      end Process;
   begin
      Process;

      --  Every Op_Read transfers the client's buffer cap into this
      --  table; drop the mapping and the cap or leak a slot per op.
      if Buf /= 0 then
         if Mapped
           and then Syscalls.Mem_Unmap
             (Address_Space => Syscalls.Address_Space_Cap,
              VA            => Buf_Win_VA,
              Length        => Buf_Bytes) /= 0
         then
            Akernel_User.Console.Put_Line
              ("fileserver: buffer unmap failed");
         end if;
         if Syscalls.Cap_Delete (Buf) /= 0 then
            Akernel_User.Console.Put_Line
              ("fileserver: buffer cap delete failed");
         end if;
      end if;

      Reply2 (Status, Count);
   end Handle_Read;

   --  Op_Delete/Truncate/Mkdir/Rmdir: path-only mutating ops
   --  (path rides words 0..5 like Op_Stat, no buffer cap).
   --  Forwarded verbatim to fs-driver volumes; boot-file volumes
   --  are read-only and raw block volumes have no files.
   procedure Handle_Path_Op is
      Op   : constant U64 := Syscalls.Message.Label;
      Name : String (1 .. 48);
      Len  : Natural;
      Pos  : Natural;
      V    : Natural;
   begin
      if not Names_Done then
         Reply2 (Files.Status_Not_Ready, 0);
         return;
      end if;

      if not Name_Of (0, 5, Name, Len) then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      V := Resolve_Volume (Name, Len, Pos);
      if V = 0 then
         Reply2 (Files.Status_Not_Found, 0);
         return;
      end if;

      if Volumes (V).Is_FS then
         Pack_Path (Name, Pos, Len, 0);
         Syscalls.Message.Label := Op;
         Syscalls.Message.Caps := (others => 0);
         if Syscalls.IPC_Call (Volumes (V).FS_EP) = Syscalls.IPC_Ok then
            Reply2 (Syscalls.Message.Words (0),
                    Syscalls.Message.Words (1));
         else
            Reply2 (Files.Status_Not_Found, 0);
         end if;
         return;
      end if;

      Reply2 (Files.Status_Bad_Args, 0);
   end Handle_Path_Op;

begin
   Akernel_User.Console.Set_Endpoint (2);  --  console grant
   Akernel_User.Console.Put_Line ("fileserver online");

   loop
      if Syscalls.IPC_Recv (EP) /= Syscalls.IPC_Ok then
         Akernel_User.Console.Put_Line ("fileserver: recv failed");
         exit;
      end if;

      --  First Op_Set_Name batch: init pushes one message per boot
      --  file, then a final message with handle 0 = table complete.
      if Syscalls.Message.Label = Files.Op_Mount then
         Handle_Mount;
      elsif Syscalls.Message.Label = Files.Op_Add_Block then
         Handle_Add_Block;
      elsif Syscalls.Message.Label = Files.Op_Add_FS then
         Handle_Add_FS;
      elsif Syscalls.Message.Label = Files.Op_Write then
         Handle_Write;
      elsif Syscalls.Message.Label = Files.Op_Delete
        or else Syscalls.Message.Label = Files.Op_Truncate
        or else Syscalls.Message.Label = Files.Op_Mkdir
        or else Syscalls.Message.Label = Files.Op_Rmdir
      then
         Handle_Path_Op;
      elsif Syscalls.Message.Label = Files.Op_Set_Name then
         if Syscalls.Message.Words (0) = 0 then
            Names_Done := True;
            Reply2 (Files.Status_Ok, 0);
         else
            Handle_Set_Name;
         end if;
      elsif Syscalls.Message.Label = Files.Op_Stat
        or else Syscalls.Message.Label = Files.Op_Open
      then
         if not Names_Done then
            Reply2 (Files.Status_Not_Ready, 0);
         else
            Handle_Stat_Or_Open;
         end if;
      elsif Syscalls.Message.Label = Files.Op_Read then
         Handle_Read;
      else
         Reply2 (Files.Status_Bad_Args, 0);
      end if;
   end loop;

   loop
      Syscalls.Yield;
   end loop;
end Fileserver;
