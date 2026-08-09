with Akernel_User.Console;
with Akernel_User.Syscalls;
with Interfaces;
with System.Storage_Elements;

--  System/Fat32: read/write FAT32 driver. An independent filesystem
--  process behind the file server's VFS layer: it talks block
--  protocol to the virtio-blk service endpoint and speaks the
--  client file protocol on its own service endpoint (init mints it
--  and pushes the Send side to the VFS as Op_Add_FS, device BD0).
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
--  directory-entry create/update/delete. Creation takes 8.3
--  component names directly and other valid components via a
--  numeric-tail alias plus LFN entries; mkdir/rmdir, file delete
--  and truncate (to zero) round out the write path. Dirent
--  timestamps carry a fixed date (no RTC). No sparse writes.

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

   Op_Stat     : constant U64 := 1;
   Op_Open     : constant U64 := 2;
   Op_Read     : constant U64 := 3;
   Op_Write    : constant U64 := 7;
   Op_Delete   : constant U64 := 8;
   Op_Truncate : constant U64 := 9;
   Op_Mkdir    : constant U64 := 10;
   Op_Rmdir    : constant U64 := 11;
   Op_Sync     : constant U64 := 12;
   Op_ReadDir  : constant U64 := 13;
   Op_Rename   : constant U64 := 16;
   Op_Volume_Info : constant U64 := 17;

   Status_Ok           : constant U64 := 0;
   Status_Not_Found    : constant U64 := 1;
   Status_Bad_Args     : constant U64 := 3;
   Status_Out_Of_Range : constant U64 := 4;

   --  No RTC in the kernel: dirent create/write/access timestamps
   --  all carry this fixed date (FAT epoch encoding: year-1980 in
   --  bits 9..15, month 5..8, day 0..4) = 2025-01-01 00:00:00.
   Fixed_Date : constant U64 := 16#5A21#;
   Fixed_Time : constant U64 := 0;

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
   Total_Sectors : U64 := 0;  --  BPB 32-bit sector count (info op)
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
   --  Metadata sector cache (write-through)
   --
   --  FAT/directory/FSInfo sectors are re-read constantly (chain
   --  walks re-fetch the same FAT sector once per entry; lookup
   --  scans re-read directory clusters), so a handful of cached
   --  copies kills the repeated block RPCs.  Writes stay
   --  write-through; after every successful write the cached copy
   --  of each written sector is refreshed from the bounce, so the
   --  cache is always coherent with this driver's own writes (the
   --  driver is the sole writer through this path — a raw PDN
   --  volume write to the same partition bypasses and can stale
   --  the cache; do not raw-write a mounted partition).
   --  File data sectors deliberately bypass the cache on reads
   --  (streaming, never repeated).
   ------------------------------------------------------------------

   Cache_Slots : constant := 8;
   type Cache_Range is range 0 .. Cache_Slots - 1;
   subtype Sector_Bytes is Byte_Array (0 .. 511);

   Cache_Tag  : array (Cache_Range) of U64 := (others => U64'Last);
   Cache_Age  : array (Cache_Range) of U64 := (others => 0);
   Cache_Data : array (Cache_Range) of Sector_Bytes;
   Cache_Tick : U64 := 0;

   function Meta_Read (Sector : U64) return Boolean is
      Victim : Cache_Range := Cache_Range'First;
   begin
      for I in Cache_Range loop
         if Cache_Tag (I) = Sector then
            Cache_Tick := Cache_Tick + 1;
            Cache_Age (I) := Cache_Tick;
            Bounce (0 .. 511) := Cache_Data (I);
            return True;
         end if;
         if Cache_Age (I) < Cache_Age (Victim) then
            Victim := I;
         end if;
      end loop;

      if not Blk_Read_Sectors (Sector, 1) then
         return False;
      end if;

      --  Prefer an unused slot; otherwise evict the oldest.
      for I in Cache_Range loop
         if Cache_Tag (I) = U64'Last then
            Victim := I;
            exit;
         end if;
      end loop;

      Cache_Tick := Cache_Tick + 1;
      Cache_Tag (Victim) := Sector;
      Cache_Age (Victim) := Cache_Tick;
      Cache_Data (Victim) := Bounce (0 .. 511);
      return True;
   end Meta_Read;

   --  Cluster-granularity metadata reads cache the single-sector
   --  case (our images use 1-sector clusters); wider reads pass
   --  through uncached.
   function Meta_Read_Sectors (Sector : U64; Count : U64) return Boolean is
   begin
      if Count = 1 then
         return Meta_Read (Sector);
      end if;
      return Blk_Read_Sectors (Sector, Count);
   end Meta_Read_Sectors;

   --  Write-through with cache refresh: every write in the driver
   --  funnels here so a cached sector never goes stale against
   --  our own writes.
   function Meta_Write (Sector : U64; Count : U64) return Boolean is
   begin
      if not Blk_Write_Sectors (Sector, Count) then
         return False;
      end if;
      for I in Cache_Range loop
         if Cache_Tag (I) /= U64'Last
           and then Cache_Tag (I) >= Sector
           and then Cache_Tag (I) < Sector + Count
         then
            declare
               Off : constant U64 := (Cache_Tag (I) - Sector) * 512;
            begin
               Cache_Data (I) := Bounce (Off .. Off + 511);
            end;
         end if;
      end loop;
      return True;
   end Meta_Write;

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
      if not Meta_Read (Fat_Start + Fat_Off / 512) then
         return 0;
      end if;
      V := LE32 (Fat_Off mod 512) and 16#0FFF_FFFF#;
      if V >= 16#0FFF_FFF8# or else V < 2 then
         return 0;
      end if;
      return V;
   end Next_Cluster;

   --  Set one FAT entry, mirrored into every FAT copy. The top 4
   --  reserved bits of the existing entry are preserved; only the
   --  low 28 bits carry the value (writing them set on a link
   --  entry makes mtools/fsck flag the chain as corrupt).
   function Set_Fat_Entry (C : U64; Val : U64) return Boolean is
      Fat_Off   : constant U64 := C * 4;
      Sec_In    : constant U64 := Fat_Off / 512;
      Ent_Off   : constant U64 := Fat_Off mod 512;
   begin
      if not Meta_Read (Fat_Start + Sec_In) then
         return False;
      end if;
      Put32 (Ent_Off, (LE32 (Ent_Off) and 16#F000_0000#)
               or (Val and 16#0FFF_FFFF#));
      for I in 0 .. Num_Fats - 1 loop
         if not Meta_Write
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
      return Meta_Write (Cluster_Sector (C), Sec_Per_Clus);
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
            if not Meta_Read (Fat_Start + Fat_Off / 512) then
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
      if Meta_Read (1) then
         if LE32 (488) /= 16#FFFF_FFFF# and then LE32 (488) > 0 then
            Put32 (488, LE32 (488) - 1);
         end if;
         Put32 (492, Next_Free);
         if not Meta_Write (1, 1) then
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
   --  Found_Clus/Found_Ent locate the entry chain-wise and
   --  Run_Clus/Run_Ent the start of its LFN run (the first entry
   --  after the previous plain or deleted entry) so a delete can
   --  mark the whole sequence 0xE5.
   function Find_In_Dir
     (Dir_Clus    : U64;
      Comp        : String;
      Entry_Clus  : out U64;
      Entry_Size  : out U64;
      Is_Dir      : out Boolean;
      Dir_Sector  : out U64;
      Dir_Off     : out U64;
      Last_Clus   : out U64;
      Found_Clus  : out U64;
      Found_Ent   : out U64;
      Run_Clus    : out U64;
      Run_Ent     : out U64) return Boolean
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
      Found_Clus := 0;
      Found_Ent := 0;
      Run_Clus := C;
      Run_Ent := 0;

      for Guard in 0 .. 512 loop
         if not Meta_Read_Sectors (Cluster_Sector (C), Sec_Per_Clus) then
            return False;
         end if;

         if Run_Ent >= Sec_Per_Clus * 16 then
            Run_Clus := C;  --  run continues at this cluster's head
            Run_Ent := 0;
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
               Run_Clus := C;
               Run_Ent := Ent + 1;
            elsif Attr = 16#0F# then
               Collect_LFN (Base);
            elsif (Attr and 16#08#) /= 0 then
               LFN_Len := 0;  --  volume label
               Run_Clus := C;
               Run_Ent := Ent + 1;
            else
               if Match_Component (Comp, Base) then
                  Entry_Clus := LE16 (Base + 20) * 16#1_0000#
                    + LE16 (Base + 26);
                  Entry_Size := LE32 (Base + 28);
                  Is_Dir := (Attr and 16#10#) /= 0;
                  Dir_Sector := Cluster_Sector (C) + Ent / 16;
                  Dir_Off := (Ent mod 16) * 32;
                  Found_Clus := C;
                  Found_Ent := Ent;
                  return True;
               end if;
               LFN_Len := 0;
               Run_Clus := C;
               Run_Ent := Ent + 1;
            end if;
         end loop;

         Last_Clus := C;
         C := Next_Cluster (C);
         exit when C = 0;
      end loop;
      return False;
   end Find_In_Dir;

   --  8.3 short name of the entry at Ent_Off in Bounce ("FOO.BAR").
   function Short_Name_Of (Ent_Off : U64) return String is
      Short : String (1 .. 12);
      SL    : Natural := 0;
   begin
      for J in 0 .. 7 loop
         exit when Bounce (Ent_Off + U64 (J)) = 16#20#;
         SL := SL + 1;
         Short (SL) :=
           Character'Val (Natural (Bounce (Ent_Off + U64 (J))));
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
      return Short (1 .. SL);
   end Short_Name_Of;

   --  Enumerate the Index-th live entry (0-based) of the
   --  directory chain at Dir_Clus (Op_ReadDir): deleted entries,
   --  LFN fragments and volume labels are skipped; the LFN run
   --  preceding a short entry supplies the name when present.
   function Dir_Entry_At
     (Dir_Clus   : U64;
      Index      : U64;
      Name       : out String;
      Name_Len   : out Natural;
      Entry_Size : out U64;
      Is_Dir     : out Boolean) return Boolean
   is
      C    : U64 := Dir_Clus;
      B0   : Interfaces.Unsigned_8;
      Attr : Interfaces.Unsigned_8;
      Base : U64;
      N    : U64 := 0;
   begin
      Name_Len := 0;
      Entry_Size := 0;
      Is_Dir := False;
      LFN_Len := 0;

      for Guard in 0 .. 512 loop
         if not Meta_Read_Sectors (Cluster_Sector (C), Sec_Per_Clus)
         then
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
            elsif B0 = 16#2E#
              and then (Bounce (Base + 1) = 16#20#
                        or else (Bounce (Base + 1) = 16#2E#
                                 and then Bounce (Base + 2) = 16#20#))
            then
               --  "." / ".." pseudo-entries (subdirectories only;
               --  the milestone-32 root walk never met them —
               --  38b's subdir stress count did).
               LFN_Len := 0;
            else
               if N = Index then
                  if LFN_Len > 0 then
                     Name_Len := Natural'Min (LFN_Len, Name'Length);
                     Name (Name'First .. Name'First + Name_Len - 1) :=
                       LFN_Buf (1 .. Name_Len);
                  else
                     declare
                        SN : constant String := Short_Name_Of (Base);
                     begin
                        Name_Len :=
                          Natural'Min (SN'Length, Name'Length);
                        Name (Name'First
                              .. Name'First + Name_Len - 1) :=
                          SN (SN'First .. SN'First + Name_Len - 1);
                     end;
                  end if;
                  Entry_Size := LE32 (Base + 28);
                  Is_Dir := (Attr and 16#10#) /= 0;
                  return True;
               end if;
               N := N + 1;
               LFN_Len := 0;
            end if;
         end loop;

         C := Next_Cluster (C);
         exit when C = 0;
      end loop;
      return False;
   end Dir_Entry_At;

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
      Comp_First  : out Natural;
      Found_Clus  : out U64;
      Found_Ent   : out U64;
      Run_Clus    : out U64;
      Run_Ent     : out U64) return Boolean
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
      Found_Clus := 0;
      Found_Ent := 0;
      Run_Clus := 0;
      Run_Ent := 0;

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
            Parent_Last, Found_Clus, Found_Ent, Run_Clus, Run_Ent);

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
           and then Ch /= '~'
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
           and then Ch /= '~'
         then
            return False;
         end if;
         Out_Name (8 + U64 (I)) :=
           Interfaces.Unsigned_8 (Character'Pos (Ch));
      end loop;
      return True;
   end Make_Short_Name;

   --  LFN-legal component: printable ASCII (no FAT-forbidden
   --  punctuation), <= 64 chars (the LFN assembly buffer bound),
   --  no trailing dot/space.
   function Valid_LFN (Comp : String) return Boolean is
   begin
      if Comp'Length = 0 or else Comp'Length > 64 then
         return False;
      end if;
      if Comp (Comp'Last) = ' ' or else Comp (Comp'Last) = '.' then
         return False;
      end if;
      for C of Comp loop
         if C < ' '
           or else C = '"'
           or else C = '*'
           or else C = '/'
           or else C = ':'
           or else C = '<'
           or else C = '>'
           or else C = '?'
           or else C = '\'
           or else C = '|'
         then
            return False;
         end if;
      end loop;
      return True;
   end Valid_LFN;

   --  VFAT short-name checksum over the 11-byte on-disk name.
   function LFN_Checksum
     (Short : Byte_Array) return Interfaces.Unsigned_8
   is
      Sum : Interfaces.Unsigned_8 := 0;
   begin
      for I in 0 .. 10 loop
         Sum := Interfaces.Shift_Right (Sum, 1)
           + (if (Sum and 1) = 1 then 16#80# else 0)
           + Short (U64 (I));
      end loop;
      return Sum;
   end LFN_Checksum;

   --  Numeric-tail short alias for an LFN component: up to 6 base
   --  chars (uppercased, illegal chars mapped to '_'), "~N",
   --  optional 3-char extension; N sweeps 1..9 until the alias is
   --  free in the parent directory.
   function Make_Alias
     (Parent_Clus : U64;
      Comp        : String;
      Out_Name    : out Byte_Array) return Boolean
   is
      function Short_Char (C : Character) return Character is
        (if C in 'a' .. 'z' then Upper (C)
         elsif C in 'A' .. 'Z'
           or else C in '0' .. '9'
           or else C = '_'
           or else C = '-'
         then C
         else '_');

      Dot   : Natural := 0;
      Base  : String (1 .. 6);
      BL    : Natural := 0;
      Ext   : String (1 .. 3);
      EL    : Natural := 0;
      Alias : String (1 .. 12);
      AL    : Natural;
      Found : Boolean;
      D1, D2, D3, D4, D5, D6, D7, D8, D9 : U64;
      DB    : Boolean;
   begin
      Out_Name := (others => 16#20#);
      for I in Comp'Range loop
         if Comp (I) = '.' then
            Dot := I;
         end if;
      end loop;

      declare
         Base_Last : constant Natural :=
           (if Dot = 0 then Comp'Last else Dot - 1);
      begin
         for I in Comp'First .. Base_Last loop
            exit when BL = 6;
            if Comp (I) /= ' ' and then Comp (I) /= '.' then
               BL := BL + 1;
               Base (BL) := Short_Char (Comp (I));
            end if;
         end loop;
         if Dot /= 0 then
            for I in Dot + 1 .. Comp'Last loop
               exit when EL = 3;
               if Comp (I) /= ' ' and then Comp (I) /= '.' then
                  EL := EL + 1;
                  Ext (EL) := Short_Char (Comp (I));
               end if;
            end loop;
         end if;
      end;

      if BL = 0 then
         return False;
      end if;

      for N in 1 .. 9 loop
         AL := BL;
         Alias (1 .. AL) := Base (1 .. BL);
         AL := AL + 1;
         Alias (AL) := '~';
         AL := AL + 1;
         Alias (AL) := Character'Val (Character'Pos ('0') + N);
         if EL > 0 then
            AL := AL + 1;
            Alias (AL) := '.';
            Alias (AL + 1 .. AL + EL) := Ext (1 .. EL);
            AL := AL + EL;
         end if;

         Found := Find_In_Dir
           (Parent_Clus, Alias (1 .. AL),
            D1, D2, DB, D3, D4, D5, D6, D7, D8, D9);
         if not Found then
            return Make_Short_Name (Alias (1 .. AL), Out_Name);
         end if;
      end loop;
      return False;
   end Make_Alias;

   --  Write one LFN directory entry into the bounce page at Off.
   --  Seq counts from 1; the entry holding the name's tail carries
   --  the 0x40 last flag. Character slots past the name get a
   --  0x0000 terminator then 0xFFFF fill.
   procedure Put_LFN_Entry
     (Off       : U64;
      Seq       : Natural;
      Last_Flag : Boolean;
      Comp      : String;
      Check     : Interfaces.Unsigned_8)
   is
      Base_Char : constant Natural := (Seq - 1) * 13;
      EOff      : U64;
      Pos       : Natural;
   begin
      Bounce (Off) := Interfaces.Unsigned_8
        (Seq + (if Last_Flag then 16#40# else 0));
      Bounce (Off + 11) := 16#0F#;
      Bounce (Off + 12) := 0;
      Bounce (Off + 13) := Check;
      Bounce (Off + 26) := 0;
      Bounce (Off + 27) := 0;
      for J in 0 .. 12 loop
         EOff := Off + (case J is
                          when 0 .. 4  => 1 + U64 (J) * 2,
                          when 5 .. 10 => 14 + U64 (J - 5) * 2,
                          when others  => 28 + U64 (J - 11) * 2);
         Pos := Base_Char + J;
         if Pos < Comp'Length then
            Bounce (EOff) :=
              Interfaces.Unsigned_8 (Character'Pos (Comp (Comp'First + Pos)));
            Bounce (EOff + 1) := 0;
         elsif Pos = Comp'Length then
            Bounce (EOff) := 0;
            Bounce (EOff + 1) := 0;
         else
            Bounce (EOff) := 16#FF#;
            Bounce (EOff + 1) := 16#FF#;
         end if;
      end loop;
   end Put_LFN_Entry;

   --  Locate a run of Need consecutive free 32-byte entries in
   --  the directory chain, extending the chain once when nothing
   --  fits. Runs may span a cluster link: a 0x00 "end of
   --  directory" entry must never precede live entries (readers
   --  stop scanning there), so when the old last cluster
   --  terminates early the run continues into the fresh cluster
   --  and overwrites the terminator. Returns the run start
   --  chain-wise (cluster + entry index); callers walk from there.
   function Find_Free_Dirents
     (Dir_Clus    : U64;
      Need        : U64;
      Run_Clus    : out U64;
      Run_Ent     : out U64) return Boolean
   is
      C        : U64 := Dir_Clus;
      Fresh    : U64;
      B0       : Interfaces.Unsigned_8;
      Run      : U64 := 0;
      N        : U64;
      Extended : Boolean := False;
   begin
      Run_Clus := 0;
      Run_Ent := 0;

      for Guard in 0 .. 512 loop
         if not Meta_Read_Sectors (Cluster_Sector (C), Sec_Per_Clus) then
            return False;
         end if;

         for Ent in 0 .. Sec_Per_Clus * 16 - 1 loop
            B0 := Bounce (Ent * 32);
            if B0 = 0 or else B0 = 16#E5# then
               if Run = 0 then
                  Run_Clus := C;
                  Run_Ent := Ent;
               end if;
               Run := Run + 1;
               if Run = Need then
                  return True;
               end if;
            else
               Run := 0;
            end if;
         end loop;

         N := Next_Cluster (C);
         if N = 0 then
            if Extended then
               return False;  --  unreachable: a fresh cluster is 16
            end if;           --  free entries and Need <= 6
            if not Alloc_Cluster (C, Fresh) then
               return False;
            end if;
            N := Fresh;
            Extended := True;
         end if;
         C := N;
      end loop;
      return False;
   end Find_Free_Dirents;

   --  Create an empty entry for Comp in Parent_Clus. Components
   --  that are not valid 8.3 names get a numeric-tail short alias
   --  plus LFN entries (Valid_LFN components only). Directories
   --  come with one allocated cluster holding "." and "..".
   --  Dir_Sector/Dir_Off locate the new SHORT entry on disk.
   function Create_Entry
     (Parent_Clus : U64;
      Comp        : String;
      Is_Dir      : Boolean;
      Dir_Sector  : out U64;
      Dir_Off     : out U64;
      New_Clus    : out U64) return Boolean
   is
      Short   : Byte_Array (0 .. 10);
      N_LFN   : Natural := 0;
      Run_C   : U64;
      Run_E   : U64;
      CC      : U64;
      EE      : U64;
      Sec     : U64;
      Off     : U64;
      Check   : Interfaces.Unsigned_8;
      Parent_Dot : U64;
   begin
      Dir_Sector := 0;
      Dir_Off := 0;
      New_Clus := 0;

      if not Make_Short_Name (Comp, Short) then
         if not Valid_LFN (Comp) then
            return False;
         end if;
         N_LFN := (Comp'Length + 12) / 13;
         if not Make_Alias (Parent_Clus, Comp, Short) then
            return False;
         end if;
      end if;

      if Is_Dir
        and then not Alloc_Cluster (0, New_Clus)
      then
         return False;
      end if;

      if not Find_Free_Dirents (Parent_Clus, U64 (N_LFN) + 1,
                                Run_C, Run_E)
      then
         return False;
      end if;

      --  Write the run entry by entry (each a read-modify-write of
      --  its sector): LFN entries in reverse order, then the short
      --  entry. The run may span a cluster link, so positions
      --  advance chain-wise (contiguity was verified by the scan).
      Check := LFN_Checksum (Short);
      CC := Run_C;
      EE := Run_E;
      for K in 0 .. N_LFN loop
         Sec := Cluster_Sector (CC) + EE / 16;
         Off := (EE mod 16) * 32;
         if not Meta_Read (Sec) then
            return False;
         end if;

         if K < N_LFN then
            Put_LFN_Entry (Off, N_LFN - K, K = 0, Comp, Check);
         else
            for I in 0 .. 31 loop
               Bounce (Off + U64 (I)) := 0;
            end loop;
            for I in 0 .. 10 loop
               Bounce (Off + U64 (I)) := Short (U64 (I));
            end loop;
            Bounce (Off + 11) := (if Is_Dir then 16#10# else 16#20#);
            Put16 (Off + 14, Fixed_Time);
            Put16 (Off + 16, Fixed_Date);
            Put16 (Off + 18, Fixed_Date);
            Put16 (Off + 22, Fixed_Time);
            Put16 (Off + 24, Fixed_Date);
            if Is_Dir then
               Put16 (Off + 20, New_Clus / 16#1_0000#);
               Put16 (Off + 26, New_Clus mod 16#1_0000#);
            end if;
         end if;

         if not Meta_Write (Sec, 1) then
            return False;
         end if;

         Dir_Sector := Sec;  --  loop ends on the short entry
         Dir_Off := Off;

         if K < N_LFN then
            EE := EE + 1;
            if EE >= Sec_Per_Clus * 16 then
               EE := 0;
               CC := Next_Cluster (CC);
            end if;
         end if;
      end loop;

      if Is_Dir then
         --  "." and ".." in the fresh (zeroed) cluster; ".." of a
         --  root child conventionally points at cluster 0.
         Parent_Dot :=
           (if Parent_Clus = Root_Clus then 0 else Parent_Clus);
         if not Meta_Read (Cluster_Sector (New_Clus)) then
            return False;
         end if;
         for I in 0 .. 10 loop
            Bounce (U64 (I)) := 16#20#;
            Bounce (32 + U64 (I)) := 16#20#;
         end loop;
         Bounce (0) := Character'Pos ('.');
         Bounce (11) := 16#10#;
         Put16 (14, Fixed_Time);
         Put16 (16, Fixed_Date);
         Put16 (18, Fixed_Date);
         Put16 (22, Fixed_Time);
         Put16 (24, Fixed_Date);
         Put16 (20, New_Clus / 16#1_0000#);
         Put16 (26, New_Clus mod 16#1_0000#);
         Bounce (32) := Character'Pos ('.');
         Bounce (33) := Character'Pos ('.');
         Bounce (32 + 11) := 16#10#;
         Put16 (32 + 14, Fixed_Time);
         Put16 (32 + 16, Fixed_Date);
         Put16 (32 + 18, Fixed_Date);
         Put16 (32 + 22, Fixed_Time);
         Put16 (32 + 24, Fixed_Date);
         Put16 (32 + 20, Parent_Dot / 16#1_0000#);
         Put16 (32 + 26, Parent_Dot mod 16#1_0000#);
         if not Meta_Write (Cluster_Sector (New_Clus), 1) then
            return False;
         end if;
      end if;
      return True;
   end Create_Entry;

   --  Create a dirent for an object that ALREADY has a cluster
   --  chain (Op_Rename, milestone 41): same short/LFN-run
   --  machinery as Create_Entry but no allocation — cluster,
   --  size and attributes are preserved from the old entry and
   --  no "."/".." are initialized (the directory keeps its own).
   function Create_Link_Entry
     (Parent_Clus : U64;
      Comp        : String;
      Is_Dir      : Boolean;
      Clus        : U64;
      Size        : U64;
      Attr        : Interfaces.Unsigned_8) return Boolean
   is
      Short   : Byte_Array (0 .. 10);
      N_LFN   : Natural := 0;
      Run_C   : U64;
      Run_E   : U64;
      CC      : U64;
      EE      : U64;
      Sec     : U64;
      Off     : U64;
      Check   : Interfaces.Unsigned_8;
   begin
      if not Make_Short_Name (Comp, Short) then
         if not Valid_LFN (Comp) then
            return False;
         end if;
         N_LFN := (Comp'Length + 12) / 13;
         if not Make_Alias (Parent_Clus, Comp, Short) then
            return False;
         end if;
      end if;

      if not Find_Free_Dirents (Parent_Clus, U64 (N_LFN) + 1,
                                Run_C, Run_E)
      then
         return False;
      end if;

      Check := LFN_Checksum (Short);
      CC := Run_C;
      EE := Run_E;
      for K in 0 .. N_LFN loop
         Sec := Cluster_Sector (CC) + EE / 16;
         Off := (EE mod 16) * 32;
         if not Meta_Read (Sec) then
            return False;
         end if;

         if K < N_LFN then
            Put_LFN_Entry (Off, N_LFN - K, K = 0, Comp, Check);
         else
            for I in 0 .. 31 loop
               Bounce (Off + U64 (I)) := 0;
            end loop;
            for I in 0 .. 10 loop
               Bounce (Off + U64 (I)) := Short (U64 (I));
            end loop;
            Bounce (Off + 11) := Attr;
            Put16 (Off + 14, Fixed_Time);
            Put16 (Off + 16, Fixed_Date);
            Put16 (Off + 18, Fixed_Date);
            Put16 (Off + 22, Fixed_Time);
            Put16 (Off + 24, Fixed_Date);
            Put16 (Off + 20, Clus / 16#1_0000#);
            Put16 (Off + 26, Clus mod 16#1_0000#);
            Put32 (Off + 28, Size);
         end if;

         if not Meta_Write (Sec, 1) then
            return False;
         end if;

         if K < N_LFN then
            EE := EE + 1;
            if EE >= Sec_Per_Clus * 16 then
               EE := 0;
               CC := Next_Cluster (CC);
            end if;
         end if;
      end loop;
      return True;
   end Create_Link_Entry;

   --  Point the ".." entry of a moved directory at its new
   --  parent (Op_Rename): entry index 1 of the first cluster,
   --  root parent conventionally recorded as cluster 0.
   function Fix_Dotdot (Dir_Clus : U64; Parent_Clus : U64) return Boolean
   is
      Parent_Dot : constant U64 :=
        (if Parent_Clus = Root_Clus then 0 else Parent_Clus);
   begin
      if not Meta_Read (Cluster_Sector (Dir_Clus)) then
         return False;
      end if;
      if Bounce (32) /= Character'Pos ('.')
        or else Bounce (33) /= Character'Pos ('.')
      then
         return False;  --  not a well-formed directory
      end if;
      Put16 (32 + 20, Parent_Dot / 16#1_0000#);
      Put16 (32 + 26, Parent_Dot mod 16#1_0000#);
      return Meta_Write (Cluster_Sector (Dir_Clus), 1);
   end Fix_Dotdot;

   --  Free every cluster of the chain at Start (raw zero entries —
   --  Set_Fat_Entry's preserve-bits mask would not mark them
   --  free), FSInfo free count / next-free and the allocation hint
   --  updated. Returns the number freed.
   function Free_Chain (Start : U64) return U64 is
      C       : U64 := Start;
      N       : U64;
      Count   : U64 := 0;
      Fat_Off : U64;
      Ignore  : Boolean;
   begin
      for Guard in 0 .. 65536 loop
         exit when C < 2;
         N := Next_Cluster (C);
         Fat_Off := C * 4;
         if not Meta_Read (Fat_Start + Fat_Off / 512) then
            return Count;
         end if;
         Put32 (Fat_Off mod 512, 0);
         for I in 0 .. Num_Fats - 1 loop
            Ignore := Meta_Write
              (Fat_Start + I * Fat_Sectors + Fat_Off / 512, 1);
         end loop;
         Count := Count + 1;
         C := N;
      end loop;

      if Count > 0 then
         if Meta_Read (1) then
            if LE32 (488) /= 16#FFFF_FFFF# then
               Put32 (488, LE32 (488) + Count);
            end if;
            Put32 (492, Start);
            Ignore := Meta_Write (1, 1);
         end if;
         Next_Free := Start;
      end if;
      return Count;
   end Free_Chain;

   --  Mark the dirent at Found_Clus/Found_Ent and the LFN entries
   --  of its run (Run_Clus/Run_Ent .. dirent) deleted (0xE5).
   function Delete_Dirent
     (Run_Clus   : U64;
      Run_Ent    : U64;
      Found_Clus : U64;
      Found_Ent  : U64) return Boolean
   is
      C     : U64 := Run_Clus;
      Ent   : U64 := Run_Ent;
      Total : U64;
   begin
      for Guard in 0 .. 512 loop
         if not Meta_Read_Sectors (Cluster_Sector (C), Sec_Per_Clus) then
            return False;
         end if;
         Total := Sec_Per_Clus * 16;
         while Ent < Total loop
            Bounce (Ent * 32) := 16#E5#;
            if C = Found_Clus and then Ent = Found_Ent then
               return Meta_Write
                 (Cluster_Sector (C), Sec_Per_Clus);
            end if;
            Ent := Ent + 1;
         end loop;
         --  Dirent is in a later cluster: flush this cluster's
         --  marks first — the Next_Cluster FAT read clobbers the
         --  bounce page.
         if not Meta_Write (Cluster_Sector (C), Sec_Per_Clus)
         then
            return False;
         end if;
         C := Next_Cluster (C);
         if C = 0 then
            return False;
         end if;
         Ent := 0;
      end loop;
      return False;
   end Delete_Dirent;

   --  Write back start cluster + size of an existing entry (and
   --  touch its access/write timestamps).
   function Update_Dirent
     (Dir_Sector : U64;
      Dir_Off    : U64;
      Cluster    : U64;
      Size       : U64) return Boolean
   is
   begin
      if not Meta_Read (Dir_Sector) then
         return False;
      end if;
      Put16 (Dir_Off + 18, Fixed_Date);
      Put16 (Dir_Off + 22, Fixed_Time);
      Put16 (Dir_Off + 24, Fixed_Date);
      Put16 (Dir_Off + 20, Cluster / 16#1_0000#);
      Put16 (Dir_Off + 26, Cluster mod 16#1_0000#);
      Put32 (Dir_Off + 28, Size);
      return Meta_Write (Dir_Sector, 1);
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
      F1, F2, F3, F4 : U64;
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
                          Comp_First, F1, F2, F3, F4)
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
   --  Op_ReadDir (milestone 32): words 0..3 = path ("" = root),
   --  word 4 = entry index. Reply: w0 = status, w1 = size,
   --  w2 = is_dir, words 3..5 = entry name (24 chars, NUL-padded).
   ------------------------------------------------------------------

   procedure Handle_Read_Dir is
      Entry_Clus  : U64;
      Entry_Size  : U64;
      Is_Dir      : Boolean;
      Dir_Sector  : U64;
      Dir_Off     : U64;
      Parent      : U64;
      Parent_Last : U64;
      Comp_First  : Natural;
      F1, F2, F3, F4 : U64;
      Idx         : constant U64 := Syscalls.Message.Words (4);
      Clus        : U64;
      Name        : String (1 .. 24) :=
        (others => Character'Val (0));
      Name_Len    : Natural;
   begin
      if not Fat_Ok then
         Reply2 (Status_Not_Found, 0);
         return;
      end if;

      declare
         Path : constant String := Path_Of (0);
      begin
         if Path'Length = 0 then
            Clus := Root_Clus;
         elsif Resolve_Path (Path, Entry_Clus, Entry_Size, Is_Dir,
                             Dir_Sector, Dir_Off, Parent, Parent_Last,
                             Comp_First, F1, F2, F3, F4)
           and then Is_Dir
         then
            Clus := Entry_Clus;
         else
            Reply2 (Status_Not_Found, 0);
            return;
         end if;
      end;

      if not Dir_Entry_At (Clus, Idx, Name, Name_Len,
                           Entry_Size, Is_Dir)
      then
         Reply2 (Status_Not_Found, 0);
         return;
      end if;

      Syscalls.Message.Words (0) := Status_Ok;
      Syscalls.Message.Words (1) := Entry_Size;
      Syscalls.Message.Words (2) := (if Is_Dir then 1 else 0);
      for W in 3 .. 5 loop
         Syscalls.Message.Words (W) := 0;
      end loop;
      for P in 1 .. Name_Len loop
         Syscalls.Message.Words (3 + (P - 1) / 8) :=
           Syscalls.Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Name (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply /= Syscalls.IPC_Ok then
         Fail ("fat32 readdir reply failed");
      end if;
   end Handle_Read_Dir;

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
         F1, F2, F3, F4 : U64;
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
                                 Parent_Last, Comp_First,
                                 F1, F2, F3, F4)
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
         F1, F2, F3, F4 : U64;
         Fresh_Clus  : U64;
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
                             Comp_First, F1, F2, F3, F4)
            then
               if Is_Dir then
                  Status := Status_Bad_Args;
                  return;
               end if;
            else
               --  Create in the resolved parent (8.3 names get a
               --  plain short entry, other valid components an LFN
               --  run plus numeric-tail alias).
               if Parent = 0
                 or else not Create_Entry
                   (Parent, Path (Comp_First .. Path'Last),
                    False, Dir_Sector, Dir_Off, Fresh_Clus)
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

            if not Meta_Write
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

   ------------------------------------------------------------------
   --  Op_Delete / Op_Truncate / Op_Mkdir / Op_Rmdir
   ------------------------------------------------------------------

   --  Shared resolve record for the path-only mutating ops: path
   --  rides message words 0..5 like Op_Stat (no buffer cap).
   procedure Handle_Delete is
      Entry_Clus  : U64;
      Entry_Size  : U64;
      Is_Dir      : Boolean;
      Dir_Sector  : U64;
      Dir_Off     : U64;
      Parent      : U64;
      Parent_Last : U64;
      Comp_First  : Natural;
      Found_Clus  : U64;
      Found_Ent   : U64;
      Run_Clus    : U64;
      Run_Ent     : U64;
      Ignore      : U64;
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

         if not Resolve_Path (Path, Entry_Clus, Entry_Size, Is_Dir,
                              Dir_Sector, Dir_Off, Parent, Parent_Last,
                              Comp_First, Found_Clus, Found_Ent,
                              Run_Clus, Run_Ent)
         then
            Reply2 (Status_Not_Found, 0);
            return;
         end if;

         if Is_Dir then
            Reply2 (Status_Bad_Args, 0);  --  directories: Op_Rmdir
            return;
         end if;

         Ignore := Free_Chain (Entry_Clus);
         if Delete_Dirent (Run_Clus, Run_Ent, Found_Clus, Found_Ent) then
            Reply2 (Status_Ok, 0);
         else
            Reply2 (Status_Not_Found, 0);
         end if;
      end;
   end Handle_Delete;

   procedure Handle_Truncate is
      Entry_Clus  : U64;
      Entry_Size  : U64;
      Is_Dir      : Boolean;
      Dir_Sector  : U64;
      Dir_Off     : U64;
      Parent      : U64;
      Parent_Last : U64;
      Comp_First  : Natural;
      Found_Clus  : U64;
      Found_Ent   : U64;
      Run_Clus    : U64;
      Run_Ent     : U64;
      Ignore      : U64;
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

         if not Resolve_Path (Path, Entry_Clus, Entry_Size, Is_Dir,
                              Dir_Sector, Dir_Off, Parent, Parent_Last,
                              Comp_First, Found_Clus, Found_Ent,
                              Run_Clus, Run_Ent)
         then
            Reply2 (Status_Not_Found, 0);
            return;
         end if;

         if Is_Dir then
            Reply2 (Status_Bad_Args, 0);
            return;
         end if;

         Ignore := Free_Chain (Entry_Clus);
         if Update_Dirent (Dir_Sector, Dir_Off, 0, 0) then
            Reply2 (Status_Ok, 0);
         else
            Reply2 (Status_Not_Found, 0);
         end if;
      end;
   end Handle_Truncate;

   procedure Handle_Mkdir is
      Entry_Clus  : U64;
      Entry_Size  : U64;
      Is_Dir      : Boolean;
      Dir_Sector  : U64;
      Dir_Off     : U64;
      Parent      : U64;
      Parent_Last : U64;
      Comp_First  : Natural;
      Found_Clus  : U64;
      Found_Ent   : U64;
      Run_Clus    : U64;
      Run_Ent     : U64;
      Fresh_Clus  : U64;
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
                          Comp_First, Found_Clus, Found_Ent,
                          Run_Clus, Run_Ent)
         then
            Reply2 (Status_Bad_Args, 0);  --  already exists
            return;
         end if;

         if Parent = 0 then
            Reply2 (Status_Not_Found, 0);  --  bad intermediate
            return;
         end if;

         if Create_Entry (Parent,
                          Path (Comp_First .. Path'Last), True,
                          Dir_Sector, Dir_Off, Fresh_Clus)
         then
            Reply2 (Status_Ok, 0);
         else
            Reply2 (Status_Bad_Args, 0);  --  invalid component
         end if;
      end;
   end Handle_Mkdir;

   procedure Handle_Rmdir is
      Entry_Clus  : U64;
      Entry_Size  : U64;
      Is_Dir      : Boolean;
      Dir_Sector  : U64;
      Dir_Off     : U64;
      Parent      : U64;
      Parent_Last : U64;
      Comp_First  : Natural;
      Found_Clus  : U64;
      Found_Ent   : U64;
      Run_Clus    : U64;
      Run_Ent     : U64;
      Ignore      : U64;
      C           : U64;
      B0          : Interfaces.Unsigned_8;
      Attr        : Interfaces.Unsigned_8;
      Is_Dot      : Boolean;
      Empty       : Boolean := True;
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

         if not Resolve_Path (Path, Entry_Clus, Entry_Size, Is_Dir,
                              Dir_Sector, Dir_Off, Parent, Parent_Last,
                              Comp_First, Found_Clus, Found_Ent,
                              Run_Clus, Run_Ent)
         then
            Reply2 (Status_Not_Found, 0);
            return;
         end if;

         if not Is_Dir then
            Reply2 (Status_Bad_Args, 0);  --  files: Op_Delete
            return;
         end if;

         --  Empty check: only ".", ".." and deleted entries may
         --  remain (orphan LFN entries count as content).
         C := Entry_Clus;
         Scan : for Guard in 0 .. 512 loop
            if not Meta_Read_Sectors (Cluster_Sector (C), Sec_Per_Clus)
            then
               Empty := False;
               exit Scan;
            end if;
            for Ent in 0 .. Sec_Per_Clus * 16 - 1 loop
               B0 := Bounce (Ent * 32);
               exit Scan when B0 = 0;
               if B0 /= 16#E5# then
                  Attr := Bounce (Ent * 32 + 11);
                  Is_Dot := Attr /= 16#0F#
                    and then Bounce (Ent * 32) = Character'Pos ('.')
                    and then (Bounce (Ent * 32 + 1) = 16#20#
                              or else
                                (Bounce (Ent * 32 + 1) =
                                   Character'Pos ('.')
                                 and then Bounce (Ent * 32 + 2) = 16#20#));
                  if not Is_Dot then
                     Empty := False;
                     exit Scan;
                  end if;
               end if;
            end loop;
            C := Next_Cluster (C);
            exit Scan when C = 0;
         end loop Scan;

         if not Empty then
            Reply2 (Status_Bad_Args, 0);
            return;
         end if;

         Ignore := Free_Chain (Entry_Clus);
         if Delete_Dirent (Run_Clus, Run_Ent, Found_Clus, Found_Ent) then
            Reply2 (Status_Ok, 0);
         else
            Reply2 (Status_Not_Found, 0);
         end if;
      end;
   end Handle_Rmdir;

   ------------------------------------------------------------------
   --  Op_Rename (milestone 41): FROM path in words 0..5 like the
   --  other path ops; the VFS already stripped both volume
   --  prefixes and placed the bare TO path NUL-terminated in the
   --  buffer (cap slot 0). Rename/move within the volume: the new
   --  dirent preserves cluster, size and attributes; directories
   --  get ".." pointed at the new parent; the old dirent run is
   --  deleted WITHOUT freeing the chain.
   ------------------------------------------------------------------

   procedure Handle_Rename is
      Buf     : constant U64 := Syscalls.Message.Caps (0);
      Entry_Clus  : U64;
      Entry_Size  : U64;
      Is_Dir      : Boolean;
      Dir_Sector  : U64;
      Dir_Off     : U64;
      Parent      : U64;
      Parent_Last : U64;
      Comp_First  : Natural;
      Found_Clus  : U64;
      Found_Ent   : U64;
      Run_Clus    : U64;
      Run_Ent     : U64;
      T_Entry_Clus  : U64;
      T_Entry_Size  : U64;
      T_Is_Dir      : Boolean;
      T_Dir_Sector  : U64;
      T_Dir_Off     : U64;
      T_Parent      : U64;
      T_Parent_Last : U64;
      T_Comp_First  : Natural;
      T_Found_Clus  : U64;
      T_Found_Ent   : U64;
      T_Run_Clus    : U64;
      T_Run_Ent     : U64;
      Attr    : Interfaces.Unsigned_8 := 0;
      Status  : U64 := Status_Ok;
      Mapped  : Boolean := False;
      Win     : Byte_Array (0 .. 47)
        with Address => To_Address (Integer_Address (Buf_Win_VA));

      procedure Process is
      begin
         if not Fat_Ok then
            Status := Status_Not_Found;
            return;
         end if;

         if Buf = 0 then
            Status := Status_Bad_Args;
            return;
         end if;

         declare
            Path : constant String := Path_Of (0);
            To   : String (1 .. 32);
            To_Len : Natural := 0;
         begin
            if Path'Length = 0 then
               Status := Status_Bad_Args;
               return;
            end if;

            if not Map_Buf (Buf) then
               Status := Status_Not_Found;
               return;
            end if;
            Mapped := True;
            for I in U64 (0) .. 31 loop
               exit when Win (I) = 0;
               To_Len := To_Len + 1;
               To (To_Len) := Character'Val (Natural (Win (I)));
            end loop;
            if Syscalls.Mem_Unmap
              (Address_Space => Syscalls.Address_Space_Cap,
               VA            => Buf_Win_VA,
               Length        => Buf_Bytes) /= 0
            then
               Akernel_User.Console.Put_Line
                 ("fat32: buffer unmap failed");
            end if;
            Mapped := False;

            if To_Len = 0 then
               Status := Status_Bad_Args;
               return;
            end if;

            --  Ancestor guard (case-folded): moving a directory
            --  into its own subtree is rejected.
            if To_Len > Path'Length
              and then To (Path'Length + 1) = '/'
            then
               declare
                  Match : Boolean := True;
               begin
                  for I in 1 .. Path'Length loop
                     if Upper (To (I)) /= Upper (Path (I)) then
                        Match := False;
                        exit;
                     end if;
                  end loop;
                  if Match then
                     Status := Status_Bad_Args;
                     return;
                  end if;
               end;
            end if;

            if not Resolve_Path (Path, Entry_Clus, Entry_Size, Is_Dir,
                                 Dir_Sector, Dir_Off, Parent,
                                 Parent_Last, Comp_First, Found_Clus,
                                 Found_Ent, Run_Clus, Run_Ent)
            then
               Status := Status_Not_Found;
               return;
            end if;

            --  Preserve the attribute byte from the old entry.
            if not Meta_Read (Dir_Sector) then
               Status := Status_Not_Found;
               return;
            end if;
            Attr := Bounce (Dir_Off + 11);

            if Resolve_Path (To (1 .. To_Len), T_Entry_Clus,
                             T_Entry_Size, T_Is_Dir, T_Dir_Sector,
                             T_Dir_Off, T_Parent, T_Parent_Last,
                             T_Comp_First, T_Found_Clus, T_Found_Ent,
                             T_Run_Clus, T_Run_Ent)
            then
               Status := Status_Bad_Args;  --  TO exists
               return;
            end if;

            if T_Parent = 0 then
               Status := Status_Not_Found;  --  bad intermediate
               return;
            end if;

            if not Create_Link_Entry
              (T_Parent, To (T_Comp_First .. To_Len), Is_Dir,
               Entry_Clus, Entry_Size, Attr)
            then
               Status := Status_Bad_Args;  --  invalid component
               return;
            end if;

            if Is_Dir
              and then not Fix_Dotdot (Entry_Clus, T_Parent)
            then
               Status := Status_Not_Found;
               return;
            end if;

            if Delete_Dirent (Run_Clus, Run_Ent, Found_Clus, Found_Ent)
            then
               Status := Status_Ok;
            else
               Status := Status_Not_Found;
            end if;
         end;
      end Process;
   begin
      Process;

      if Mapped
        and then Syscalls.Mem_Unmap
          (Address_Space => Syscalls.Address_Space_Cap,
           VA            => Buf_Win_VA,
           Length        => Buf_Bytes) /= 0
      then
         Akernel_User.Console.Put_Line ("fat32: buffer unmap failed");
      end if;
      if Buf /= 0
        and then Syscalls.Cap_Delete (Buf) /= 0
      then
         Akernel_User.Console.Put_Line ("fat32: buffer cap delete failed");
      end if;

      Reply2 (Status, 0);
   end Handle_Rename;

   ------------------------------------------------------------------
   --  Op_Volume_Info (milestone 41): (status, total bytes, free
   --  bytes, bytes per cluster). Free rides the FSInfo count read
   --  fresh from sector 1; U64'Last = unknown.
   ------------------------------------------------------------------

   procedure Handle_Volume_Info is
      Total_Clus : U64;
      Free_Clus  : U64 := U64'Last;
   begin
      if not Fat_Ok or else Total_Sectors <= Data_Start then
         Reply2 (Status_Not_Found, 0);
         return;
      end if;

      Total_Clus := (Total_Sectors - Data_Start) / Sec_Per_Clus;

      --  FSInfo (sector 1): free count at 488; 0xFFFFFFFF = unknown.
      if Meta_Read (1) and then LE32 (488) /= 16#FFFF_FFFF# then
         Free_Clus := LE32 (488);
      end if;

      Syscalls.Message.Words (0) := Status_Ok;
      Syscalls.Message.Words (1) := Total_Clus * Clus_Bytes;
      Syscalls.Message.Words (2) :=
        (if Free_Clus = U64'Last then U64'Last
         else Free_Clus * Clus_Bytes);
      Syscalls.Message.Words (3) := Clus_Bytes;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply /= Syscalls.IPC_Ok then
         Fail ("fat32 reply failed");
      end if;
   end Handle_Volume_Info;

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
      Total_Sectors := LE32 (32);
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
      elsif Syscalls.Message.Label = Op_ReadDir then
         Handle_Read_Dir;
      elsif Syscalls.Message.Label = Op_Write then
         Handle_Write;
      elsif Syscalls.Message.Label = Op_Delete then
         Handle_Delete;
      elsif Syscalls.Message.Label = Op_Truncate then
         Handle_Truncate;
      elsif Syscalls.Message.Label = Op_Mkdir then
         Handle_Mkdir;
      elsif Syscalls.Message.Label = Op_Rmdir then
         Handle_Rmdir;
      elsif Syscalls.Message.Label = Op_Rename then
         Handle_Rename;
      elsif Syscalls.Message.Label = Op_Volume_Info then
         Handle_Volume_Info;
      elsif Syscalls.Message.Label = Op_Sync then
         --  Write-through cache: nothing dirty to flush (the hook
         --  exists for future write-back or device flush).
         Reply2 (Status_Ok, 0);
      else
         Reply2 (Status_Bad_Args, 0);
      end if;
   end loop;
end Fat32;
