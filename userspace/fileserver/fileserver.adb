with System;
with System.Storage_Elements;
with Interfaces;
with Akernel_User.Syscalls;
with Akernel_User.Files;
with Akernel_User.Console;
with Fileserver_Tables;
with Fileserver_Pipes;

--  File server (docs/IPC.md "file protocol"): holds every boot-file
--  cap (granted via the boot_files manifest token at handles 3..N)
--  and the Receive side of the fs endpoint (handle 1). Init first
--  sends Op_Mount (from the manifest's volume directive) binding a
--  device name (RD0) and volume label (Initrd) plus a
--  case-sensitivity flag to the boot-file set, then pushes the
--  name table as Op_Set_Name messages, each TRANSFERRING its
--  boot-file cap in slot 0 (38b: spawn grant lists cap at 32);
--  until the table is complete Stat/Open/Read answer
--  Status_Not_Ready.
--
--  Wire names are volume-qualified (VOL:path or LABEL:path);
--  unqualified names are rejected (client-side PATH resolution
--  prepends the default volume). Volume prefixes always compare
--  case-insensitively; path comparison uses the volume's flag.
--
--  Boot files are mapped as borrowed read-only pages (mem_map on a
--  Boot_File_Object cap) into ONE shared window on demand per
--  Op_Read, copied, unmapped (38b: no per-file VA windows — the
--  single-threaded loop never needs two files at once, so VA cost
--  is one window regardless of file count, and files larger than
--  the window read in chunked passes). File data starts Lead_In
--  bytes into the first page (cpio alignment). Op_Read copies
--  bytes into the client-owned buffer whose cap arrives in cap
--  slot 0; the most recent buffer stays mapped.

procedure Fileserver is
   use type Akernel_User.Syscalls.U64;
   use type Interfaces.Unsigned_8;
   use System.Storage_Elements;

   package Syscalls renames Akernel_User.Syscalls;
   package Files renames Akernel_User.Files;

   --  Big tables (File_Table/Volumes/Assigns + the Max_*
   --  constants and entry types) live in library-level package
   --  Fileserver_Tables — in this declarative part they would
   --  ride the 16 KiB mapped main stack (38b burn redux).
   use Fileserver_Tables;

   subtype U64 is Syscalls.U64;
   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of Byte;

   EP : constant U64 := 1;  --  fs_server grant: Receive side
   Reply_H : U64;  --  reply cap of the request being served (m47)

   Names_Done : Boolean := False;

   --  Volume/assign/entry docs live with the tables in
   --  fileserver_tables.ads.
   Max_Expanded : constant := 96;

   --  VA windows. Userspace VA map (see s-memory.adb): heap
   --  0x4000_0000..0x4020_0000, TEXT at 0x4600_0000, args
   --  0x4800_0000, stack/IPC 0x6FFx_xxxx. The file window is ONE
   --  shared 256 KiB window mapped on demand per read; the
   --  client-buffer and block-bounce windows are FIXED addresses
   --  — never derive them from a table size again: bumping
   --  Max_Files 32->128 slid Buf_Win_VA onto the text base and
   --  the server copied file data over its own code
   --  (37b-followup burn).
   File_Win_VA    : constant U64 := 16#4040_0000#;
   File_Win_Pages : constant U64 := 64;  --  256 KiB shared window
   Buf_Win_VA     : constant U64 := 16#4240_0000#;
   --  Compile-time guard: the file window must stay below the
   --  buffer window, and the buffer window below the text.
   Windows_Fit    : constant :=
     1 / Boolean'Pos
       (File_Win_VA + File_Win_Pages * Syscalls.Page_Size
          <= Buf_Win_VA
        and then Buf_Win_VA + 64 * Syscalls.Page_Size
                   <= 16#4600_0000#);

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

      if Colon = 0 then
         return 0;  --  unqualified
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

   function Find_Assign (Prefix : String) return Natural is
   begin
      for I in Assigns'Range loop
         if Assigns (I).Valid
           and then Match (Assigns (I).Name, Assigns (I).Name_Len,
                           Prefix, True)
         then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Assign;

   --  Create or replace an assign; False = no slot / bad args.
   function Set_Assign (Name : String; Target : String) return Boolean
   is
      Match_I : Natural := 0;
      Free_I  : Natural := 0;
      Slot    : Natural;
   begin
      if Name'Length = 0 or else Name'Length > 16
        or else Target'Length = 0 or else Target'Length > 48
      then
         return False;
      end if;
      for I in Assigns'Range loop
         if Assigns (I).Valid then
            if Match (Assigns (I).Name, Assigns (I).Name_Len,
                      Name, True)
            then
               Match_I := I;
               exit;
            end if;
         elsif Free_I = 0 then
            Free_I := I;
         end if;
      end loop;
      Slot := (if Match_I /= 0 then Match_I else Free_I);
      if Slot = 0 then
         return False;
      end if;
      Assigns (Slot).Valid := True;
      Assigns (Slot).Name := (others => Character'Val (0));
      Assigns (Slot).Name (1 .. Name'Length) := Name;
      Assigns (Slot).Name_Len := Name'Length;
      Assigns (Slot).Target := (others => Character'Val (0));
      Assigns (Slot).Target (1 .. Target'Length) := Target;
      Assigns (Slot).Tgt_Len := Target'Length;
      return True;
   end Set_Assign;

   --  Resolve a wire name to a volume, expanding assigns: on a
   --  volume miss the prefix is substituted from the assign table
   --  (implied "/" between target and rest, Amiga-style: C:Dir
   --  expands Sys:C/Dir) and resolution repeats, depth-capped.
   --  Expanded/Exp_Len carry the final wire name for the caller's
   --  path packing; Volume = 0 means unknown/unqualified.
   procedure Resolve_Full
     (Name     : String;
      Len      : Natural;
      Expanded : out String;
      Exp_Len  : out Natural;
      Volume   : out Natural;
      Path_Pos : out Natural)
   is
      Colon      : Natural;
      A          : Natural;
      Rest_First : Natural;
      Need_Sep   : Boolean;
      Add        : Natural;
   begin
      Volume := 0;
      Path_Pos := 1;
      Exp_Len := 0;
      Expanded := (others => Character'Val (0));
      if Len = 0 or else Len > Expanded'Length then
         return;
      end if;
      Exp_Len := Len;
      Expanded (Expanded'First .. Expanded'First + Len - 1) :=
        Name (Name'First .. Name'First + Len - 1);

      for Depth in 1 .. 4 loop
         Volume := Resolve_Volume (Expanded, Exp_Len, Path_Pos);
         if Volume /= 0 then
            return;
         end if;

         Colon := 0;
         for I in 1 .. Exp_Len loop
            if Expanded (I) = ':' then
               Colon := I;
               exit;
            end if;
         end loop;
         exit when Colon = 0;  --  unqualified: Volume stays 0

         A := Find_Assign
           (Expanded (Expanded'First .. Expanded'First + Colon - 2));
         exit when A = 0;

         Rest_First := Colon + 1;
         Need_Sep := Rest_First <= Exp_Len
           and then Assigns (A).Target (Assigns (A).Tgt_Len) /= ':'
           and then Assigns (A).Target (Assigns (A).Tgt_Len) /= '/';
         Add := Assigns (A).Tgt_Len + (if Need_Sep then 1 else 0)
                + (Exp_Len - Colon);
         if Add > Expanded'Length then
            Exp_Len := 0;
            Volume := 0;
            return;
         end if;
         declare
            New_Name : String (1 .. Max_Expanded) :=
              (others => Character'Val (0));
            P : Natural := Assigns (A).Tgt_Len;
         begin
            New_Name (1 .. P) :=
              Assigns (A).Target (1 .. Assigns (A).Tgt_Len);
            if Need_Sep then
               P := P + 1;
               New_Name (P) := '/';
            end if;
            if Rest_First <= Exp_Len then
               New_Name (P + 1 .. P + (Exp_Len - Colon)) :=
                 Expanded (Rest_First .. Exp_Len);
            end if;
            Exp_Len := Add;
            Expanded := New_Name;
         end;
      end loop;
      Volume := 0;
   end Resolve_Full;

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
      --  m75: replies transfer caps now; drop any received request
      --  caps (e.g. a forwarded Buf cap) still sitting in the buffer.
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
         Akernel_User.Console.Put_Line ("fileserver: reply failed");
      end if;
   end Reply2;

   --  Lazy cpio lead-in discovery: map one page at the shared
   --  window, learn Lead_In, drop the mapping. Reads then map
   --  the file's chunk at the window on demand.
   procedure Ensure_Lead_In (Index : Natural; Ok : out Boolean) is
      F : File_Entry renames File_Table (Index);
   begin
      Ok := True;
      if F.Lead_Known then
         return;
      end if;

      if Syscalls.Mem_Map_File
        (Address_Space => Syscalls.Address_Space_Cap,
         Cap           => F.Handle,
         VA            => File_Win_VA,
         Offset        => 0,
         Length        => Syscalls.Page_Size,
         Lead_In       => F.Lead_In) /= 0
      then
         Ok := False;
         return;
      end if;

      if Syscalls.Mem_Unmap
        (Address_Space => Syscalls.Address_Space_Cap,
         VA            => File_Win_VA,
         Length        => Syscalls.Page_Size) /= 0
      then
         Akernel_User.Console.Put_Line
           ("fileserver: lead-in unmap failed");
         Ok := False;
         return;
      end if;

      F.Lead_Known := True;
   end Ensure_Lead_In;

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


   --  Op_Sync: fan the flush out to every fs-driver volume and
   --  report the first failure.  Block-backed raw volumes and
   --  boot files are write-through / read-only — nothing to do.
   procedure Handle_Sync is
      Status : U64 := Files.Status_Ok;
   begin
      for V in Volumes'Range loop
         if Volumes (V).Valid and then Volumes (V).Is_FS then
            Syscalls.Message.Label := Files.Op_Sync;
            Syscalls.Message.Words := (others => 0);
            Syscalls.Message.Caps := (others => 0);
            if Syscalls.IPC_Call (Volumes (V).FS_EP) /= Syscalls.IPC_Ok
              or else Syscalls.Message.Words (0) /= Files.Status_Ok
            then
               Status := Files.Status_Not_Found;
            end if;
         end if;
      end loop;
      Reply2 (Status, 0);
   end Handle_Sync;

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

            --  Milestone 36: mounting the system volume (label
            --  "sys") seeds the session assigns C: and ENV: —
            --  the Amiga boot assigns — unless already set.
            if Match ("sys", 3,
                      Volumes (V).Label (1 .. Volumes (V).Lab_Len),
                      True)
            then
               declare
                  T  : String (1 .. 24) := (others => Character'Val (0));
                  TL : Natural := Volumes (V).Lab_Len;
               begin
                  T (1 .. TL) := Volumes (V).Label (1 .. TL);
                  if Find_Assign ("C") = 0 then
                     T (TL + 1) := ':';
                     T (TL + 2) := 'C';
                     if Set_Assign ("C", T (1 .. TL + 2)) then
                        null;
                     end if;
                  end if;
                  if Find_Assign ("ENV") = 0 then
                     T (TL + 1 .. TL + 10) := ":Prefs/Env";
                     if Set_Assign ("ENV", T (1 .. TL + 10)) then
                        null;
                     end if;
                  end if;
               end;
            end if;

            Reply2 (Files.Status_Ok, 0);
            return;
         end if;
      end loop;

      Reply2 (Files.Status_Bad_Args, 0);
   end Handle_Add_FS;

   --  Op_Set_Name: words 0..1 = (nonzero sentinel, name length),
   --  words 2..5 = name; the boot-file cap ARRIVES TRANSFERRED in
   --  cap slot 0 (milestone 38b — spawn grant lists cap at 32
   --  entries, far under the 256-file headroom target). The cap
   --  stays in this table for the file's lifetime — it IS the
   --  file, not a per-op borrow.
   procedure Handle_Set_Name is
      Handle : constant U64 := Syscalls.Message.Caps (0);
      Len    : constant Natural := Natural (Syscalls.Message.Words (1));
   begin
      if Len = 0 or else Len > Max_Name or else Handle = 0 then
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
            Reply2 (Files.Status_Ok, 0);
            return;
         end if;
      end loop;

      Reply2 (Files.Status_Bad_Args, 0);
   end Handle_Set_Name;

   --  Op_Assign: words 0..1 = name (no colon), words 2..5 =
   --  target; an empty target removes the assign.
   procedure Handle_Assign is
      Name  : String (1 .. 16);
      N_Len : Natural;
      Target : String (1 .. 32) := (others => Character'Val (0));
      T_Len : Natural := 0;
      C     : Character;
      A     : Natural;
      Bad   : Boolean := False;
   begin
      if not Name_Of (0, 1, Name, N_Len) then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;
      for I in 1 .. N_Len loop
         if Name (I) = ':' then
            Bad := True;
         end if;
      end loop;
      if Bad then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      for Pos in 0 .. 31 loop
         C := Unpack_Char (2, Pos);
         exit when C = Character'Val (0);
         T_Len := T_Len + 1;
         Target (T_Len) := C;
      end loop;

      if T_Len = 0 then
         A := Find_Assign (Name (1 .. N_Len));
         if A = 0 then
            Reply2 (Files.Status_Not_Found, 0);
         else
            Assigns (A).Valid := False;
            Reply2 (Files.Status_Ok, 0);
         end if;
         return;
      end if;

      if Set_Assign (Name (1 .. N_Len), Target (1 .. T_Len)) then
         Reply2 (Files.Status_Ok, 0);
      else
         Reply2 (Files.Status_Bad_Args, 0);
      end if;
   end Handle_Assign;

   --  Op_Assign_List: word 0 = index; reply words 1..5 pack
   --  "NAME: target" (NUL-padded), word 0 = status. Stateless,
   --  ReadDir-style: index N returns the N-th live entry.
   procedure Handle_Assign_List is
      Idx   : constant U64 := Syscalls.Message.Words (0);
      Seen  : U64 := 0;
      Line  : String (1 .. 40);
      L_Len : Natural;
   begin
      for I in Assigns'Range loop
         if Assigns (I).Valid then
            if Seen = Idx then
               L_Len := 0;
               for K in 1 .. Assigns (I).Name_Len loop
                  exit when L_Len >= 38;
                  L_Len := L_Len + 1;
                  Line (L_Len) := Assigns (I).Name (K);
               end loop;
               L_Len := L_Len + 1;
               Line (L_Len) := ':';
               L_Len := L_Len + 1;
               Line (L_Len) := ' ';
               for K in 1 .. Assigns (I).Tgt_Len loop
                  exit when L_Len >= 40;
                  L_Len := L_Len + 1;
                  Line (L_Len) := Assigns (I).Target (K);
               end loop;

               Syscalls.Message.Label := 0;
               Syscalls.Message.Words := (others => 0);
               for P in 0 .. L_Len - 1 loop
                  Syscalls.Message.Words (1 + P / 8) :=
                    Syscalls.Message.Words (1 + P / 8)
                      or Shl (U64 (Character'Pos (Line (P + 1))),
                              (P mod 8) * 8);
               end loop;
               Syscalls.Message.Words (0) := Files.Status_Ok;
               Syscalls.Message.Caps := (others => 0);
               if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
                  Akernel_User.Console.Put_Line
                    ("fileserver: reply failed");
               end if;
               return;
            end if;
            Seen := Seen + 1;
         end if;
      end loop;
      Reply2 (Files.Status_Not_Found, 0);
   end Handle_Assign_List;

   --  Pack Name (Pos .. Len) into the outgoing message words
   --  First_Word .. 5 (NUL-padded): the VFS forwards the path
   --  portion of a volume-qualified name to the fs driver.
   procedure Pack_Path
     (Name : String; Pos : Natural; Len : Natural; First_Word : Natural;
      Last_Word : Natural := 5)
   is
      W : Natural;
   begin
      for I in First_Word .. Last_Word loop
         Syscalls.Message.Words (I) := 0;
      end loop;
      for P in Pos .. Len loop
         W := First_Word + (P - Pos) / 8;
         exit when W > Last_Word;
         Syscalls.Message.Words (W) :=
           Syscalls.Message.Words (W)
             or Shl (U64 (Character'Pos (Name (Name'First + P - 1))),
                     ((P - Pos) mod 8) * 8);
      end loop;
   end Pack_Path;

   --  Milestone 41b/Proc:self: forward a client request to an
   --  fs-driver volume using a cap minted with the original
   --  caller's badge (now the caller's process id). The fs driver
   --  sees the real client identity in Message.Badge.
   Max_Forward_Caps : constant := 1024;
   type Forward_Cap_Entry is record
      Valid  : Boolean := False;
      Volume : Natural := 0;
      Badge  : U64 := 0;
      Cap    : U64 := 0;
   end record;
   Forward_Caps : array (1 .. Max_Forward_Caps) of Forward_Cap_Entry;

   --  Reuse a previously-minted forward cap when the same caller
   --  (badge = process id) hits the same fs-driver volume. This
   --  keeps the VFS forward path from paying for a cap_mint+delete
   --  on every fs operation. Bounded leak: at most one cap per
   --  live caller/volume pair.
   function Cached_FS_Cap (Volume : Natural; Badge : U64) return U64 is
   begin
      for E of Forward_Caps loop
         if E.Valid and then E.Volume = Volume and then E.Badge = Badge then
            return E.Cap;
         end if;
      end loop;
      return Syscalls.Syscall_Failed;
   end Cached_FS_Cap;

   procedure Store_FS_Cap
     (Volume : Natural;
      Badge  : U64;
      Cap    : U64;
      Stored : out Boolean)
   is
   begin
      Stored := False;
      for E of Forward_Caps loop
         if not E.Valid then
            E.Valid  := True;
            E.Volume := Volume;
            E.Badge  := Badge;
            E.Cap    := Cap;
            Stored   := True;
            return;
         end if;
      end loop;
   end Store_FS_Cap;

   function Is_Proc_Volume (Volume : Natural) return Boolean is
   begin
      return Volumes (Volume).Lab_Len = 4
        and then Match ("Proc", 4,
                        Volumes (Volume).Label (1 .. 4),
                        True);
   end Is_Proc_Volume;

   function Forward_To_FS (Volume : Natural; Caller_Badge : U64)
                            return Boolean
   is
      FS_EP  : U64 := Syscalls.Syscall_Failed;
      Stored : Boolean := False;
      Ok     : Boolean := False;
   begin
      --  Milestone 41b/Proc:self: caller identity is needed only
      --  for the Proc: introspection volume. For all other fs-driver
      --  volumes (Sys:, BD0:, etc.) use the unminted endpoint cap
      --  and avoid the cap_mint cost on every first access.
      if Is_Proc_Volume (Volume) then
         FS_EP := Cached_FS_Cap (Volume, Caller_Badge);
         if FS_EP = Syscalls.Syscall_Failed then
            FS_EP := Syscalls.Cap_Mint
              (Source      => Volumes (Volume).FS_EP,
               Rights_Mask =>
                 Syscalls.Right_Send + Syscalls.Right_Transfer,
               Badge       => Caller_Badge);
            if FS_EP /= Syscalls.Syscall_Failed then
               Store_FS_Cap (Volume, Caller_Badge, FS_EP, Stored);
               if not Stored then
                  --  Cache is full: don't leak the minted cap.
                  declare
                     Unused : U64;
                  begin
                     Unused := Syscalls.Cap_Delete (FS_EP);
                  end;
                  return False;
               end if;
            end if;
         end if;
      else
         FS_EP := Volumes (Volume).FS_EP;
      end if;

      if FS_EP = Syscalls.Syscall_Failed then
         return False;
      end if;

      Ok := Syscalls.IPC_Call (FS_EP) = Syscalls.IPC_Ok;
      return Ok;
   end Forward_To_FS;

   --  Op_ReadDir (milestone 32): words 0..3 = volume-qualified
   --  path, word 4 = entry index; FS-driver volumes only (the
   --  wire format matches the fs driver's: path portion repacked
   --  into words 0..3, index back into word 4). The reply rides
   --  through unchanged: w0 = status, w1 = size, w2 = is_dir,
   --  words 3..5 = entry name.
   procedure Handle_Read_Dir is
      Name : String (1 .. 32);
      Len  : Natural;
      Pos  : Natural;
      V    : Natural;
      Idx  : U64;
      Exp  : String (1 .. Max_Expanded);
      E_Len : Natural;
   begin
      if not Name_Of (0, 3, Name, Len) then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      Resolve_Full (Name, Len, Exp, E_Len, V, Pos);
      if V = 0 or else not Volumes (V).Is_FS then
         Reply2 (Files.Status_Not_Found, 0);
         return;
      end if;

      Idx := Syscalls.Message.Words (4);
      Syscalls.Message.Label := Files.Op_ReadDir;
      Pack_Path (Exp, Pos, E_Len, 0, 3);
      Syscalls.Message.Words (4) := Idx;
      Syscalls.Message.Caps := (others => 0);
      if Forward_To_FS (V, Syscalls.Message.Badge) then
         --  Relay the fs driver's reply words untouched.
         Syscalls.Message.Caps := (others => 0);
         if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
            Syscalls.Debug_Put_Line ("fileserver readdir reply failed");
            Syscalls.Process_Exit;
         end if;
      else
         Reply2 (Files.Status_Not_Found, 0);
      end if;
   end Handle_Read_Dir;

   --  Op_Attr_List (milestone 82d): words 0..3 = volume-qualified
   --  path, word 4 = attribute index; FS-driver volumes only (the
   --  wire format matches the fs driver's: path portion repacked
   --  into words 0..3, index back into word 4). The reply rides
   --  through unchanged: w0 = status, w1 = attr type code, w2 =
   --  attr data size, words 3..5 = attr name. Volumes without
   --  attribute support answer Not_Found (empty list semantics).
   procedure Handle_Attr_List is
      Name : String (1 .. 32);
      Len  : Natural;
      Pos  : Natural;
      V    : Natural;
      Idx  : U64;
      Exp  : String (1 .. Max_Expanded);
      E_Len : Natural;
   begin
      if not Name_Of (0, 3, Name, Len) then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      Resolve_Full (Name, Len, Exp, E_Len, V, Pos);
      if V = 0 or else not Volumes (V).Is_FS then
         Reply2 (Files.Status_Not_Found, 0);
         return;
      end if;

      Idx := Syscalls.Message.Words (4);
      Syscalls.Message.Label := Files.Op_Attr_List;
      Pack_Path (Exp, Pos, E_Len, 0, 3);
      Syscalls.Message.Words (4) := Idx;
      Syscalls.Message.Caps := (others => 0);
      if Forward_To_FS (V, Syscalls.Message.Badge) then
         --  Relay the fs driver's reply words untouched.
         Syscalls.Message.Caps := (others => 0);
         if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
            Syscalls.Debug_Put_Line ("fileserver attrlist reply failed");
            Syscalls.Process_Exit;
         end if;
      else
         Reply2 (Files.Status_Not_Found, 0);
      end if;
   end Handle_Attr_List;

   --  Op_Attr_Read (milestone 82d): words 0..3 = volume-qualified
   --  path, words 4..5 = attr name (16 chars), cap slot 0 = the
   --  client's buffer memobj, forwarded like Op_Read (the fs
   --  driver maps, fills and cap_deletes its own copy; ours is
   --  deleted at op end). The reply rides through unchanged:
   --  w0 = status, w1 = count copied, w2 = attr total size,
   --  w3 = type code. Volumes without attribute support answer
   --  Bad_Args.
   procedure Handle_Attr_Read is
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      Name   : String (1 .. 32);
      Len    : Natural;
      Pos    : Natural;
      V      : Natural;
      Status : U64 := Files.Status_Ok;
      Done   : Boolean := False;  --  forwarded: reply already sent
      Exp    : String (1 .. Max_Expanded);
      E_Len  : Natural;
   begin
      if Buf = 0 or else not Name_Of (0, 3, Name, Len) then
         Status := Files.Status_Bad_Args;
      else
         Resolve_Full (Name, Len, Exp, E_Len, V, Pos);
         if V = 0 then
            Status := Files.Status_Not_Found;
         elsif not Volumes (V).Is_FS then
            Status := Files.Status_Bad_Args;
         else
            --  Pack_Path touches words 0..3 only; the attr name
            --  in words 4..5 rides through to the fs driver.
            Pack_Path (Exp, Pos, E_Len, 0, 3);
            Syscalls.Message.Label := Files.Op_Attr_Read;
            Syscalls.Message.Caps := (0 => Buf, others => 0);
            if Forward_To_FS (V, Syscalls.Message.Badge) then
               --  Relay the fs driver's reply words untouched.
               Syscalls.Message.Caps := (others => 0);
               if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
                  Syscalls.Debug_Put_Line
                    ("fileserver attrread reply failed");
                  Syscalls.Process_Exit;
               end if;
               Done := True;
            else
               Status := Files.Status_Not_Found;
            end if;
         end if;
      end if;

      --  Every Op_Attr_Read transfers the client's buffer cap
      --  into this table; drop it or leak a slot per op.
      if Buf /= 0
        and then Syscalls.Cap_Delete (Buf) /= 0
      then
         Akernel_User.Console.Put_Line
           ("fileserver: attr buffer cap delete failed");
      end if;
      if not Done then
         Reply2 (Status, 0);
      end if;
   end Handle_Attr_Read;

   --  Op_Query (milestone 82f): words 0..3 = volume-qualified
   --  path (only the volume prefix matters — queries are
   --  volume-wide), word 4 = match index, cap slot 0 = the
   --  client's buffer holding the NUL-terminated predicate,
   --  forwarded like Op_Attr_Read. The reply rides through
   --  unchanged: w0 = status, w1 = size, w2 = is_dir, words 3..5
   --  = volume-relative path. Volumes without query support
   --  answer Bad_Args.
   procedure Handle_Query is
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      Name   : String (1 .. 32);
      Len    : Natural;
      Pos    : Natural;
      V      : Natural;
      Status : U64 := Files.Status_Ok;
      Done   : Boolean := False;  --  forwarded: reply already sent
      Exp    : String (1 .. Max_Expanded);
      E_Len  : Natural;
   begin
      if Buf = 0 or else not Name_Of (0, 3, Name, Len) then
         Status := Files.Status_Bad_Args;
      else
         Resolve_Full (Name, Len, Exp, E_Len, V, Pos);
         if V = 0 then
            Status := Files.Status_Not_Found;
         elsif not Volumes (V).Is_FS then
            Status := Files.Status_Bad_Args;
         else
            --  Pack_Path touches words 0..3 only; the match
            --  index in word 4 rides through to the fs driver.
            Pack_Path (Exp, Pos, E_Len, 0, 3);
            Syscalls.Message.Label := Files.Op_Query;
            Syscalls.Message.Caps := (0 => Buf, others => 0);
            if Forward_To_FS (V, Syscalls.Message.Badge) then
               --  Relay the fs driver's reply words untouched.
               Syscalls.Message.Caps := (others => 0);
               if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
                  Syscalls.Debug_Put_Line
                    ("fileserver query reply failed");
                  Syscalls.Process_Exit;
               end if;
               Done := True;
            else
               Status := Files.Status_Not_Found;
            end if;
         end if;
      end if;

      --  Every Op_Query transfers the client's buffer cap into
      --  this table; drop it or leak a slot per op.
      if Buf /= 0
        and then Syscalls.Cap_Delete (Buf) /= 0
      then
         Akernel_User.Console.Put_Line
           ("fileserver: query buffer cap delete failed");
      end if;
      if not Done then
         Reply2 (Status, 0);
      end if;
   end Handle_Query;

   procedure Handle_Stat_Or_Open is
      Name : String (1 .. 48);
      Len  : Natural;
      Pos  : Natural;
      V    : Natural;
      I    : Natural;
      Exp  : String (1 .. Max_Expanded);
      E_Len : Natural;
   begin
      if not Name_Of (0, 5, Name, Len) then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      --  Milestone 59: words 2/3 carry FAT write date/time from
      --  fs drivers (forwarded untouched by the VFS branch); every
      --  local reply must zero them or the request's packed path
      --  leaks through as a garbage stamp.  Milestone 64: word 4
      --  is the is-dir flag — same hygiene.
      Syscalls.Message.Words (2) := 0;
      Syscalls.Message.Words (3) := 0;
      Syscalls.Message.Words (4) := 0;

      Resolve_Full (Name, Len, Exp, E_Len, V, Pos);
      if V = 0 then
         Reply2 (Files.Status_Not_Found, 0);
         return;
      end if;

      if Volumes (V).Is_Nil then
         --  NIL: everything stats/opens as a zero-byte sink.
         Reply2 (Files.Status_Ok, 0);
         return;
      end if;

      if Volumes (V).Is_Pipe then
         --  PIPE:name: Open attaches (creating the pipe on
         --  first use, Amiga-style); Stat never creates.
         declare
            P : Natural := 0;
         begin
            if E_Len < Pos then
               Reply2 (Files.Status_Bad_Args, 0);  --  bare PIPE:
               return;
            end if;
            P := Fileserver_Pipes.Find (Exp (Pos .. E_Len));
            if Syscalls.Message.Label = Files.Op_Open then
               if P = 0 then
                  P := Fileserver_Pipes.Find_Or_Create
                    (Exp (Pos .. E_Len));
                  if P = 0 then
                     --  Table full: poll-and-retry like every
                     --  pipe backpressure answer.
                     Reply2 (Files.Status_Not_Ready, 0);
                     return;
                  end if;
               end if;
               Reply2 (Files.Status_Ok, 0);
            else
               if P = 0 then
                  Reply2 (Files.Status_Not_Found, 0);
               else
                  Reply2 (Files.Status_Ok,
                          Fileserver_Pipes.Buffered (P));
               end if;
            end if;
         end;
         return;
      end if;

      if Volumes (V).Is_FS then
         --  VFS forwarding: the fs driver speaks the same client
         --  protocol; the path portion rides words 0..5. The
         --  caller identity is delivered through the minted cap
         --  badge (Forward_To_FS preserves Message contents).
         Pack_Path (Exp, Pos, E_Len, 0);
         Syscalls.Message.Caps := (others => 0);
         if Forward_To_FS (V, Syscalls.Message.Badge) then
            Reply2 (Syscalls.Message.Words (0),
                    Syscalls.Message.Words (1));
         else
            Reply2 (Files.Status_Not_Found, 0);
         end if;
         return;
      end if;

      if Volumes (V).Is_Block then
         --  Block volumes expose the raw device as "disk".
         if Match ("disk", 4, Exp (Pos .. E_Len),
                   Volumes (V).Case_Insensitive)
         then
            Reply2 (Files.Status_Ok, Volumes (V).Blk_Size);
         else
            Reply2 (Files.Status_Not_Found, 0);
         end if;
         return;
      end if;

      I := Find (Exp (Pos .. E_Len), V);
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

   procedure Unmap_Buf is
   begin
      if Syscalls.Mem_Unmap
        (Address_Space => Syscalls.Address_Space_Cap,
         VA            => Buf_Win_VA,
         Length        => Buf_Bytes) /= 0
      then
         Akernel_User.Console.Put_Line
           ("fileserver: buffer unmap failed");
      end if;
   end Unmap_Buf;

   --  Blocking pipes (milestone 49): complete deferred requests
   --  for pipe P after the ring changed. Passes run until no
   --  progress — a completing read frees space for a pending
   --  write and a completing write feeds a pending read. Each
   --  completion maps the STASHED client buffer, copies, replies
   --  through the stashed reply cap and drops both caps. The
   --  caller must hold NO Buf_Win_VA mapping (drain remaps it).
   --  Message.Words(0..1) are scratch here: every op extracts
   --  its parameters before mutating the ring, and the current
   --  request's own reply words are written after this returns.
   procedure Drain_Pipe (P : Natural) is
      use Fileserver_Pipes;
      Progress : Boolean;
      B        : Byte;
   begin
      loop
         Progress := False;
         for S in 1 .. Max_Pending loop
            if Pend_Kind (S) /= P_None
              and then Pend_Pipe (S) = P
            then
               if Pend_Kind (S) = P_Read
                 and then (Buffered (P) > 0 or else Is_EOF (P))
               then
                  declare
                     Count : U64 :=
                       U64'Min (Pend_Length (S), Buffered (P));
                     St    : U64 := Files.Status_Ok;
                  begin
                     Count := U64'Min (Count, Buf_Bytes);
                     if Count > 0 then
                        if not Map_Buf (Pend_Buf (S)) then
                           St := Files.Status_Not_Found;
                           Count := 0;
                        else
                           declare
                              Win : Byte_Array (0 .. Count - 1)
                                with Address => To_Address
                                  (Integer_Address (Buf_Win_VA));
                           begin
                              for J in Win'Range loop
                                 if not Pop (P, B) then
                                    Count := J;
                                    exit;
                                 end if;
                                 Win (J) := B;
                              end loop;
                           end;
                           Unmap_Buf;
                        end if;
                     end if;
                     Syscalls.Message.Words (0) := St;
                     Syscalls.Message.Words (1) := Count;
                     --  m75: deferred reply on a stored handle —
                     --  Message.Caps belongs to a LATER request;
                     --  clear it before it transfers cross-request.
                     Syscalls.Message.Caps := (others => 0);
                     if Syscalls.IPC_Reply (Pend_Reply (S))
                       /= Syscalls.IPC_Ok
                     then
                        Akernel_User.Console.Put_Line
                          ("fileserver: pipe drain reply failed");
                     end if;
                  end;
                  if Syscalls.Cap_Delete (Pend_Buf (S)) /= 0 then
                     Akernel_User.Console.Put_Line
                       ("fileserver: pipe drain buf drop failed");
                  end if;
                  Pend_Clear (S);
                  Progress := True;
               elsif Pend_Kind (S) = P_Write
                 and then Space_Left (P) >= Pend_Length (S)
               then
                  declare
                     St : U64 := Files.Status_Ok;
                  begin
                     if not Map_Buf (Pend_Buf (S)) then
                        St := Files.Status_Not_Found;
                     else
                        declare
                           Win : Byte_Array
                             (0 .. Pend_Length (S) - 1)
                             with Address => To_Address
                               (Integer_Address (Buf_Win_VA));
                        begin
                           for J in Win'Range loop
                              Push (P, Win (J));
                           end loop;
                        end;
                        Unmap_Buf;
                     end if;
                     Syscalls.Message.Words (0) := St;
                     Syscalls.Message.Words (1) := Pend_Length (S);
                     --  m75: deferred reply — clear the current
                     --  request's caps (see the P_Read case above).
                     Syscalls.Message.Caps := (others => 0);
                     if Syscalls.IPC_Reply (Pend_Reply (S))
                       /= Syscalls.IPC_Ok
                     then
                        Akernel_User.Console.Put_Line
                          ("fileserver: pipe drain reply failed");
                     end if;
                  end;
                  if Syscalls.Cap_Delete (Pend_Buf (S)) /= 0 then
                     Akernel_User.Console.Put_Line
                       ("fileserver: pipe drain buf drop failed");
                  end if;
                  Pend_Clear (S);
                  Progress := True;
               end if;
            end if;
         end loop;
         exit when not Progress;
      end loop;
   end Drain_Pipe;

   --  Op_Delete on a pipe with deferred requests: wake them with
   --  Not_Found so their clients do not block forever (this is
   --  also the escape hatch for a writer whose reader died — the
   --  shell deletes its pool pipes after every pipeline).
   procedure Fail_Pipe_Pendings (P : Natural) is
      use Fileserver_Pipes;
   begin
      for S in 1 .. Max_Pending loop
         if Pend_Kind (S) /= P_None
           and then Pend_Pipe (S) = P
         then
            Syscalls.Message.Words (0) := Files.Status_Not_Found;
            Syscalls.Message.Words (1) := 0;
            --  m75: deferred reply — clear the current request's
            --  caps (see Drain_Pipe).
            Syscalls.Message.Caps := (others => 0);
            if Syscalls.IPC_Reply (Pend_Reply (S))
              /= Syscalls.IPC_Ok
            then
               Akernel_User.Console.Put_Line
                 ("fileserver: pipe fail reply failed");
            end if;
            if Syscalls.Cap_Delete (Pend_Buf (S)) /= 0 then
               Akernel_User.Console.Put_Line
                 ("fileserver: pipe fail buf drop failed");
            end if;
            Pend_Clear (S);
         end if;
      end loop;
   end Fail_Pipe_Pendings;

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
      Deferred : Boolean := False;  --  stashed pipe write (m49)
      Exp    : String (1 .. Max_Expanded);
      E_Len  : Natural;

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

         Resolve_Full (Name, Len, Exp, E_Len, V, Pos);
         if V = 0 then
            Status := Files.Status_Not_Found;
            return;
         end if;

         if Volumes (V).Is_FS then
            Syscalls.Message.Words (0) := Offset;
            Syscalls.Message.Words (1) := Length;
            Pack_Path (Exp, Pos, E_Len, 2);
            Syscalls.Message.Label := Files.Op_Write;
            Syscalls.Message.Caps := (0 => Buf, others => 0);
            if Forward_To_FS (V, Syscalls.Message.Badge) then
               Status := Syscalls.Message.Words (0);
               Count := Syscalls.Message.Words (1);
            else
               Status := Files.Status_Not_Found;
            end if;
            return;
         end if;

         if Volumes (V).Is_Block then
            if not Match ("disk", 4, Exp (Pos .. E_Len),
                          Volumes (V).Case_Insensitive)
            then
               Status := Files.Status_Not_Found;
               return;
            end if;

            Handle_Block_Write (V, Buf, Offset, Length,
                                Status, Count, Mapped);
            return;
         end if;

         if Volumes (V).Is_Nil then
            --  NIL: writes are discarded and always succeed.
            Status := Files.Status_Ok;
            Count := Length;
            return;
         end if;

         if Volumes (V).Is_Pipe then
            --  PIPE: writes append all-or-nothing (creating the
            --  pipe on first use like Open). A ring without room
            --  BLOCKS (milestone 49): reply + buffer caps stashed
            --  until a reader pops. Table full falls back to
            --  Not_Ready (client poll loop degrades gracefully).
            declare
               P : Natural := 0;
            begin
               if E_Len < Pos
                 or else Length > Fileserver_Pipes.Pipe_Bytes
               then
                  Status := Files.Status_Bad_Args;
                  return;
               end if;
               P := Fileserver_Pipes.Find_Or_Create
                 (Exp (Pos .. E_Len));
               if P = 0 then
                  Status := Files.Status_Not_Ready;
                  return;
               end if;
               if Fileserver_Pipes.Space_Left (P) < Length then
                  if Fileserver_Pipes.Stash
                    (P, Fileserver_Pipes.P_Write,
                     Reply_H, Buf, Length)
                  then
                     Deferred := True;
                  else
                     Status := Files.Status_Not_Ready;
                  end if;
                  return;
               end if;
               if not Map_Buf (Buf) then
                  Status := Files.Status_Not_Found;
                  return;
               end if;
               Mapped := True;
               declare
                  Win : Byte_Array (0 .. Length - 1)
                    with Address => To_Address
                      (Integer_Address (Buf_Win_VA));
               begin
                  for J in Win'Range loop
                     Fileserver_Pipes.Push (P, Win (J));
                  end loop;
               end;
               --  Drain AFTER releasing the window (drain maps
               --  stashed buffers through the same VA).
               Mapped := False;
               Unmap_Buf;
               Status := Files.Status_Ok;
               Count := Length;
               Drain_Pipe (P);
            end;
            return;
         end if;

         Status := Files.Status_Bad_Args;  --  boot files read-only
      end Process;
   begin
      Process;

      --  A deferred pipe request owns its reply cap and buffer
      --  cap in the pending table: no unmap, no delete, no reply
      --  from this handler.
      if Deferred then
         return;
      end if;

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
      Deferred : Boolean := False;  --  stashed pipe read (m49)
      Ok     : Boolean;
      Exp    : String (1 .. Max_Expanded);
      E_Len  : Natural;

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

         Resolve_Full (Name, Len, Exp, E_Len, V, Pos);
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
            Pack_Path (Exp, Pos, E_Len, 2);
            Syscalls.Message.Label := Files.Op_Read;
            Syscalls.Message.Caps := (0 => Buf, others => 0);
            if Forward_To_FS (V, Syscalls.Message.Badge) then
               Status := Syscalls.Message.Words (0);
               Count := Syscalls.Message.Words (1);
            else
               Status := Files.Status_Not_Found;
            end if;
            return;
         end if;

         if Volumes (V).Is_Block then
            if not Match ("disk", 4, Exp (Pos .. E_Len),
                          Volumes (V).Case_Insensitive)
            then
               Status := Files.Status_Not_Found;
               return;
            end if;

            Handle_Block_Read (V, Buf, Offset, Length,
                               Status, Count, Mapped);
            return;
         end if;

         if Volumes (V).Is_Nil then
            --  NIL: reads answer immediate EOF.
            Status := Files.Status_Ok;
            Count := 0;
            return;
         end if;

         if Volumes (V).Is_Pipe then
            --  PIPE: reads pop from the ring. An empty non-EOF
            --  ring BLOCKS (milestone 49): the request's reply
            --  cap and buffer cap are stashed and the reply is
            --  deferred until a writer pushes or closes. Table
            --  full falls back to Not_Ready (the client's poll
            --  loop degrades gracefully). Ok+0 once EOF.
            declare
               P : constant Natural :=
                 Fileserver_Pipes.Find (Exp (Pos .. E_Len));
               B : Byte;
            begin
               if P = 0 then
                  Status := Files.Status_Not_Found;
                  return;
               end if;
               if Fileserver_Pipes.Buffered (P) = 0 then
                  if Fileserver_Pipes.Is_EOF (P) then
                     Status := Files.Status_Ok;
                     Count := 0;
                  elsif Fileserver_Pipes.Stash
                    (P, Fileserver_Pipes.P_Read,
                     Reply_H, Buf, Length)
                  then
                     Deferred := True;
                  else
                     Status := Files.Status_Not_Ready;
                  end if;
                  return;
               end if;
               Count := U64'Min (Length,
                                 Fileserver_Pipes.Buffered (P));
               Count := U64'Min (Count, Buf_Bytes);
               if not Map_Buf (Buf) then
                  Status := Files.Status_Not_Found;
                  Count := 0;
                  return;
               end if;
               Mapped := True;
               declare
                  Win : Byte_Array (0 .. Count - 1)
                    with Address => To_Address
                      (Integer_Address (Buf_Win_VA));
               begin
                  for J in Win'Range loop
                     if not Fileserver_Pipes.Pop (P, B) then
                        Count := J;  --  cannot happen (bounded)
                        exit;
                     end if;
                     Win (J) := B;
                  end loop;
               end;
               --  Drain AFTER releasing the window (drain maps
               --  stashed buffers through the same VA).
               Mapped := False;
               Unmap_Buf;
               Status := Files.Status_Ok;
               Drain_Pipe (P);
            end;
            return;
         end if;

         I := Find (Exp (Pos .. E_Len), V);
         if I = 0 then
            Status := Files.Status_Not_Found;
            return;
         end if;

         if Offset >= File_Table (I).Size then
            Status := Files.Status_Out_Of_Range;
            return;
         end if;

         Ensure_Lead_In (I, Ok);
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

         --  Chunked pass through the shared window: map the pages
         --  covering the next up-to-256 KiB of file data, copy
         --  into the client buffer window, unmap. One iteration
         --  for any read that fits the window (today always:
         --  client buffers cap at 32 KiB); files larger than the
         --  window just take more passes.
         declare
            F : File_Entry renames File_Table (I);
            File_Pages : constant U64 :=
              (F.Lead_In + F.Size + Syscalls.Page_Size - 1)
                / Syscalls.Page_Size;
            Done      : U64 := 0;
            Pos       : U64 := Offset;
            Left      : U64 := Count;
            Dummy_LI  : U64;
         begin
            while Left > 0 loop
               declare
                  Page_Base : constant U64 :=
                    (F.Lead_In + Pos) / Syscalls.Page_Size;
                  Span : constant U64 :=
                    U64'Min (File_Win_Pages, File_Pages - Page_Base);
                  Skip : constant U64 :=
                    (F.Lead_In + Pos) mod Syscalls.Page_Size;
                  Chunk : constant U64 :=
                    U64'Min (Left, Span * Syscalls.Page_Size - Skip);
               begin
                  if Syscalls.Mem_Map_File
                    (Address_Space => Syscalls.Address_Space_Cap,
                     Cap           => F.Handle,
                     VA            => File_Win_VA,
                     Offset        => Page_Base * Syscalls.Page_Size,
                     Length        => Span * Syscalls.Page_Size,
                     Lead_In       => Dummy_LI) /= 0
                  then
                     Status := Files.Status_Not_Found;
                     Count := 0;
                     exit;
                  end if;

                  declare
                     Src : Byte_Array (0 .. Chunk - 1)
                       with Address => To_Address (Integer_Address
                         (File_Win_VA + Skip));
                     Dst : Byte_Array (0 .. Chunk - 1)
                       with Address => To_Address (Integer_Address
                         (Buf_Win_VA + Done));
                  begin
                     --  Byte loop, not Dst := Src: the variable-
                     --  size array assignment made GNAT spill a
                     --  ~40 KiB temp into the main frame and blow
                     --  the 16 KiB mapped stack (38b burn).
                     for B in 0 .. Chunk - 1 loop
                        Dst (B) := Src (B);
                     end loop;
                  end;

                  if Syscalls.Mem_Unmap
                    (Address_Space => Syscalls.Address_Space_Cap,
                     VA            => File_Win_VA,
                     Length        => Span * Syscalls.Page_Size) /= 0
                  then
                     Akernel_User.Console.Put_Line
                       ("fileserver: window unmap failed");
                     Status := Files.Status_Not_Found;
                     Count := 0;
                     exit;
                  end if;

                  Done := Done + Chunk;
                  Pos := Pos + Chunk;
                  Left := Left - Chunk;
               end;
            end loop;
         end;
      end Process;
   begin
      Process;

      --  A deferred pipe request owns its reply cap and buffer
      --  cap in the pending table: no unmap, no delete, no reply
      --  from this handler.
      if Deferred then
         return;
      end if;

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
      Exp  : String (1 .. Max_Expanded);
      E_Len : Natural;
   begin
      if not Names_Done then
         Reply2 (Files.Status_Not_Ready, 0);
         return;
      end if;

      if not Name_Of (0, 5, Name, Len) then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      --  Milestone 59: words 2/3 carry FAT write date/time from
      --  fs drivers (forwarded untouched by the VFS branch); every
      --  local reply must zero them or the request's packed path
      --  leaks through as a garbage stamp.
      Syscalls.Message.Words (2) := 0;
      Syscalls.Message.Words (3) := 0;

      Resolve_Full (Name, Len, Exp, E_Len, V, Pos);
      if V = 0 then
         Reply2 (Files.Status_Not_Found, 0);
         return;
      end if;

      if Volumes (V).Is_Nil then
         --  NIL: swallows deletes/truncates; it has no
         --  directories to make or remove.
         if Op = Files.Op_Delete or else Op = Files.Op_Truncate then
            Reply2 (Files.Status_Ok, 0);
         else
            Reply2 (Files.Status_Bad_Args, 0);
         end if;
         return;
      end if;

      if Volumes (V).Is_Pipe then
         declare
            P : constant Natural :=
              Fileserver_Pipes.Find (Exp (Pos .. E_Len));
         begin
            if Op = Files.Op_Delete then
               if P = 0 then
                  Reply2 (Files.Status_Not_Found, 0);
               else
                  --  Deferred requests on the dying pipe wake
                  --  Not_Found (the dead-reader escape hatch).
                  Fail_Pipe_Pendings (P);
                  Fileserver_Pipes.Destroy (P);
                  Reply2 (Files.Status_Ok, 0);
               end if;
            elsif Op = Files.Op_Truncate then
               --  Truncate = reset for reuse (empties the ring
               --  and clears a stale EOF).
               if P = 0 then
                  Reply2 (Files.Status_Not_Found, 0);
               else
                  Fileserver_Pipes.Reset (P);
                  --  A reset ring has full space: deferred
                  --  writers can complete (milestone 49).
                  Drain_Pipe (P);
                  Reply2 (Files.Status_Ok, 0);
               end if;
            else
               Reply2 (Files.Status_Bad_Args, 0);
            end if;
         end;
         return;
      end if;

      if Volumes (V).Is_FS then
         Pack_Path (Exp, Pos, E_Len, 0);
         Syscalls.Message.Label := Op;
         Syscalls.Message.Caps := (others => 0);
         if Forward_To_FS (V, Syscalls.Message.Badge) then
            Reply2 (Syscalls.Message.Words (0),
                    Syscalls.Message.Words (1));
         else
            Reply2 (Files.Status_Not_Found, 0);
         end if;
         return;
      end if;

      Reply2 (Files.Status_Bad_Args, 0);
   end Handle_Path_Op;

   --  Op_Rename (milestone 41): FROM path rides words 0..5 like a
   --  path op; the TO path arrives NUL-terminated in the client
   --  buffer (cap slot 0). Both volumes must resolve to the same
   --  fs-driver volume; the buffer is rewritten with the volume-
   --  stripped TO path and forwarded verbatim.
   procedure Handle_Rename is
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      Name   : String (1 .. 48);
      Len    : Natural;
      To     : String (1 .. 48);
      To_Len : Natural := 0;
      Pos    : Natural;
      V      : Natural;
      Pos2   : Natural;
      V2     : Natural;
      Exp    : String (1 .. Max_Expanded);
      E_Len  : Natural;
      Exp2   : String (1 .. Max_Expanded);
      E_Len2 : Natural;
      Status : U64 := Files.Status_Ok;
      Mapped : Boolean := False;
      Win    : Byte_Array (0 .. 47)
        with Address => System.Storage_Elements.To_Address
          (System.Storage_Elements.Integer_Address (Buf_Win_VA));

      procedure Process is
      begin
         if not Names_Done then
            Status := Files.Status_Not_Ready;
            return;
         end if;

         if Buf = 0 or else not Name_Of (0, 5, Name, Len) then
            Status := Files.Status_Bad_Args;
            return;
         end if;

         Resolve_Full (Name, Len, Exp, E_Len, V, Pos);
         if V = 0 then
            Status := Files.Status_Not_Found;
            return;
         end if;
         if not Volumes (V).Is_FS then
            Status := Files.Status_Bad_Args;
            return;
         end if;

         if not Map_Buf (Buf) then
            Status := Files.Status_Not_Found;
            return;
         end if;
         Mapped := True;

         for I in U64 (0) .. 47 loop
            exit when Win (I) = 0;
            To_Len := To_Len + 1;
            To (To_Len) := Character'Val (Natural (Win (I)));
         end loop;
         if To_Len = 0 then
            Status := Files.Status_Bad_Args;
            return;
         end if;

         Resolve_Full (To, To_Len, Exp2, E_Len2, V2, Pos2);
         if V2 = 0 then
            Status := Files.Status_Not_Found;
            return;
         end if;
         if V2 /= V then
            Status := Files.Status_Bad_Args;  --  cross-volume
            return;
         end if;

         --  Rewrite the buffer with the bare TO path (NUL-padded
         --  through 48 bytes) for the fs driver.
         for I in U64 (0) .. 47 loop
            Win (I) :=
              (if I < U64 (E_Len2 - Pos2 + 1)
               then Byte (Character'Pos (Exp2 (Pos2 + Natural (I))))
               else 0);
         end loop;

         if Syscalls.Mem_Unmap
           (Address_Space => Syscalls.Address_Space_Cap,
            VA            => Buf_Win_VA,
            Length        => Buf_Bytes) /= 0
         then
            Akernel_User.Console.Put_Line
              ("fileserver: buffer unmap failed");
         end if;
         Mapped := False;

         Pack_Path (Exp, Pos, E_Len, 0);
         Syscalls.Message.Label := Files.Op_Rename;
         Syscalls.Message.Caps := (0 => Buf, others => 0);
         if Forward_To_FS (V, Syscalls.Message.Badge) then
            Status := Syscalls.Message.Words (0);
         else
            Status := Files.Status_Not_Found;
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
              ("fileserver: buffer unmap failed");
         end if;
         if Syscalls.Cap_Delete (Buf) /= 0 then
            Akernel_User.Console.Put_Line
              ("fileserver: buffer cap delete failed");
         end if;
      end if;

      Reply2 (Status, 0);
   end Handle_Rename;

   --  Op_Volume_Info (milestone 41): any volume-qualified path
   --  picks the volume; fs-driver volumes relay (status, total,
   --  free, cluster), everything else answers Bad_Args.
   procedure Handle_Volume_Info is
      Name : String (1 .. 48);
      Len  : Natural;
      Pos  : Natural;
      V    : Natural;
      Exp  : String (1 .. Max_Expanded);
      E_Len : Natural;
   begin
      if not Names_Done then
         Reply2 (Files.Status_Not_Ready, 0);
         return;
      end if;

      if not Name_Of (0, 5, Name, Len) then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      --  Milestone 59: words 2/3 carry FAT write date/time from
      --  fs drivers (forwarded untouched by the VFS branch); every
      --  local reply must zero them or the request's packed path
      --  leaks through as a garbage stamp.
      Syscalls.Message.Words (2) := 0;
      Syscalls.Message.Words (3) := 0;

      Resolve_Full (Name, Len, Exp, E_Len, V, Pos);
      if V = 0 then
         Reply2 (Files.Status_Not_Found, 0);
         return;
      end if;

      if Volumes (V).Is_FS then
         Pack_Path (Exp, Pos, E_Len, 0);
         Syscalls.Message.Label := Files.Op_Volume_Info;
         Syscalls.Message.Caps := (others => 0);
         if Forward_To_FS (V, Syscalls.Message.Badge)
           and then Syscalls.Message.Words (0) = Files.Status_Ok
         then
            Syscalls.Message.Caps := (others => 0);
            if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
               Akernel_User.Console.Put_Line
                 ("fileserver: reply failed");
            end if;
            return;
         end if;
         Reply2 (Files.Status_Not_Found, 0);
         return;
      end if;

      Reply2 (Files.Status_Bad_Args, 0);
   end Handle_Volume_Info;

   --  Seed the server-internal virtual volumes (milestone
   --  46a): PIPE: (named FIFO rings, Fileserver_Pipes) and
   --  NIL: (sink). They are never mounted by init; the file
   --  server owns them outright. Names resolve like any
   --  device/label prefix, always case-insensitively.
   procedure Seed_Virtual_Volumes is
   begin
      for V in Volumes'Range loop
         if not Volumes (V).Valid then
            Volumes (V).Valid := True;
            Volumes (V).Device := (others => Character'Val (0));
            Volumes (V).Device (1 .. 4) := "PIPE";
            Volumes (V).Dev_Len := 4;
            Volumes (V).Label := Volumes (V).Device;
            Volumes (V).Lab_Len := 4;
            Volumes (V).Case_Insensitive := True;
            Volumes (V).Is_Pipe := True;
            exit;
         end if;
      end loop;
      for V in Volumes'Range loop
         if not Volumes (V).Valid then
            Volumes (V).Valid := True;
            Volumes (V).Device := (others => Character'Val (0));
            Volumes (V).Device (1 .. 3) := "NIL";
            Volumes (V).Dev_Len := 3;
            Volumes (V).Label := Volumes (V).Device;
            Volumes (V).Lab_Len := 3;
            Volumes (V).Case_Insensitive := True;
            Volumes (V).Is_Nil := True;
            exit;
         end if;
      end loop;
   end Seed_Virtual_Volumes;

   --  Op_Close (milestone 46a): PIPE: name -> writer EOF; any
   --  other volume -> no-op Ok (regular files are write-
   --  through, close = flush = nothing; keeps the wire
   --  fid-less: Close names the path, not a handle).
   procedure Handle_Close is
      Name : String (1 .. 48);
      Len  : Natural;
      Pos  : Natural;
      V    : Natural;
      P    : Natural;
      Exp  : String (1 .. Max_Expanded);
      E_Len : Natural;
   begin
      if not Name_Of (0, 5, Name, Len) then
         Reply2 (Files.Status_Bad_Args, 0);
         return;
      end if;

      --  Milestone 59: words 2/3 carry FAT write date/time from
      --  fs drivers (forwarded untouched by the VFS branch); every
      --  local reply must zero them or the request's packed path
      --  leaks through as a garbage stamp.
      Syscalls.Message.Words (2) := 0;
      Syscalls.Message.Words (3) := 0;

      Resolve_Full (Name, Len, Exp, E_Len, V, Pos);
      if V = 0 then
         Reply2 (Files.Status_Not_Found, 0);
         return;
      end if;

      if Volumes (V).Is_Pipe then
         P := Fileserver_Pipes.Find (Exp (Pos .. E_Len));
         if P = 0 then
            Reply2 (Files.Status_Not_Found, 0);
         else
            Fileserver_Pipes.Set_EOF (P);
            --  Wake deferred readers: they drain the ring or
            --  see Ok+0 (milestone 49).
            Drain_Pipe (P);
            Reply2 (Files.Status_Ok, 0);
         end if;
         return;
      end if;

      Reply2 (Files.Status_Ok, 0);
   end Handle_Close;

begin
   Akernel_User.Console.Set_Endpoint (2);  --  console grant
   Akernel_User.Console.Put_Line ("fileserver online");
   Seed_Virtual_Volumes;

   loop
      if Syscalls.IPC_Recv (EP, Reply_H) /= Syscalls.IPC_Ok then
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
      elsif Syscalls.Message.Label = Files.Op_Assign then
         Handle_Assign;
      elsif Syscalls.Message.Label = Files.Op_Assign_List then
         Handle_Assign_List;
      elsif Syscalls.Message.Label = Files.Op_Sync then
         Handle_Sync;
      elsif Syscalls.Message.Label = Files.Op_Rename then
         Handle_Rename;
      elsif Syscalls.Message.Label = Files.Op_Volume_Info then
         Handle_Volume_Info;
      elsif Syscalls.Message.Label = Files.Op_Close then
         Handle_Close;
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
      elsif Syscalls.Message.Label = Files.Op_ReadDir then
         if not Names_Done then
            Reply2 (Files.Status_Not_Ready, 0);
         else
            Handle_Read_Dir;
         end if;
      elsif Syscalls.Message.Label = Files.Op_Attr_List then
         if not Names_Done then
            Reply2 (Files.Status_Not_Ready, 0);
         else
            Handle_Attr_List;
         end if;
      elsif Syscalls.Message.Label = Files.Op_Attr_Read then
         if not Names_Done then
            Reply2 (Files.Status_Not_Ready, 0);
         else
            Handle_Attr_Read;
         end if;
      elsif Syscalls.Message.Label = Files.Op_Query then
         if not Names_Done then
            Reply2 (Files.Status_Not_Ready, 0);
         else
            Handle_Query;
         end if;
      else
         Reply2 (Files.Status_Bad_Args, 0);
      end if;
   end loop;

   loop
      Syscalls.Yield;
   end loop;
end Fileserver;
