with Akernel_User.Console;
with Akernel_User.Syscalls;
with Interfaces;
with System.Storage_Elements;

--  System/Fat32: read/write FAT32 driver. An independent filesystem
--  process behind the file server's VFS layer: it talks block
--  protocol to the virtio-blk service endpoint and speaks the
--  client file protocol on its own service endpoint (init mints it
--  and pushes the Send side to the VFS as Op_Add_FS, device HD0).
--
--  Handles: 1 = console endpoint, 2 = blk service EP, 3 = svc EP.
--
--  Layout: BPB probe at boot (0x55AA, 512-byte sectors, "FAT32   "
--  type string, cluster size <= 8 sectors so a cluster fits the
--  bounce page), then per-op: subdir/LFN-aware path lookup
--  (case-insensitive), FAT chain walks through the bounce page,
--  reads streaming cluster-by-cluster into the mapped client
--  buffer, writes with read-modify-write sectors, cluster chain
--  extension (free-cluster scan, FAT mirrors, FSInfo hint) and
--  directory-entry create/update. 8.3 component names only for
--  file creation; no sparse writes.

procedure Fat32 is
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

   Op_Stat  : constant U64 := 1;
   Op_Open  : constant U64 := 2;
   Op_Read  : constant U64 := 3;
   Op_Write : constant U64 := 7;

   Status_Ok           : constant U64 := 0;
   Status_Not_Found    : constant U64 := 1;
   Status_Bad_Args     : constant U64 := 3;
   Status_Out_Of_Range : constant U64 := 4;

   Buf_Win_VA : constant U64 := 16#5400_0000#;
   Blk_Buf_VA : constant U64 := 16#5000_0000#;

   Buf_Pages : constant U64 := 8;
   Buf_Bytes : constant U64 := Buf_Pages * Syscalls.Page_Size;

   type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;
   Bounce : Byte_Array (0 .. Syscalls.Page_Size - 1)
     with Address => To_Address (Integer_Address (Blk_Buf_VA));

   Blk_Buf_Cap : U64 := 0;

   --  Probed geometry.
   Fat_Ok       : Boolean := False;
   Sec_Per_Clus : U64 := 0;
   Clus_Bytes   : U64 := 0;
   Fat_Start    : U64 := 0;  --  first FAT sector (= reserved count)
   Fat_Sectors  : U64 := 0;  --  sectors per FAT
   Num_Fats     : U64 := 0;
   Data_Start   : U64 := 0;  --  first data sector (cluster 2)
   Root_Clus    : U64 := 0;
   Next_Free    : U64 := 2;  --  allocation scan hint

   function LE16 (Off : U64) return U64 is
     (U64 (Bounce (Off)) + U64 (Bounce (Off + 1)) * 256);

   function LE32 (Off : U64) return U64 is
     (LE16 (Off) + LE16 (Off + 2) * 16#1_0000#);

   procedure Put16 (Off : U64; V : U64) is
   begin
      Bounce (Off) := Interfaces.Unsigned_8 (V mod 256);
      Bounce (Off + 1) := Interfaces.Unsigned_8 ((V / 256) mod 256);
   end Put16;

   procedure Put32 (Off : U64; V : U64) is
   begin
      Put16 (Off, V mod 16#1_0000#);
      Put16 (Off + 2, V / 16#1_0000#);
   end Put32;

   function Shl (Value : U64; Amount : Natural) return U64
     renames Interfaces.Shift_Left;

   function Upper (C : Character) return Character is
   begin
      if C in 'a' .. 'z' then
         return Character'Val (Character'Pos (C) - 32);
      end if;
      return C;
   end Upper;

   ------------------------------------------------------------------
   --  Block RPCs through the bounce page
   ------------------------------------------------------------------

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

   function Blk_Write_Sectors (Sector : U64; Count : U64) return Boolean is
   begin
      Syscalls.Message.Label := Blk_Write;
      Syscalls.Message.Words (0) := Sector;
      Syscalls.Message.Words (1) := Count;
      Syscalls.Message.Caps := (0 => Blk_Buf_Cap, others => 0);
      return Syscalls.IPC_Call (Blk_EP) = Syscalls.IPC_Ok
        and then Syscalls.Message.Words (0) = 0;
   end Blk_Write_Sectors;

   ------------------------------------------------------------------
   --  FAT chain operations
   ------------------------------------------------------------------

   function Cluster_Sector (C : U64) return U64 is
     (Data_Start + (C - 2) * Sec_Per_Clus);

   --  Next cluster in chain, 0 at end.
   function Next_Cluster (C : U64) return U64 is
      Fat_Off : constant U64 := C * 4;
      V       : U64;
   begin
      if not Blk_Read_Sectors (Fat_Start + Fat_Off / 512, 1) then
         return 0;
      end if;
      V := LE32 (Fat_Off mod 512) and 16#0FFF_FFFF#;
      if V >= 16#0FFF_FFF8# or else V < 2 then
         return 0;
      end if;
      return V;
   end Next_Cluster;

   --  Set one FAT entry, mirrored into every FAT copy.
   function Set_Fat_Entry (C : U64; Val : U64) return Boolean is
      Fat_Off   : constant U64 := C * 4;
      Sec_In    : constant U64 := Fat_Off / 512;
      Ent_Off   : constant U64 := Fat_Off mod 512;
   begin
      if not Blk_Read_Sectors (Fat_Start + Sec_In, 1) then
         return False;
      end if;
      Put32 (Ent_Off, Val or 16#0F00_0000#);
      for I in 0 .. Num_Fats - 1 loop
         if not Blk_Write_Sectors
           (Fat_Start + I * Fat_Sectors + Sec_In, 1)
         then
            return False;
         end if;
      end loop;
      return True;
   end Set_Fat_Entry;

   function Zero_Cluster (C : U64) return Boolean is
   begin
      for I in 0 .. Clus_Bytes - 1 loop
         Bounce (I) := 0;
      end loop;
      return Blk_Write_Sectors (Cluster_Sector (C), Sec_Per_Clus);
   end Zero_Cluster;

   --  Allocate one free cluster: free-entry scan from the Next_Free
   --  hint, EOC marker, link from After (when nonzero), zeroed
   --  data, FSInfo free count / next-free hint updated when known.
   function Alloc_Cluster (After : U64; Result : out U64) return Boolean is
      Total : constant U64 := Fat_Sectors * 128;  --  entries per FAT
      Found : U64 := 0;
      C     : U64;
   begin
      Result := 0;
      C := Next_Free;
      for Scan in 0 .. Total - 1 loop
         if C >= Total or else C < 2 then
            C := 2;
         end if;
         declare
            Fat_Off : constant U64 := C * 4;
         begin
            if not Blk_Read_Sectors (Fat_Start + Fat_Off / 512, 1) then
               return False;
            end if;
            if LE32 (Fat_Off mod 512) = 0 then
               Found := C;
               exit;
            end if;
         end;
         C := C + 1;
      end loop;

      if Found = 0 then
         return False;
      end if;

      if not Set_Fat_Entry (Found, 16#0FFF_FFFF#)
        or else (After /= 0 and then not Set_Fat_Entry (After, Found))
        or else not Zero_Cluster (Found)
      then
         return False;
      end if;

      Next_Free := Found + 1;

      --  FSInfo (sector 1): free count at 488, next-free at 492.
      if Blk_Read_Sectors (1, 1) then
         if LE32 (488) /= 16#FFFF_FFFF# and then LE32 (488) > 0 then
            Put32 (488, LE32 (488) - 1);
         end if;
         Put32 (492, Next_Free);
         if not Blk_Write_Sectors (1, 1) then
            return False;
         end if;
      end if;

      Result := Found;
      return True;
   end Alloc_Cluster;

   --  Walk the chain at Start to index K; when Extend, allocate and
   --  link clusters past the end. Returns the cluster at index K.
   function Find_Or_Extend
     (Start : U64;
      K     : U64;
      Extend : Boolean;
      Result : out U64) return Boolean
   is
      C   : U64 := Start;
      I   : U64 := 0;
      N   : U64;
      Fresh : U64;
   begin
      Result := 0;
      if C = 0 then
         if not Extend then
            return False;
         end if;
         if not Alloc_Cluster (0, Fresh) then
            return False;
         end if;
         C := Fresh;
      end if;

      for Guard in 0 .. 65536 loop
         if I = K then
            Result := C;
            return True;
         end if;
         N := Next_Cluster (C);
         if N = 0 then
            if not Extend then
               return False;
            end if;
            if not Alloc_Cluster (C, Fresh) then
               return False;
            end if;
            N := Fresh;
         end if;
         C := N;
         I := I + 1;
      end loop;
      return False;
   end Find_Or_Extend;

   ------------------------------------------------------------------
   --  Directory lookup (subdirectories + LFN)
   ------------------------------------------------------------------

   --  Pending long-file-name assembly, reset at each plain entry.
   LFN_Buf : String (1 .. 64);
   LFN_Len : Natural := 0;

   procedure Collect_LFN (Ent_Off : U64) is
      Seq  : constant Natural := Natural (Bounce (Ent_Off) and 16#1F#);
      Base : constant Natural := (Seq - 1) * 13;
      Pos  : Natural;
      Hi   : Interfaces.Unsigned_8;
      Lo   : Interfaces.Unsigned_8;
      Off  : U64;
   begin
      for J in 0 .. 12 loop
         Off := Ent_Off + (case J is
                             when 0 .. 4  => 1 + U64 (J) * 2,
                             when 5 .. 10 => 14 + U64 (J - 5) * 2,
                             when others  => 28 + U64 (J - 11) * 2);
         Hi := Bounce (Off + 1);
         Lo := Bounce (Off);
         exit when Hi = 0 and then (Lo = 0 or else Lo = 16#FF#);
         Pos := Base + J + 1;
         if Pos <= 64 then
            if Hi /= 0 then
               LFN_Buf (Pos) := '?';  --  non-ASCII never matches
            else
               LFN_Buf (Pos) := Character'Val (Natural (Lo));
            end if;
            if Pos > LFN_Len then
               LFN_Len := Pos;
            end if;
         end if;
      end loop;
   end Collect_LFN;

   --  Case-insensitive compare of Comp against the assembled LFN
   --  (if any) or the dotted 8.3 short name at Ent_Off.
   function Match_Component (Comp : String; Ent_Off : U64) return Boolean is
      Short : String (1 .. 12);
      SL    : Natural := 0;
      Ch    : Character;
   begin
      if LFN_Len > 0 and then Comp'Length = LFN_Len then
         for I in Comp'Range loop
            if Upper (Comp (I)) /=
              Upper (LFN_Buf (I - Comp'First + 1))
            then
               return False;
            end if;
         end loop;
         return True;
      end if;

      for J in 0 .. 7 loop
         exit when Bounce (Ent_Off + U64 (J)) = 16#20#;
         SL := SL + 1;
         Short (SL) := Character'Val (Natural (Bounce (Ent_Off + U64 (J))));
      end loop;
      if Bounce (Ent_Off + 8) /= 16#20# then
         SL := SL + 1;
         Short (SL) := '.';
         for J in 8 .. 10 loop
            exit when Bounce (Ent_Off + U64 (J)) = 16#20#;
            SL := SL + 1;
            Short (SL) :=
              Character'Val (Natural (Bounce (Ent_Off + U64 (J))));
         end loop;
      end if;

      if Comp'Length /= SL then
         return False;
      end if;
      for I in Comp'Range loop
         Ch := Upper (Short (I - Comp'First + 1));
         if Upper (Comp (I)) /= Ch then
            return False;
         end if;
      end loop;
      return True;
   end Match_Component;

   --  Find component Comp in the directory chain at Dir_Clus. On
   --  success returns the entry's cluster/size/kind and the on-disk
   --  location (sector + offset) of its short directory entry.
   function Find_In_Dir
     (Dir_Clus    : U64;
      Comp        : String;
      Entry_Clus  : out U64;
      Entry_Size  : out U64;
      Is_Dir      : out Boolean;
      Dir_Sector  : out U64;
      Dir_Off     : out U64;
      Last_Clus   : out U64) return Boolean
   is
      C    : U64 := Dir_Clus;
      B0   : Interfaces.Unsigned_8;
      Attr : Interfaces.Unsigned_8;
      Base : U64;
   begin
      Entry_Clus := 0;
      Entry_Size := 0;
      Is_Dir := False;
      Dir_Sector := 0;
      Dir_Off := 0;
      Last_Clus := C;

      for Guard in 0 .. 512 loop
         if not Blk_Read_Sectors (Cluster_Sector (C), Sec_Per_Clus) then
            return False;
         end if;

         for Ent in 0 .. Sec_Per_Clus * 16 - 1 loop
            Base := Ent * 32;
            B0 := Bounce (Base);
            if B0 = 0 then
               return False;  --  end of directory
            end if;
            Attr := Bounce (Base + 11);
            if B0 = 16#E5# then
               LFN_Len := 0;
            elsif Attr = 16#0F# then
               Collect_LFN (Base);
            elsif (Attr and 16#08#) /= 0 then
               LFN_Len := 0;  --  volume label
            else
               if Match_Component (Comp, Base) then
                  Entry_Clus := LE16 (Base + 20) * 16#1_0000#
                    + LE16 (Base + 26);
                  Entry_Size := LE32 (Base + 28);
                  Is_Dir := (Attr and 16#10#) /= 0;
                  Dir_Sector := Cluster_Sector (C) + Ent / 16;
                  Dir_Off := (Ent mod 16) * 32;
                  return True;
               end if;
               LFN_Len := 0;
            end if;
         end loop;

         Last_Clus := C;
         C := Next_Cluster (C);
         exit when C = 0;
      end loop;
      return False;
   end Find_In_Dir;

   --  Resolve a '/'-separated path from the root. On a hit returns
   --  the entry fields; on a miss Parent_Clus/Parent_Last hold the
   --  innermost directory reached (create target) and Comp_First
   --  the start of the failing final component.
   function Resolve_Path
     (Path        : String;
      Entry_Clus  : out U64;
      Entry_Size  : out U64;
      Is_Dir      : out Boolean;
      Dir_Sector  : out U64;
      Dir_Off     : out U64;
      Parent_Clus : out U64;
      Parent_Last : out U64;
      Comp_First  : out Natural) return Boolean
   is
      Cur    : U64 := Root_Clus;
      Pos    : Natural := Path'First;
      Stop   : Natural;
      Found  : Boolean;
      Dummy  : U64;
   begin
      Entry_Clus := 0;
      Entry_Size := 0;
      Is_Dir := False;
      Dir_Sector := 0;
      Dir_Off := 0;
      Parent_Clus := 0;
      Parent_Last := 0;
      Comp_First := 0;

      if Path'Length = 0 then
         return False;
      end if;

      loop
         Stop := Pos;
         while Stop <= Path'Last and then Path (Stop) /= '/' loop
            Stop := Stop + 1;
         end loop;

         if Stop = Pos then
            return False;  --  empty component
         end if;

         Found := Find_In_Dir
           (Cur, Path (Pos .. Stop - 1),
            Entry_Clus, Entry_Size, Is_Dir, Dir_Sector, Dir_Off,
            Parent_Last);

         if Stop > Path'Last then
            --  Final component.
            if not Found then
               Parent_Clus := Cur;
               Comp_First := Pos;
            end if;
            return Found;
         end if;

         if not Found or else not Is_Dir then
            return False;  --  bad intermediate component
         end if;

         Cur := Entry_Clus;
         Pos := Stop + 1;
         if Pos > Path'Last then
            return False;  --  trailing slash
         end if;
      end loop;
   end Resolve_Path;

   ------------------------------------------------------------------
   --  Directory entry create/update (writes)
   ------------------------------------------------------------------

   --  8.3-valid component (letters, digits, '_', '-', '.'), folded
   --  to upper case into the 11-byte on-disk form.
   function Make_Short_Name
     (Comp : String;
      Out_Name : out Byte_Array) return Boolean
   is
      Dot   : Natural := 0;
      NLen  : Natural;
      EL    : Natural;
      Ch    : Character;
   begin
      Out_Name := (others => 16#20#);
      for I in Comp'Range loop
         if Comp (I) = '.' then
            if Dot /= 0 then
               return False;  --  more than one dot
            end if;
            Dot := I;
         end if;
      end loop;

      if Dot = Comp'First then
         return False;
      end if;

      NLen := (if Dot = 0 then Comp'Length else Dot - Comp'First);
      EL := (if Dot = 0 then 0 else Comp'Last - Dot);
      if NLen = 0 or else NLen > 8 or else EL > 3 then
         return False;
      end if;

      for I in 0 .. NLen - 1 loop
         Ch := Upper (Comp (Comp'First + I));
         if Ch not in 'A' .. 'Z'
           and then Ch not in '0' .. '9'
           and then Ch /= '_'
           and then Ch /= '-'
         then
            return False;
         end if;
         Out_Name (U64 (I)) :=
           Interfaces.Unsigned_8 (Character'Pos (Ch));
      end loop;

      for I in 0 .. EL - 1 loop
         Ch := Upper (Comp (Dot + 1 + I));
         if Ch not in 'A' .. 'Z'
           and then Ch not in '0' .. '9'
           and then Ch /= '_'
           and then Ch /= '-'
         then
            return False;
         end if;
         Out_Name (8 + U64 (I)) :=
           Interfaces.Unsigned_8 (Character'Pos (Ch));
      end loop;
      return True;
   end Make_Short_Name;

   --  Locate a free 32-byte slot in the directory chain, extending
   --  the chain with a fresh cluster when full.
   function Find_Free_Dirent
     (Dir_Clus    : U64;
      Last_Clus   : U64;
      Dir_Sector  : out U64;
      Dir_Off     : out U64) return Boolean
   is
      C   : U64 := Dir_Clus;
      Fresh : U64;
      B0  : Interfaces.Unsigned_8;
   begin
      Dir_Sector := 0;
      Dir_Off := 0;

      for Guard in 0 .. 512 loop
         if not Blk_Read_Sectors (Cluster_Sector (C), Sec_Per_Clus) then
            return False;
         end if;

         for Ent in 0 .. Sec_Per_Clus * 16 - 1 loop
            B0 := Bounce (Ent * 32);
            if B0 = 0 or else B0 = 16#E5# then
               Dir_Sector := Cluster_Sector (C) + Ent / 16;
               Dir_Off := (Ent mod 16) * 32;
               return True;
            end if;
         end loop;

         declare
            N : constant U64 := Next_Cluster (C);
         begin
            if N = 0 then
               exit;
            end if;
            C := N;
         end;
      end loop;

      --  Directory full: extend its chain.
      if not Alloc_Cluster (Last_Clus, Fresh) then
         return False;
      end if;
      Dir_Sector := Cluster_Sector (Fresh);
      Dir_Off := 0;
      return True;
   end Find_Free_Dirent;

   --  Create an empty file entry for Comp in Parent_Clus.
   function Create_File
     (Parent_Clus : U64;
      Parent_Last : U64;
      Comp        : String;
      Dir_Sector  : out U64;
      Dir_Off     : out U64) return Boolean
   is
      Short : Byte_Array (0 .. 10);
   begin
      Dir_Sector := 0;
      Dir_Off := 0;

      if not Make_Short_Name (Comp, Short) then
         return False;
      end if;

      if not Find_Free_Dirent (Parent_Clus, Parent_Last,
                               Dir_Sector, Dir_Off)
      then
         return False;
      end if;

      if not Blk_Read_Sectors (Dir_Sector, 1) then
         return False;
      end if;

      for I in 0 .. 31 loop
         Bounce (Dir_Off + U64 (I)) := 0;
      end loop;
      for I in 0 .. 10 loop
         Bounce (Dir_Off + U64 (I)) := Short (U64 (I));
      end loop;
      Bounce (Dir_Off + 11) := 16#20#;  --  archive
      return Blk_Write_Sectors (Dir_Sector, 1);
   end Create_File;

   --  Write back start cluster + size of an existing entry.
   function Update_Dirent
     (Dir_Sector : U64;
      Dir_Off    : U64;
      Cluster    : U64;
      Size       : U64) return Boolean
   is
   begin
      if not Blk_Read_Sectors (Dir_Sector, 1) then
         return False;
      end if;
      Put16 (Dir_Off + 20, Cluster / 16#1_0000#);
      Put16 (Dir_Off + 26, Cluster mod 16#1_0000#);
      Put32 (Dir_Off + 28, Size);
      return Blk_Write_Sectors (Dir_Sector, 1);
   end Update_Dirent;

   ------------------------------------------------------------------
   --  Request plumbing
   ------------------------------------------------------------------

   procedure Reply2 (Status : U64; Value : U64) is
   begin
      Syscalls.Message.Words (0) := Status;
      Syscalls.Message.Words (1) := Value;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply /= Syscalls.IPC_Ok then
         Fail ("fat32 reply failed");
      end if;
   end Reply2;

   --  Unpack the path from message words First .. 5.
   function Path_Of (First : Natural) return String is
      Name : String (1 .. 32) := (others => Character'Val (0));
      Len  : Natural := 0;
   begin
      for P in 0 .. 31 loop
         declare
            Ch : constant Character :=
              Character'Val (Natural
                ((Syscalls.Message.Words (First + P / 8)
                    / Shl (1, (P mod 8) * 8)) and 16#FF#));
         begin
            exit when Ch = Character'Val (0);
            Len := Len + 1;
            Name (Len) := Ch;
         end;
      end loop;
      return Name (1 .. Len);
   end Path_Of;

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

   ------------------------------------------------------------------
   --  Op_Stat / Op_Open
   ------------------------------------------------------------------

   procedure Handle_Stat_Or_Open is
      Entry_Clus  : U64;
      Entry_Size  : U64;
      Is_Dir      : Boolean;
      Dir_Sector  : U64;
      Dir_Off     : U64;
      Parent      : U64;
      Parent_Last : U64;
      Comp_First  : Natural;
   begin
      if not Fat_Ok then
         Reply2 (Status_Not_Found, 0);
         return;
      end if;

      declare
         Path : constant String := Path_Of (0);
      begin
         if Path'Length = 0 then
            Reply2 (Status_Bad_Args, 0);
            return;
         end if;

         if Resolve_Path (Path, Entry_Clus, Entry_Size, Is_Dir,
                          Dir_Sector, Dir_Off, Parent, Parent_Last,
                          Comp_First)
         then
            if Is_Dir then
               Reply2 (Status_Bad_Args, 0);  --  no dir stat/open
            else
               Reply2 (Status_Ok, Entry_Size);
            end if;
         else
            Reply2 (Status_Not_Found, 0);
         end if;
      end;
   end Handle_Stat_Or_Open;

   ------------------------------------------------------------------
   --  Op_Read
   ------------------------------------------------------------------

   procedure Handle_Read is
      Offset : constant U64 := Syscalls.Message.Words (0);
      Length : constant U64 := Syscalls.Message.Words (1);
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      Count  : U64 := 0;
      Status : U64 := Status_Ok;
      Mapped : Boolean := False;

      procedure Process is
         Entry_Clus  : U64;
         Entry_Size  : U64;
         Is_Dir      : Boolean;
         Dir_Sector  : U64;
         Dir_Off     : U64;
         Parent      : U64;
         Parent_Last : U64;
         Comp_First  : Natural;
         Done        : U64 := 0;
         C           : U64;
         Pos         : U64;
         Chunk       : U64;
         Skip        : U64;
         NSec        : U64;
      begin
         if not Fat_Ok or else Buf = 0 or else Length = 0 then
            Status := Status_Bad_Args;
            return;
         end if;

         declare
            Path : constant String := Path_Of (2);
         begin
            if Path'Length = 0 then
               Status := Status_Bad_Args;
               return;
            end if;

            if not Resolve_Path (Path, Entry_Clus, Entry_Size, Is_Dir,
                                 Dir_Sector, Dir_Off, Parent,
                                 Parent_Last, Comp_First)
              or else Is_Dir
            then
               Status := Status_Not_Found;
               return;
            end if;
         end;

         if Offset >= Entry_Size then
            Status := Status_Out_Of_Range;
            return;
         end if;

         Count := U64'Min (Length, Entry_Size - Offset);
         Count := U64'Min (Count, Buf_Bytes);

         if not Map_Buf (Buf) then
            Status := Status_Not_Found;
            Count := 0;
            return;
         end if;
         Mapped := True;

         while Done < Count loop
            Pos := Offset + Done;
            if not Find_Or_Extend (Entry_Clus, Pos / Clus_Bytes,
                                   False, C)
            then
               Status := Status_Not_Found;
               Count := 0;
               return;
            end if;

            Skip := Pos mod Clus_Bytes;
            NSec := U64'Min (Sec_Per_Clus - Skip / 512,
                             (Count - Done + (Skip mod 512) + 511)
                               / 512);

            if not Blk_Read_Sectors (Cluster_Sector (C) + Skip / 512,
                                     NSec)
            then
               Status := Status_Not_Found;
               Count := 0;
               return;
            end if;

            Chunk := U64'Min (NSec * 512 - (Skip mod 512),
                              Count - Done);

            declare
               Src : Byte_Array (0 .. Chunk - 1)
                 with Address => To_Address (Integer_Address
                   (Blk_Buf_VA + (Skip mod 512)));
               Dst : Byte_Array (0 .. Chunk - 1)
                 with Address => To_Address (Integer_Address
                   (Buf_Win_VA + Done));
            begin
               Dst := Src;
            end;

            Done := Done + Chunk;
         end loop;
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
              ("fat32: buffer unmap failed");
         end if;
         if Syscalls.Cap_Delete (Buf) /= 0 then
            Akernel_User.Console.Put_Line
              ("fat32: buffer cap delete failed");
         end if;
      end if;

      Reply2 (Status, Count);
   end Handle_Read;

   ------------------------------------------------------------------
   --  Op_Write
   ------------------------------------------------------------------

   procedure Handle_Write is
      Offset : constant U64 := Syscalls.Message.Words (0);
      Length : constant U64 := Syscalls.Message.Words (1);
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      Count  : U64 := 0;
      Status : U64 := Status_Ok;
      Mapped : Boolean := False;

      procedure Process is
         Entry_Clus  : U64;
         Entry_Size  : U64;
         Is_Dir      : Boolean;
         Dir_Sector  : U64;
         Dir_Off     : U64;
         Parent      : U64;
         Parent_Last : U64;
         Comp_First  : Natural;
         Done        : U64 := 0;
         C           : U64;
         Pos         : U64;
         Chunk       : U64;
         Skip        : U64;
         New_Size    : U64;
      begin
         if not Fat_Ok or else Buf = 0 or else Length = 0 then
            Status := Status_Bad_Args;
            return;
         end if;

         declare
            Path : constant String := Path_Of (2);
         begin
            if Path'Length = 0 then
               Status := Status_Bad_Args;
               return;
            end if;

            if Resolve_Path (Path, Entry_Clus, Entry_Size, Is_Dir,
                             Dir_Sector, Dir_Off, Parent, Parent_Last,
                             Comp_First)
            then
               if Is_Dir then
                  Status := Status_Bad_Args;
                  return;
               end if;
            else
               --  Create in the resolved parent (8.3 names only).
               if Parent = 0
                 or else not Create_File
                   (Parent, Parent_Last, Path (Comp_First .. Path'Last),
                    Dir_Sector, Dir_Off)
               then
                  Status := Status_Not_Found;
                  return;
               end if;
               Entry_Clus := 0;
               Entry_Size := 0;
            end if;
         end;

         --  No sparse writes: offset must not pass the current end.
         if Offset > Entry_Size then
            Status := Status_Out_Of_Range;
            return;
         end if;

         Count := U64'Min (Length, Buf_Bytes);

         if not Map_Buf (Buf) then
            Status := Status_Not_Found;
            Count := 0;
            return;
         end if;
         Mapped := True;

         while Done < Count loop
            Pos := Offset + Done;

            if not Find_Or_Extend (Entry_Clus, Pos / Clus_Bytes,
                                   True, C)
            then
               Status := Status_Not_Found;
               Count := 0;
               return;
            end if;

            if Entry_Clus = 0 then
               Entry_Clus := C;  --  first cluster of a new file
            end if;

            Skip := Pos mod 512;
            Chunk := U64'Min (512 - Skip, Count - Done);

            --  Read-modify-write the target sector.
            if not Blk_Read_Sectors
              (Cluster_Sector (C) + (Pos mod Clus_Bytes) / 512, 1)
            then
               Status := Status_Not_Found;
               Count := 0;
               return;
            end if;

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

            if not Blk_Write_Sectors
              (Cluster_Sector (C) + (Pos mod Clus_Bytes) / 512, 1)
            then
               Status := Status_Not_Found;
               Count := 0;
               return;
            end if;

            Done := Done + Chunk;
         end loop;

         New_Size := U64'Max (Entry_Size, Offset + Count);
         if not Update_Dirent (Dir_Sector, Dir_Off, Entry_Clus,
                               New_Size)
         then
            Status := Status_Not_Found;
            Count := 0;
            return;
         end if;
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
              ("fat32: buffer unmap failed");
         end if;
         if Syscalls.Cap_Delete (Buf) /= 0 then
            Akernel_User.Console.Put_Line
              ("fat32: buffer cap delete failed");
         end if;
      end if;

      Reply2 (Status, Count);
   end Handle_Write;

begin
   Akernel_User.Console.Set_Endpoint (Console_Cap);
   Akernel_User.Console.Put_Line ("fat32 starting");

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
      Fail ("fat32 bounce alloc failed");
   end if;

   --  BPB probe.
   Syscalls.Message.Label := Blk_Info;
   Syscalls.Message.Caps := (others => 0);
   if Syscalls.IPC_Call (Blk_EP) /= Syscalls.IPC_Ok
     or else Syscalls.Message.Words (0) /= 0
     or else not Blk_Read_Sectors (0, 1)
   then
      Fail ("fat32 blk probe failed");
   end if;

   Fat_Ok :=
     Bounce (510) = 16#55#
     and then Bounce (511) = 16#AA#
     and then LE16 (11) = 512
     and then Bounce (82) = 16#46#   --  'F'
     and then Bounce (83) = 16#41#   --  'A'
     and then Bounce (84) = 16#54#   --  'T'
     and then Bounce (85) = 16#33#   --  '3'
     and then Bounce (86) = 16#32#   --  '2'
     and then (Bounce (13) = 1
               or else Bounce (13) = 2
               or else Bounce (13) = 4
               or else Bounce (13) = 8);

   if Fat_Ok then
      Sec_Per_Clus := U64 (Bounce (13));
      Clus_Bytes := Sec_Per_Clus * 512;
      Fat_Start := LE16 (14);
      Num_Fats := U64 (Bounce (16));
      Fat_Sectors := LE32 (36);
      Data_Start := Fat_Start + Num_Fats * Fat_Sectors;
      Root_Clus := LE32 (44);
      Fat_Ok := Num_Fats >= 1
        and then Fat_Sectors > 0
        and then Root_Clus >= 2;
   end if;

   if not Fat_Ok then
      Fail ("fat32 no filesystem on device");
   end if;

   Akernel_User.Console.Put_Line ("fat32 online");

   loop
      if Syscalls.IPC_Recv (Svc_EP) /= Syscalls.IPC_Ok then
         Fail ("fat32 recv failed");
      end if;

      if Syscalls.Message.Label = Op_Stat
        or else Syscalls.Message.Label = Op_Open
      then
         Handle_Stat_Or_Open;
      elsif Syscalls.Message.Label = Op_Read then
         Handle_Read;
      elsif Syscalls.Message.Label = Op_Write then
         Handle_Write;
      else
         Reply2 (Status_Bad_Args, 0);
      end if;
   end loop;
end Fat32;
