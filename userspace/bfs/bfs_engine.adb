--  BeFS read-only engine body. Layout mirrors tools/mkbefs.py
--  (which writes the fixture) and tools/befs_dump.py (which reads
--  it back); field offsets are the Haiku BFS on-disk format:
--
--    superblock at byte 512 of the partition (second half of
--    block 0); block_run = int32 ag + u16 start + u16 len, mapped
--    by block = ag << ag_shift + start; inode = one block, magic
--    0x3BBE0AD9, bfs_inode header 232 bytes, data_stream at 72
--    (12 direct runs, max ranges, indirect runs, size at 208);
--    btree = header at stream offset 0, nodes of node_size bytes,
--    node header 28 bytes, keys then key lengths (8-aligned) then
--    int64 values.
--
--  Directory lookup is a leaf-chain scan from the leftmost leaf
--  (B+trees link their leaves via the right pointer), which is
--  correct for any tree shape; a keyed internal-node descent is
--  the obvious future optimization if a volume outgrows this.

with Akernel_User.Console;
with Interfaces;
with System.Storage_Elements;

package body Bfs_Engine is
   package Syscalls renames Akernel_User.Syscalls;
   use type Syscalls.U64;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use System.Storage_Elements;

   subtype U8  is Interfaces.Unsigned_8;
   subtype U16 is Interfaces.Unsigned_16;
   subtype U32 is Interfaces.Unsigned_32;

   Blk_Read : constant U64 := 1;

   SB_Magic1    : constant U32 := 16#4246_5331#;  --  'BFS1'
   SB_Magic2    : constant U32 := 16#DD12_1031#;
   SB_Magic3    : constant U32 := 16#15B6_830E#;
   SB_LE        : constant U32 := 16#4249_4745#;  --  'BIGE'
   Inode_Magic  : constant U32 := 16#3BBE_0AD9#;
   Btree_Magic  : constant U32 := 16#69F6_C2E8#;
   Inode_In_Use : constant U32 := 16#0000_0001#;
   Btree_Null   : constant U64 := 16#FFFF_FFFF_FFFF_FFFF#;

   S_IFMT  : constant U32 := 8#170000#;
   S_IFDIR : constant U32 := 8#040000#;

   Block_Size : constant U64 := 1024;  --  mount gate (fixture geometry)

   Status_Ok           : constant U64 := 0;
   Status_Not_Found    : constant U64 := 1;
   Status_Out_Of_Range : constant U64 := 4;

   type Byte_Array is array (U64 range <>) of U8;

   --  block_run: int32 ag, u16 start, u16 len
   type Block_Run is record
      AG     : U32;
      Start  : U16;
      Length : U16;
   end record;

   ------------------------------------------------------------------
   --  State
   ------------------------------------------------------------------

   Blk_EP    : U64 := 0;
   Buf_Cap   : U64 := 0;
   Buf_VA    : U64 := 16#5380_0000#;
   Is_Mounted : Boolean := False;

   AG_Shift     : U64 := 0;
   Num_Blocks   : U64 := 0;
   Used_Blocks  : U64 := 0;
   Root_Block   : U64 := 0;   --  root dir inode number (= block)
   Index_Block  : U64 := 0;   --  indices root inode

   --  Block cache: 16 read-only slots of one block each.
   Cache_Slots : constant := 16;
   Cache_Num   : array (0 .. Cache_Slots - 1) of U64 :=
     (others => U64'Last);
   Cache_Refs  : array (0 .. Cache_Slots - 1) of Natural :=
     (others => 0);
   Cache_Data  : array (0 .. Cache_Slots - 1,
                        0 .. Block_Size - 1) of U8;

   ------------------------------------------------------------------
   --  Little-endian readers over a cache slot
   ------------------------------------------------------------------

   function LE16 (Slot : Natural; Off : U64) return U16 is
     (U16 (Cache_Data (Slot, Off))
        or Interfaces.Shift_Left (U16 (Cache_Data (Slot, Off + 1)), 8));

   function LE32 (Slot : Natural; Off : U64) return U32 is
     (U32 (Cache_Data (Slot, Off))
        or Interfaces.Shift_Left (U32 (Cache_Data (Slot, Off + 1)), 8)
        or Interfaces.Shift_Left (U32 (Cache_Data (Slot, Off + 2)), 16)
        or Interfaces.Shift_Left (U32 (Cache_Data (Slot, Off + 3)), 24));

   function LE64 (Slot : Natural; Off : U64) return U64 is
     (U64 (LE32 (Slot, Off))
        or Interfaces.Shift_Left (U64 (LE32 (Slot, Off + 4)), 32));

   function Run_At (Slot : Natural; Off : U64) return Block_Run is
     ((AG     => LE32 (Slot, Off),
       Start  => LE16 (Slot, Off + 4),
       Length => LE16 (Slot, Off + 6)));

   function To_Block (R : Block_Run) return U64 is
     (Interfaces.Shift_Left (U64 (R.AG), Natural (AG_Shift))
        + U64 (R.Start));

   ------------------------------------------------------------------
   --  Block cache
   ------------------------------------------------------------------

   function Get_Block (Num : U64) return Natural is
      Free : Natural := Cache_Slots;
   begin
      for S in 0 .. Cache_Slots - 1 loop
         if Cache_Num (S) = Num and then Cache_Refs (S) > 0 then
            Cache_Refs (S) := Cache_Refs (S) + 1;
            return S;
         elsif Cache_Refs (S) = 0 and then Free = Cache_Slots then
            Free := S;
         end if;
      end loop;
      if Free = Cache_Slots then
         Fail : begin
            Akernel_User.Console.Put_Line ("bfs: block cache exhausted");
            loop
               null;
            end loop;
         end Fail;
      end if;
      --  One block = two sectors through the bounce buffer.
      Syscalls.Message.Label := Blk_Read;
      Syscalls.Message.Words (0) := Num * 2;
      Syscalls.Message.Words (1) := 2;
      Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);
      if Syscalls.IPC_Call (Blk_EP) /= Syscalls.IPC_Ok
        or else Syscalls.Message.Words (0) /= 0
      then
         Akernel_User.Console.Put_Line ("bfs: block read io error");
         return Cache_Slots;
      end if;
      declare
         Src : Byte_Array (0 .. Block_Size - 1)
           with Address => To_Address (Integer_Address (Buf_VA));
      begin
         for I in Src'Range loop
            Cache_Data (Free, I) := Src (I);
         end loop;
      end;
      Cache_Num (Free) := Num;
      Cache_Refs (Free) := 1;
      return Free;
   end Get_Block;

   procedure Put_Block (Slot : Natural) is
   begin
      if Slot < Cache_Slots and then Cache_Refs (Slot) > 0 then
         Cache_Refs (Slot) := Cache_Refs (Slot) - 1;
      end if;
   end Put_Block;

   ------------------------------------------------------------------
   --  Inode
   ------------------------------------------------------------------

   type Run_Array is array (0 .. 11) of Block_Run;

   type Inode_Info is record
      Block       : U64;   --  inode number
      Mode        : U32;
      Size        : U64;   --  data stream size in bytes
      Direct      : Run_Array;
      Max_Direct  : U64;
      Indirect    : Block_Run;
      Max_Indir   : U64;
      Double_Ind  : Block_Run;
      Max_Double  : U64;
   end record;

   function Read_Inode (Block : U64; Info : out Inode_Info)
                        return Boolean
   is
      Slot : constant Natural := Get_Block (Block);
   begin
      if Slot = Cache_Slots
        or else LE32 (Slot, 0) /= Inode_Magic
        or else (LE32 (Slot, 24) and Inode_In_Use) = 0
      then
         Put_Block (Slot);
         return False;
      end if;
      Info.Block := Block;
      Info.Mode := LE32 (Slot, 20);
      for I in Info.Direct'Range loop
         Info.Direct (I) := Run_At (Slot, 72 + U64 (I) * 8);
      end loop;
      Info.Max_Direct := LE64 (Slot, 168);
      Info.Indirect   := Run_At (Slot, 176);
      Info.Max_Indir  := LE64 (Slot, 184);
      Info.Double_Ind := Run_At (Slot, 192);
      Info.Max_Double := LE64 (Slot, 200);
      Info.Size       := LE64 (Slot, 208);
      Put_Block (Slot);
      return True;
   end Read_Inode;

   ------------------------------------------------------------------
   --  Data stream read (file contents AND btree streams)
   ------------------------------------------------------------------

   --  Copy one partial block: Skip bytes into block Block, up to
   --  Chunk bytes, to Buf + Done.
   function Copy_Part (Block : U64; Skip : U64; Chunk : U64;
                       Buf : System.Address; Done : U64) return Boolean
   is
      Slot : constant Natural := Get_Block (Block);
   begin
      if Slot = Cache_Slots then
         return False;
      end if;
      declare
         Dst : Byte_Array (0 .. Chunk - 1) with Address => Buf + Storage_Offset (Done);
      begin
         for I in 0 .. Chunk - 1 loop
            Dst (I) := Cache_Data (Slot, Skip + I);
         end loop;
      end;
      Put_Block (Slot);
      return True;
   end Copy_Part;

   --  Read Len stream bytes at Pos into Buf; returns bytes done.
   function Stream_Read (Info : Inode_Info; Pos : U64;
                         Buf : System.Address; Len : U64) return U64
   is
      Done    : U64 := 0;
      Covered : U64;
      P       : U64;
      In_Run  : U64;
      Chunk   : U64;
      Block   : U64;
      Found   : Boolean;
   begin
      while Done < Len loop
         P := Pos + Done;
         Found := False;

         --  Direct runs.
         Covered := 0;
         for R of Info.Direct loop
            exit when R.Length = 0;
            if P < Covered + U64 (R.Length) * Block_Size then
               In_Run := P - Covered;
               Chunk := U64'Min
                 (Len - Done, U64 (R.Length) * Block_Size - In_Run);
               Block := To_Block (R) + In_Run / Block_Size;
               while Chunk > 0 loop
                  declare
                     Skip : constant U64 := In_Run mod Block_Size;
                     Part : constant U64 :=
                       U64'Min (Chunk, Block_Size - Skip);
                  begin
                     if not Copy_Part (Block, Skip, Part, Buf, Done)
                     then
                        return Done;
                     end if;
                     Done := Done + Part;
                     Chunk := Chunk - Part;
                     In_Run := In_Run + Part;
                     Block := Block + 1;
                  end;
               end loop;
               Found := True;
               exit;
            end if;
            Covered := Covered + U64 (R.Length) * Block_Size;
         end loop;

         --  Indirect run: fixed-length runs (Indirect.Length) in a
         --  block_run array spanning the indirect blocks.
         if not Found
           and then Info.Max_Indir > 0
           and then Info.Indirect.Length > 0
           and then P < Info.Max_Indir
         then
            declare
               Run_Bytes : constant U64 :=
                 U64 (Info.Indirect.Length) * Block_Size;
               Rel       : constant U64 := P - Info.Max_Direct;
               Run_Idx   : constant U64 := Rel / Run_Bytes;
               Per_Block : constant U64 := Block_Size / 8;
               Ind_Slot  : constant Natural := Get_Block
                 (To_Block (Info.Indirect) + Run_Idx / Per_Block);
            begin
               if Ind_Slot = Cache_Slots then
                  return Done;
               end if;
               declare
                  R : constant Block_Run := Run_At
                    (Ind_Slot, (Run_Idx mod Per_Block) * 8);
               begin
                  Put_Block (Ind_Slot);
                  if R.Length = 0 then
                     return Done;
                  end if;
                  In_Run := Rel mod Run_Bytes;
                  Chunk := U64'Min (Len - Done, Run_Bytes - In_Run);
                  Block := To_Block (R) + In_Run / Block_Size;
                  while Chunk > 0 loop
                     declare
                        Skip : constant U64 := In_Run mod Block_Size;
                        Part : constant U64 :=
                          U64'Min (Chunk, Block_Size - Skip);
                     begin
                        if not Copy_Part (Block, Skip, Part, Buf, Done)
                        then
                           return Done;
                        end if;
                        Done := Done + Part;
                        Chunk := Chunk - Part;
                        In_Run := In_Run + Part;
                        Block := Block + 1;
                     end;
                  end loop;
                  Found := True;
               end;
            end;
         end if;

         --  Double-indirect: not needed at fixture scale; bail out
         --  cleanly rather than misread (M82e work).
         exit when not Found;
      end loop;
      return Done;
   end Stream_Read;

   ------------------------------------------------------------------
   --  B+tree iteration (leaf chain from the leftmost leaf)
   ------------------------------------------------------------------

   type Tree_It is record
      Stream   : Inode_Info;
      Node     : Byte_Array (0 .. Block_Size - 1);
      Key_Idx  : U64;
      Count    : U64;
      Key_Pos  : U64;   --  byte offset of current key in keys area
      Lens_Off : U64;   --  key_lengths area offset
      Vals_Off : U64;   --  values area offset
      Valid    : Boolean;
   end record;

   --  Load the btree node at stream offset Off into It.
   function Load_Node (It : in out Tree_It; Off : U64) return Boolean is
      Got : U64;
   begin
      Got := Stream_Read (It.Stream, Off,
                          It.Node (It.Node'First)'Address, Block_Size);
      if Got /= Block_Size then
         return False;
      end if;
      declare
         KLen : U64;
      begin
         It.Count := U64 (U16 (It.Node (24))
            + Interfaces.Shift_Left (U16 (It.Node (25)), 8));
         KLen := U64 (U16 (It.Node (26))
            + Interfaces.Shift_Left (U16 (It.Node (27)), 8));
         It.Lens_Off := (28 + KLen + 7) and not 7;
         It.Vals_Off := It.Lens_Off + 2 * It.Count;
      end;
      It.Key_Idx := 0;
      It.Key_Pos := 28;
      return True;
   end Load_Node;

   function It_LE64 (It : Tree_It; Off : U64) return U64 is
      V : U64 := 0;
   begin
      for I in 0 .. 7 loop
         V := V or Interfaces.Shift_Left
           (U64 (It.Node (Off + U64 (I))), 8 * I);
      end loop;
      return V;
   end It_LE64;

   function It_LE16 (It : Tree_It; Off : U64) return U64 is
     (U64 (It.Node (Off))
        + Interfaces.Shift_Left (U64 (It.Node (Off + 1)), 8));

   procedure Tree_Rewind (Dir : Inode_Info; It : in out Tree_It;
                          Ok : out Boolean)
   is
      Hdr : Byte_Array (0 .. Block_Size - 1);
      Got : U64;
      Off : U64;
   begin
      It.Stream := Dir;
      It.Valid := False;
      Ok := False;
      --  btree header at stream offset 0; root node pointer at 16.
      Got := Stream_Read (Dir, 0, Hdr (Hdr'First)'Address, Block_Size);
      if Got /= Block_Size then
         return;
      end if;
      declare
         Magic : U32 := 0;
      begin
         for I in 0 .. 3 loop
            Magic := Magic or Interfaces.Shift_Left
              (U32 (Hdr (U64 (I))), 8 * I);
         end loop;
         if Magic /= Btree_Magic then
            return;
         end if;
      end;
      Off := 0;
      for I in 0 .. 7 loop
         Off := Off or Interfaces.Shift_Left
           (U64 (Hdr (16 + U64 (I))), 8 * I);
      end loop;
      --  Descend to the leftmost leaf (overflow link -1 = leaf).
      loop
         if not Load_Node (It, Off) then
            return;
         end if;
         exit when It_LE64 (It, 16) = Btree_Null;
         Off := It_LE64 (It, It.Vals_Off);  --  first child
      end loop;
      It.Valid := True;
      Ok := True;
   end Tree_Rewind;

   --  Next entry: key into Name (up to Name'Length), value = inode
   --  block. False at end of the leaf chain.
   function Tree_Next (It : in out Tree_It; Name : out String;
                       Name_Len : out Natural; Inode_Block : out U64)
                       return Boolean
   is
      KLen : U64;
   begin
      Name_Len := 0;
      if not It.Valid then
         return False;
      end if;
      if It.Key_Idx >= It.Count then
         --  Follow the right link.
         declare
            Right : constant U64 := It_LE64 (It, 8);
         begin
            if Right = Btree_Null then
               return False;
            end if;
            if not Load_Node (It, Right) then
               return False;
            end if;
         end;
      end if;
      KLen := It_LE16 (It, It.Lens_Off + 2 * It.Key_Idx);
      Inode_Block := It_LE64 (It, It.Vals_Off + 8 * It.Key_Idx);
      for I in 0 .. KLen - 1 loop
         if I < U64 (Name'Length) then
            Name (Name'First + Natural (I)) :=
              Character'Val (Natural (It.Node (It.Key_Pos + I)));
         end if;
      end loop;
      Name_Len := Natural (U64'Min (KLen, U64 (Name'Length)));
      It.Key_Pos := It.Key_Pos + KLen;
      It.Key_Idx := It.Key_Idx + 1;
      return True;
   end Tree_Next;

   ------------------------------------------------------------------
   --  Path lookup
   ------------------------------------------------------------------

   function Lookup (Path : String; Info : out Inode_Info;
                    Is_Root : out Boolean) return Boolean
   is
      Cur     : Inode_Info;
      It      : Tree_It;
      Name    : String (1 .. 32);
      Name_Ln : Natural;
      Block   : U64;
      Ok      : Boolean;
      Pos     : Natural;
      Last    : Natural;
      Found   : Boolean;
   begin
      Is_Root := Path'Length = 0;
      if Is_Root then
         return Read_Inode (Root_Block, Info);
      end if;
      if not Read_Inode (Root_Block, Cur) then
         return False;
      end if;

      Pos := Path'First;
      while Pos <= Path'Last loop
         Last := Pos;
         while Last <= Path'Last and then Path (Last) /= '/' loop
            Last := Last + 1;
         end loop;
         --  Component is Path (Pos .. Last - 1).
         Tree_Rewind (Cur, It, Ok);
         if not Ok then
            return False;
         end if;
         Found := False;
         while Tree_Next (It, Name, Name_Ln, Block) loop
            if Name_Ln = Last - Pos
              and then Name (1 .. Name_Ln) = Path (Pos .. Last - 1)
            then
               Found := True;
               exit;
            end if;
         end loop;
         if not Found or else not Read_Inode (Block, Cur) then
            return False;
         end if;
         Pos := Last + 1;
      end loop;
      Info := Cur;
      return True;
   end Lookup;

   ------------------------------------------------------------------
   --  Engine API
   ------------------------------------------------------------------

   procedure Init (Blk_EP : U64; Buf_Cap : U64) is
   begin
      Bfs_Engine.Blk_EP := Blk_EP;
      Bfs_Engine.Buf_Cap := Buf_Cap;

      --  Superblock: byte 512 = second half of block 0.
      declare
         Slot : constant Natural := Get_Block (0);
      begin
         if Slot = Cache_Slots then
            return;
         end if;
         Is_Mounted :=
           LE32 (Slot, 512 + 32) = SB_Magic1
           and then LE32 (Slot, 512 + 36) = SB_LE
           and then LE32 (Slot, 512 + 68) = SB_Magic2
           and then LE32 (Slot, 512 + 112) = SB_Magic3
           and then U64 (LE32 (Slot, 512 + 40)) = Block_Size
           --  Empty journal: read-only cannot replay.
           and then LE64 (Slot, 512 + 96) = LE64 (Slot, 512 + 104);
         if Is_Mounted then
            AG_Shift    := U64 (LE32 (Slot, 512 + 76));
            Num_Blocks  := LE64 (Slot, 512 + 48);
            Used_Blocks := LE64 (Slot, 512 + 56);
            Root_Block  := To_Block (Run_At (Slot, 512 + 116));
            Index_Block := To_Block (Run_At (Slot, 512 + 124));
         end if;
         Put_Block (Slot);
      end;

      if Is_Mounted then
         declare
            Root : Inode_Info;
         begin
            Is_Mounted := Read_Inode (Root_Block, Root);
         end;
      end if;
   end Init;

   function Mounted return Boolean is
   begin
      return Is_Mounted;
   end Mounted;

   function Stat (Path : String; Size : out U64; Is_Dir : out Boolean)
                  return U64
   is
      Info : Inode_Info;
      Root : Boolean;
   begin
      Size := 0;
      Is_Dir := False;
      if not Is_Mounted or else not Lookup (Path, Info, Root) then
         return Status_Not_Found;
      end if;
      Is_Dir := (Info.Mode and S_IFMT) = S_IFDIR;
      if not Is_Dir then
         Size := Info.Size;
      end if;
      return Status_Ok;
   end Stat;

   function Read (Path : String; Offset : U64; Buf : System.Address;
                  Len : in out U64) return U64
   is
      Info : Inode_Info;
      Root : Boolean;
   begin
      if not Is_Mounted or else not Lookup (Path, Info, Root)
        or else Root
        or else (Info.Mode and S_IFMT) /= 8#100000#  --  S_IFREG
      then
         Len := 0;
         return Status_Not_Found;
      end if;
      if Offset > Info.Size then
         Len := 0;
         return Status_Out_Of_Range;
      end if;
      if Offset = Info.Size then
         Len := 0;  --  read at EOF: success, nothing to copy
         return Status_Ok;
      end if;
      Len := U64'Min (Len, Info.Size - Offset);
      Len := Stream_Read (Info, Offset, Buf, Len);
      return Status_Ok;
   end Read;

   function Read_Dir (Path : String; Index : U64;
                      Name : out String; Name_Len : out Natural;
                      Size : out U64; Is_Dir : out Boolean)
                      return U64
   is
      Info   : Inode_Info;
      Root   : Boolean;
      It     : Tree_It;
      E_Name : String (1 .. 32);
      E_Len  : Natural;
      Block  : U64;
      E_Info : Inode_Info;
      Ok     : Boolean;
      Seen   : U64 := 0;
   begin
      Name_Len := 0;
      Size := 0;
      Is_Dir := False;
      if not Is_Mounted or else not Lookup (Path, Info, Root) then
         return Status_Not_Found;
      end if;
      if (Info.Mode and S_IFMT) /= S_IFDIR then
         return Status_Not_Found;
      end if;
      Tree_Rewind (Info, It, Ok);
      if not Ok then
         return Status_Not_Found;
      end if;
      while Tree_Next (It, E_Name, E_Len, Block) loop
         if not (E_Len = 1 and then E_Name (1) = '.')
           and then not (E_Len = 2
                         and then E_Name (1 .. 2) = "..")
         then
            if Seen = Index then
               if not Read_Inode (Block, E_Info) then
                  return Status_Not_Found;
               end if;
               Is_Dir := (E_Info.Mode and S_IFMT) = S_IFDIR;
               if not Is_Dir then
                  Size := E_Info.Size;
               end if;
               Name_Len := Natural'Min (E_Len, Name'Length);
               Name (Name'First .. Name'First + Name_Len - 1) :=
                 E_Name (1 .. Name_Len);
               return Status_Ok;
            end if;
            Seen := Seen + 1;
         end if;
      end loop;
      return Status_Not_Found;
   end Read_Dir;

   ------------------------------------------------------------------
   --  Attributes (small_data region of the inode, m82d)
   ------------------------------------------------------------------

   --  Entry layout (tools/mkbefs.py, Haiku Inode::AddSmallData):
   --  le32 type, le16 name_size (no NUL), le16 data_size, name
   --  bytes, 3 pad bytes (NUL + 2), data bytes, 1 pad byte. A
   --  zeroed header (name_size = 0) ends the list; the region
   --  runs from offset 232 to the end of the inode block.
   Small_Data_Off : constant U64 := 232;

   --  Every file inode carries a NAME pseudo-attribute first
   --  (type FILE_NAME_TYPE 'CSTR', name_size = 1, name byte
   --  0x13 = FILE_NAME_NAME, data = the file name) so the name
   --  index can back-refer. Like Haiku's attribute iterator and
   --  tools/befs_dump.py, it is NOT a user-visible attribute:
   --  both walks below skip it.
   File_Name_Name : constant U8 := 16#13#;

   --  True when the small_data entry at Pos is the internal
   --  name pseudo-attribute.
   function Is_Name_Attr (Slot : Natural; Pos : U64; NLen : U64)
                          return Boolean is
     (NLen = 1 and then Cache_Data (Slot, Pos + 8) = File_Name_Name);

   function Attr_List (Path : String; Index : U64;
                       Name : out String; Name_Len : out Natural;
                       Attr_Type : out U64; Data_Size : out U64)
                       return U64
   is
      Info : Inode_Info;
      Root : Boolean;
      Pos  : U64;
      NLen : U64;
      DLen : U64;
      Seen : U64 := 0;
   begin
      Name_Len := 0;
      Attr_Type := 0;
      Data_Size := 0;
      if not Is_Mounted or else not Lookup (Path, Info, Root) then
         return Status_Not_Found;
      end if;
      declare
         Slot : constant Natural := Get_Block (Info.Block);
      begin
         if Slot = Cache_Slots then
            return Status_Not_Found;
         end if;
         Pos := Small_Data_Off;
         while Pos + 8 <= Block_Size loop
            NLen := U64 (LE16 (Slot, Pos + 4));
            DLen := U64 (LE16 (Slot, Pos + 6));
            exit when NLen = 0;
            exit when Pos + 8 + NLen + 3 + DLen + 1 > Block_Size;
            if not Is_Name_Attr (Slot, Pos, NLen) then
               if Seen = Index then
                  Attr_Type := U64 (LE32 (Slot, Pos));
                  Data_Size := DLen;
                  for I in 0 .. NLen - 1 loop
                     exit when I >= U64 (Name'Length);
                     Name_Len := Name_Len + 1;
                     Name (Name'First + Name_Len - 1) :=
                       Character'Val (Natural
                         (Cache_Data (Slot, Pos + 8 + I)));
                  end loop;
                  Put_Block (Slot);
                  return Status_Ok;
               end if;
               Seen := Seen + 1;
            end if;
            Pos := Pos + 8 + NLen + 3 + DLen + 1;
         end loop;
         Put_Block (Slot);
      end;
      return Status_Not_Found;
   end Attr_List;

   function Attr_Read (Path : String; Attr : String;
                       Buf : System.Address; Buf_Len : U64;
                       Count : out U64; Data_Size : out U64;
                       Attr_Type : out U64) return U64
   is
      Info  : Inode_Info;
      Root  : Boolean;
      Pos   : U64;
      NLen  : U64;
      DLen  : U64;
      Match : Boolean;
   begin
      Count := 0;
      Data_Size := 0;
      Attr_Type := 0;
      if not Is_Mounted or else not Lookup (Path, Info, Root) then
         return Status_Not_Found;
      end if;
      declare
         Slot : constant Natural := Get_Block (Info.Block);
      begin
         if Slot = Cache_Slots then
            return Status_Not_Found;
         end if;
         Pos := Small_Data_Off;
         while Pos + 8 <= Block_Size loop
            NLen := U64 (LE16 (Slot, Pos + 4));
            DLen := U64 (LE16 (Slot, Pos + 6));
            exit when NLen = 0;
            exit when Pos + 8 + NLen + 3 + DLen + 1 > Block_Size;
            if not Is_Name_Attr (Slot, Pos, NLen)
              and then NLen = U64 (Attr'Length)
            then
               Match := True;
               for I in 0 .. NLen - 1 loop
                  if Cache_Data (Slot, Pos + 8 + I) /=
                    U8 (Character'Pos (Attr (Attr'First + Natural (I))))
                  then
                     Match := False;
                     exit;
                  end if;
               end loop;
               if Match then
                  Attr_Type := U64 (LE32 (Slot, Pos));
                  Data_Size := DLen;
                  Count := U64'Min (DLen, Buf_Len);
                  if Count > 0 then
                     declare
                        Dst : Byte_Array (0 .. Count - 1)
                          with Address => Buf;
                     begin
                        for I in Dst'Range loop
                           Dst (I) :=
                             Cache_Data (Slot, Pos + 8 + NLen + 3 + I);
                        end loop;
                     end;
                  end if;
                  Put_Block (Slot);
                  return Status_Ok;
               end if;
            end if;
            Pos := Pos + 8 + NLen + 3 + DLen + 1;
         end loop;
         Put_Block (Slot);
      end;
      return Status_Not_Found;
   end Attr_Read;

   procedure Volume_Info (Total, Free, Block : out U64) is
   begin
      if Is_Mounted then
         Total := Interfaces.Shift_Left (Num_Blocks, 10);
         Free  := Interfaces.Shift_Left (Num_Blocks - Used_Blocks, 10);
         Block := Block_Size;
      else
         Total := 0;
         Free := 0;
         Block := 0;
      end if;
   end Volume_Info;

   --  The indices root inode is part of the mounted geometry but
   --  only used from M82f (queries) onward.
   pragma Unreferenced (Index_Block);

end Bfs_Engine;
