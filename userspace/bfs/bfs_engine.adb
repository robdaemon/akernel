--  BeFS engine body (m82c read, m82e journaled write). Layout
--  mirrors tools/mkbefs.py (which writes the fixture) and
--  tools/befs_dump.py (which reads it back); field offsets are the
--  Haiku BFS on-disk format:
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
--
--  Write path (m82e): one journal transaction per wire op, WAL
--  ordered — run_array + contents into the log, superblock DIRT
--  with the new log_end, blocks to their destinations, superblock
--  CLEN with log_start = log_end. The log format is Haiku's
--  (Journal.cpp): a transaction at log offset S is one run_array
--  block {count, max_runs=127, runs[count]} — destination block
--  runs, sorted/merged — followed by the block contents in run
--  order. Log offsets are positions within the log area, taken
--  mod log length. Idx mount a non-empty log is replayed the same
--  way (Journal::ReplayLog). Single-leaf btrees only (no node
--  splits): leaf insert/remove rebuild the node; a leaf without
--  room fails the op with Bad_Args.

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

    Blk_Read  : constant U64 := 1;
    Blk_Write : constant U64 := 2;
    Blk_Flush : constant U64 := 4;

    SB_Magic1    : constant U32 := 16#4246_5331#;  --  'BFS1'
    SB_Magic2    : constant U32 := 16#DD12_1031#;
    SB_Magic3    : constant U32 := 16#15B6_830E#;
    SB_LE        : constant U32 := 16#4249_4745#;  --  'BIGE'
    SB_Clean     : constant U32 := 16#434C_454E#;  --  'CLEN'
    SB_Dirty     : constant U32 := 16#4449_5254#;  --  'DIRT'
    Inode_Magic  : constant U32 := 16#3BBE_0AD9#;
    Btree_Magic  : constant U32 := 16#69F6_C2E8#;
    Inode_In_Use : constant U32 := 16#0000_0001#;
    Btree_Null   : constant U64 := 16#FFFF_FFFF_FFFF_FFFF#;
    File_Name_Type : constant U32 := 16#4353_5452#;  --  'CSTR'
    File_Name_Name : constant U8 := 16#13#;

    S_IFMT      : constant U32 := 8#170000#;
    S_IFDIR     : constant U32 := 8#040000#;
    S_IFREG     : constant U32 := 8#100000#;
    S_STR_INDEX : constant U32 := 8#1000000000#;

    Block_Size : constant U64 := 1024;  --  mount gate (fixture geometry)

    Status_Ok           : constant U64 := 0;
    Status_Not_Found    : constant U64 := 1;
    Status_Bad_Args     : constant U64 := 3;
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

    --  Journal geometry (superblock log_blocks / log_start /
    --  log_end). Positions are offsets within the log area.
    Log_Base      : U64 := 0;   --  first block of the log area
    Log_Len       : U64 := 0;   --  log area length in blocks
    Log_Pos_Start : U64 := 0;
    Log_Pos_End   : U64 := 0;

    --  Name index inode (found under the indices root at mount;
    --  0 when the volume has none — index maintenance then skips).
    Name_Index   : U64 := 0;

    --  Block allocator state: net used_blocks change of the open
    --  transaction (folded into Used_Blocks at commit) and the
    --  first-fit scan hint.
    Used_Pending : U64 := 0;
    Alloc_Hint   : U64 := 514;

    --  Block cache: 16 slots of one block each. Writes always go
    --  through the journal transaction below: modify the slot,
    --  Trans_Add snapshots it, Trans_Commit does the WAL dance.
    Cache_Slots : constant := 16;
    Cache_Num   : array (0 .. Cache_Slots - 1) of U64 :=
      (others => U64'Last);
    Cache_Refs  : array (0 .. Cache_Slots - 1) of Natural :=
      (others => 0);
    Cache_Data  : array (0 .. Cache_Slots - 1,
                         0 .. Block_Size - 1) of U8;

    --  Open journal transaction (m82e; one per wire op). Get_Block
    --  overlays these snapshots onto fresh disk reads so the
    --  uncommitted state stays readable inside the transaction.
    Max_Trans_Blocks : constant := 40;
    Trans_Count : Natural := 0;
    Trans_Num   : array (0 .. Max_Trans_Blocks - 1) of U64;
    Trans_Data  : array (0 .. Max_Trans_Blocks - 1,
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
       --  Transaction overlay: a block modified earlier in the
       --  open transaction but not yet committed must read back
       --  the journaled snapshot, not the stale disk contents.
       for T in 0 .. Trans_Count - 1 loop
          if Trans_Num (T) = Num then
             for I in 0 .. Block_Size - 1 loop
                Cache_Data (Free, I) := Trans_Data (T, I);
             end loop;
             exit;
          end if;
       end loop;
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

    --  Little-endian writers over a cache slot (write path).

    procedure Put_LE16 (Slot : Natural; Off : U64; V : U16) is
    begin
       Cache_Data (Slot, Off) := U8 (V and 16#FF#);
       Cache_Data (Slot, Off + 1) := U8 (Interfaces.Shift_Right (V, 8));
    end Put_LE16;

    procedure Put_LE32 (Slot : Natural; Off : U64; V : U32) is
    begin
       for I in 0 .. 3 loop
          Cache_Data (Slot, Off + U64 (I)) :=
            U8 (Interfaces.Shift_Right (V, 8 * I) and 16#FF#);
       end loop;
    end Put_LE32;

    procedure Put_LE64 (Slot : Natural; Off : U64; V : U64) is
    begin
       for I in 0 .. 7 loop
          Cache_Data (Slot, Off + U64 (I)) :=
            U8 (Interfaces.Shift_Right (V, 8 * I) and 16#FF#);
       end loop;
    end Put_LE64;

    ------------------------------------------------------------------
    --  Raw block write + device flush (write path)
    ------------------------------------------------------------------

    --  Write one block from Src (1024 bytes) through the bounce
    --  buffer.
    function Write_Raw (Num : U64; Src : System.Address)
                        return Boolean
    is
       Dst : Byte_Array (0 .. Block_Size - 1)
         with Address => To_Address (Integer_Address (Buf_VA));
       Data : Byte_Array (0 .. Block_Size - 1) with Address => Src;
    begin
       for I in Dst'Range loop
          Dst (I) := Data (I);
       end loop;
       Syscalls.Message.Label := Blk_Write;
       Syscalls.Message.Words (0) := Num * 2;
       Syscalls.Message.Words (1) := 2;
       Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);
       if Syscalls.IPC_Call (Blk_EP) /= Syscalls.IPC_Ok
         or else Syscalls.Message.Words (0) /= 0
       then
          Akernel_User.Console.Put_Line ("bfs: block write io error");
          return False;
       end if;
       return True;
    end Write_Raw;

    function Flush_Device return Boolean is
    begin
       Syscalls.Message.Label := Blk_Flush;
       Syscalls.Message.Caps := (others => 0);
       return Syscalls.IPC_Call (Blk_EP) = Syscalls.IPC_Ok
         and then Syscalls.Message.Words (0) = 0;
    end Flush_Device;

    --  Drop all cache slots holding Num (used after raw writes so
    --  the next read sees disk contents).
    procedure Invalidate (Num : U64) is
    begin
       for S in 0 .. Cache_Slots - 1 loop
          if Cache_Num (S) = Num then
             Cache_Num (S) := U64'Last;
             Cache_Refs (S) := 0;
          end if;
       end loop;
    end Invalidate;

    ------------------------------------------------------------------
    --  Journal (m82e). One transaction per wire op; the log never
    --  accumulates because every commit checkpoints immediately
    --  (log_start := log_end in the CLEN superblock write).
    ------------------------------------------------------------------

    --  Snapshot the slot's block into the transaction (dedupes by
    --  block number: a later snapshot overwrites an earlier one).
    procedure Trans_Add (Slot : Natural) is
       Num : constant U64 := Cache_Num (Slot);
    begin
       for I in 0 .. Trans_Count - 1 loop
          if Trans_Num (I) = Num then
             for B in 0 .. Block_Size - 1 loop
                Trans_Data (I, B) := Cache_Data (Slot, B);
             end loop;
             return;
          end if;
       end loop;
       if Trans_Count = Max_Trans_Blocks then
          Fail : begin
             Akernel_User.Console.Put_Line ("bfs: transaction too big");
             loop
                null;
             end loop;
          end Fail;
       end if;
       Trans_Num (Trans_Count) := Num;
       for B in 0 .. Block_Size - 1 loop
          Trans_Data (Trans_Count, B) := Cache_Data (Slot, B);
       end loop;
       Trans_Count := Trans_Count + 1;
    end Trans_Add;

    --  Drop the transaction without writing anything; cached
    --  copies of the touched blocks are invalidated (they carry
    --  modifications disk never saw).
    procedure Trans_Abort is
    begin
       for I in 0 .. Trans_Count - 1 loop
          Invalidate (Trans_Num (I));
       end loop;
       Trans_Count := 0;
       Used_Pending := 0;
    end Trans_Abort;

    --  Rewrite the superblock half of block 0 with the current
    --  journal positions, Used_Blocks (+ pending delta at the
    --  clean checkpoint) and the clean/dirty flag.
    function Write_Super (Dirty : Boolean) return Boolean is
       Slot : constant Natural := Get_Block (0);
       Ok   : Boolean;
    begin
       if Slot = Cache_Slots then
          return False;
       end if;
       if not Dirty then
          Used_Blocks := Used_Blocks + Used_Pending;
          Used_Pending := 0;
          Put_LE64 (Slot, 512 + 56, Used_Blocks);
       end if;
       Put_LE32 (Slot, 512 + 84,
                 (if Dirty then SB_Dirty else SB_Clean));
       Put_LE64 (Slot, 512 + 96, Log_Pos_Start);
       Put_LE64 (Slot, 512 + 104, Log_Pos_End);
       Ok := Write_Raw (0, Cache_Data (Slot, 0)'Address);
       --  The slot is dirty vs. what other readers expect (flags);
       --  drop it so the next Get_Block re-reads.
       Cache_Num (Slot) := U64'Last;
       Cache_Refs (Slot) := 0;
       return Ok;
    end Write_Super;

    --  WAL commit: log, superblock-dirty, data, superblock-clean.
    function Trans_Commit return Boolean is
       Order : array (0 .. Max_Trans_Blocks - 1) of Natural;
       Pos   : U64;
       Tmp   : Natural;
       Run_Open : Boolean;
       Run_Start : U64;
       Run_Len   : U64;
       Run_Count : U64;
       Arr   : Byte_Array (0 .. Block_Size - 1);
    begin
       if Trans_Count = 0 then
          return True;
       end if;
       if U64 (Trans_Count) + 1 >= Log_Len then
          Trans_Abort;
          return False;
       end if;

       --  Selection-sort entry indices by block number (runs in
       --  the run_array are sorted/merged, contents follow).
       for I in 0 .. Trans_Count - 1 loop
          Order (I) := I;
       end loop;
       for I in 0 .. Trans_Count - 1 loop
          for J in I + 1 .. Trans_Count - 1 loop
             if Trans_Num (Order (J)) < Trans_Num (Order (I)) then
                Tmp := Order (I);
                Order (I) := Order (J);
                Order (J) := Tmp;
             end if;
          end loop;
       end loop;

       --  Build the run_array block: merged destination runs.
       for I in Arr'Range loop
          Arr (I) := 0;
       end loop;
       Run_Count := 0;
       Run_Open := False;
       Run_Start := 0;
       Run_Len := 0;
       for I in 0 .. Trans_Count - 1 loop
          if Run_Open
            and then Trans_Num (Order (I)) = Run_Start + Run_Len
          then
             Run_Len := Run_Len + 1;
          else
             if Run_Open then
                declare
                   O : constant U64 := 8 + (Run_Count - 1) * 8;
                begin
                   for B in 0 .. 3 loop
                      Arr (O + U64 (B)) := 0;  --  ag 0
                   end loop;
                   Arr (O + 4) := U8 (Run_Start and 16#FF#);
                   Arr (O + 5) :=
                     U8 (Interfaces.Shift_Right (Run_Start, 8)
                           and 16#FF#);
                   Arr (O + 6) := U8 (Run_Len and 16#FF#);
                   Arr (O + 7) :=
                     U8 (Interfaces.Shift_Right (Run_Len, 8)
                           and 16#FF#);
                end;
             end if;
             Run_Open := True;
             Run_Start := Trans_Num (Order (I));
             Run_Len := 1;
             Run_Count := Run_Count + 1;
          end if;
       end loop;
       declare
          O : constant U64 := 8 + (Run_Count - 1) * 8;
       begin
          for B in 0 .. 3 loop
             Arr (O + U64 (B)) := 0;
          end loop;
          Arr (O + 4) := U8 (Run_Start and 16#FF#);
          Arr (O + 5) :=
            U8 (Interfaces.Shift_Right (Run_Start, 8) and 16#FF#);
          Arr (O + 6) := U8 (Run_Len and 16#FF#);
          Arr (O + 7) :=
            U8 (Interfaces.Shift_Right (Run_Len, 8) and 16#FF#);
       end;
       for B in 0 .. 3 loop
          Arr (U64 (B)) :=
            U8 (Interfaces.Shift_Right (Run_Count, 8 * B) and 16#FF#);
          Arr (4 + U64 (B)) :=
            U8 (Interfaces.Shift_Right (U64 (127), 8 * B) and 16#FF#);
       end loop;

       --  Stage 1: run_array + contents into the log.
       Pos := Log_Pos_End;
       if not Write_Raw (Log_Base + Pos, Arr (Arr'First)'Address) then
          Trans_Abort;
          return False;
       end if;
       Pos := (Pos + 1) mod Log_Len;
       for I in 0 .. Trans_Count - 1 loop
          if not Write_Raw
            (Log_Base + Pos,
             Trans_Data (Order (I), 0)'Address)
          then
             Trans_Abort;
             return False;
          end if;
          Pos := (Pos + 1) mod Log_Len;
       end loop;
       Log_Pos_End := Pos;

       --  Stage 2: superblock DIRT pins the new log_end.
       if not Write_Super (Dirty => True) or else not Flush_Device
       then
          Trans_Abort;
          return False;
       end if;

       --  Stage 3: blocks to their destinations; keep cache slots
       --  holding them coherent with what was written.
       for I in 0 .. Trans_Count - 1 loop
          if not Write_Raw
            (Trans_Num (Order (I)),
             Trans_Data (Order (I), 0)'Address)
          then
             Trans_Abort;
             return False;
          end if;
          for S in 0 .. Cache_Slots - 1 loop
             if Cache_Num (S) = Trans_Num (Order (I)) then
                for B in 0 .. Block_Size - 1 loop
                   Cache_Data (S, B) := Trans_Data (Order (I), B);
                end loop;
             end if;
          end loop;
       end loop;
       if not Flush_Device then
          Trans_Abort;
          return False;
       end if;

       --  Stage 4: clean checkpoint.
       Log_Pos_Start := Log_Pos_End;
       if not Write_Super (Dirty => False) or else not Flush_Device
       then
          Trans_Abort;
          return False;
       end if;
       Trans_Count := 0;
       return True;
    end Trans_Commit;

    --  Crash recovery at mount: re-write journaled blocks to their
    --  destinations, then checkpoint clean (Journal::ReplayLog).
    function Replay_Log return Boolean is
       Pos  : U64 := Log_Pos_Start mod Log_Len;
       Stop : constant U64 := Log_Pos_End mod Log_Len;
       Runs : array (0 .. 126) of Block_Run;
       Cnt  : U64;
       Dest : U64;
    begin
       while Pos /= Stop loop
          declare
             Slot : constant Natural := Get_Block (Log_Base + Pos);
          begin
             if Slot = Cache_Slots then
                return False;
             end if;
             Cnt := U64 (LE32 (Slot, 0));
             if Cnt = 0 or else Cnt > 127
               or else LE32 (Slot, 4) /= 127
             then
                Put_Block (Slot);
                return False;
             end if;
             for I in 0 .. Cnt - 1 loop
                Runs (Natural (I)) := Run_At (Slot, 8 + I * 8);
                if Runs (Natural (I)).AG /= 0
                  or else Runs (Natural (I)).Length = 0
                  or else To_Block (Runs (Natural (I)))
                            + U64 (Runs (Natural (I)).Length)
                          > Num_Blocks
                then
                   Put_Block (Slot);
                   return False;
                end if;
             end loop;
             Put_Block (Slot);
          end;
          Pos := (Pos + 1) mod Log_Len;
          for I in 0 .. Natural (Cnt) - 1 loop
             Dest := To_Block (Runs (I));
             for J in 0 .. U64 (Runs (I).Length) - 1 loop
                declare
                   Slot : constant Natural :=
                     Get_Block (Log_Base + Pos);
                begin
                   if Slot = Cache_Slots then
                      return False;
                   end if;
                   if not Write_Raw
                     (Dest + J, Cache_Data (Slot, 0)'Address)
                   then
                      Put_Block (Slot);
                      return False;
                   end if;
                   Put_Block (Slot);
                   Invalidate (Dest + J);
                end;
                Pos := (Pos + 1) mod Log_Len;
             end loop;
          end loop;
       end loop;
       Log_Pos_Start := Log_Pos_End;
       if not Write_Super (Dirty => False) then
          return False;
       end if;
       return Flush_Device;
    end Replay_Log;

    ------------------------------------------------------------------
    --  Block allocator (bitmap block 1, bit i = block i, lsb first)
    ------------------------------------------------------------------

    function Bit_Test (Slot : Natural; B : U64) return Boolean is
      ((Cache_Data (Slot, B / 8)
          and Interfaces.Shift_Left (U8 (1), Natural (B mod 8))) /= 0);

    --  First-fit contiguous run of Count blocks; the bitmap block
    --  change joins the open transaction.
    function Alloc (Count : U64; Start : out U64) return Boolean is
       Slot : constant Natural := Get_Block (1);
       B    : U64;
       Run  : U64;
       Lo   : U64;
    begin
       Start := 0;
       if Slot = Cache_Slots then
          return False;
       end if;
       for Pass in 0 .. 1 loop
          Lo := (if Pass = 0 then Alloc_Hint else 2 + Log_Len);
          B := Lo;
          while B + Count <= Num_Blocks
            and then (Pass = 0 or else B < Alloc_Hint)
          loop
             if not Bit_Test (Slot, B) then
                Run := 0;
                while Run < Count
                  and then B + Run < Num_Blocks
                  and then not Bit_Test (Slot, B + Run)
                loop
                   Run := Run + 1;
                end loop;
                if Run = Count then
                   for K in 0 .. Count - 1 loop
                      Cache_Data (Slot, (B + K) / 8) :=
                        Cache_Data (Slot, (B + K) / 8)
                          or Interfaces.Shift_Left
                            (U8 (1), Natural ((B + K) mod 8));
                   end loop;
                   Trans_Add (Slot);
                   Put_Block (Slot);
                   Used_Pending := Used_Pending + Count;
                   Start := B;
                   Alloc_Hint := B + Count;
                   return True;
                end if;
                B := B + U64'Max (Run, 1);
             else
                B := B + 1;
             end if;
          end loop;
       end loop;
       Put_Block (Slot);
       return False;
    end Alloc;

    procedure Free (Start : U64; Count : U64) is
       Slot : constant Natural := Get_Block (1);
    begin
       if Slot = Cache_Slots then
          return;
       end if;
       for K in 0 .. Count - 1 loop
          Cache_Data (Slot, (Start + K) / 8) :=
            Cache_Data (Slot, (Start + K) / 8)
              and not Interfaces.Shift_Left
                (U8 (1), Natural ((Start + K) mod 8));
       end loop;
       Trans_Add (Slot);
       Put_Block (Slot);
       Used_Pending := Used_Pending - Count;
       if Start < Alloc_Hint then
          Alloc_Hint := Start;
       end if;
    end Free;

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
    --  Single-leaf btree mutation (m82e; no node splits)
    ------------------------------------------------------------------

    subtype Block_Buf is Byte_Array (0 .. Block_Size - 1);

    function Buf_LE16 (B : Block_Buf; Off : U64) return U64 is
      (U64 (B (Off)) + Interfaces.Shift_Left (U64 (B (Off + 1)), 8));

    function Buf_LE64 (B : Block_Buf; Off : U64) return U64 is
       V : U64 := 0;
    begin
       for I in 0 .. 7 loop
          V := V or Interfaces.Shift_Left (U64 (B (Off + U64 (I))),
                                           8 * I);
       end loop;
       return V;
    end Buf_LE64;

    --  Physical block of stream offset Off through the direct runs.
    function Stream_Block (Info : Inode_Info; Off : U64) return U64 is
       Covered : U64 := 0;
    begin
       for R of Info.Direct loop
          exit when R.Length = 0;
          if Off < Covered + U64 (R.Length) * Block_Size then
             return To_Block (R) + (Off - Covered) / Block_Size;
          end if;
          Covered := Covered + U64 (R.Length) * Block_Size;
       end loop;
      return U64'Last;
    end Stream_Block;

    --  Decoded leaf: keys as raw bytes, sorted; duplicate keys
    --  allowed (the name index has one entry per same-named file).
    Leaf_Max     : constant := 24;
    Leaf_Key_Max : constant := 64;
    type Leaf_KL_Array   is array (0 .. Leaf_Max - 1) of Natural;
    type Leaf_Key_Row    is array (U64 range 0 .. Leaf_Key_Max - 1)
       of U8;
    type Leaf_Keys_Array is array (0 .. Leaf_Max - 1)
       of Leaf_Key_Row;
    type Leaf_Vals_Array is array (0 .. Leaf_Max - 1) of U64;
    type Leaf_Entries is record
       N    : Natural := 0;
       KL   : Leaf_KL_Array := (others => 0);
       Keys : Leaf_Keys_Array := (others => (others => 0));
       Vals : Leaf_Vals_Array := (others => 0);
    end record;

    --  Bytewise key order: shorter-is-less on equal prefix.
    function Key_Less (E : Leaf_Entries; I : Natural; Key : String)
                       return Boolean
    is
       K : Natural := 0;
    begin
       while K < E.KL (I) and then K < Key'Length loop
          if E.Keys (I)(U64 (K)) /=
            U8 (Character'Pos (Key (Key'First + K)))
          then
             return E.Keys (I)(U64 (K))
               < U8 (Character'Pos (Key (Key'First + K)));
          end if;
          K := K + 1;
       end loop;
       return E.KL (I) < Key'Length;
    end Key_Less;

    function Key_Equal (E : Leaf_Entries; I : Natural; Key : String)
                        return Boolean is
    begin
       if E.KL (I) /= Key'Length then
          return False;
       end if;
       for K in 0 .. Key'Length - 1 loop
          if E.Keys (I)(U64 (K)) /=
            U8 (Character'Pos (Key (Key'First + K)))
          then
             return False;
          end if;
       end loop;
       return True;
    end Key_Equal;

    --  Load the tree's single leaf into Node; Node_Block is its
    --  physical block. False when the tree is not a single leaf
    --  (multi-leaf/internal trees are beyond m82e).
    function Leaf_Load (Dir : Inode_Info; Node : out Block_Buf;
                        Node_Block : out U64) return Boolean
    is
       Hdr : Block_Buf;
       Got : U64;
       Root_Off : U64;
    begin
       Node_Block := U64'Last;
       Got := Stream_Read (Dir, 0, Hdr (Hdr'First)'Address, Block_Size);
       if Got /= Block_Size
         or else U32 (Buf_LE64 (Hdr, 0) and 16#FFFF_FFFF#) /= Btree_Magic
       then
          return False;
       end if;
       Root_Off := Buf_LE64 (Hdr, 16);
       Node_Block := Stream_Block (Dir, Root_Off);
       if Node_Block = U64'Last then
          return False;
       end if;
       declare
          Slot : constant Natural := Get_Block (Node_Block);
       begin
          if Slot = Cache_Slots then
             Node_Block := U64'Last;
             return False;
          end if;
          for I in Node'Range loop
             Node (I) := Cache_Data (Slot, I);
          end loop;
          Put_Block (Slot);
       end;
       --  Single leaf: left, right and overflow links all -1.
       if Buf_LE64 (Node, 0) /= Btree_Null
         or else Buf_LE64 (Node, 8) /= Btree_Null
         or else Buf_LE64 (Node, 16) /= Btree_Null
       then
          Node_Block := U64'Last;
          return False;
       end if;
       return True;
    end Leaf_Load;

    procedure Leaf_Decode (Node : Block_Buf; E : out Leaf_Entries)
    is
       Count : constant Natural := Natural (Buf_LE16 (Node, 24));
       KLen  : constant U64 := Buf_LE16 (Node, 26);
       Lens  : constant U64 := (28 + KLen + 7) and not 7;
       Pos   : U64 := 28;
       L     : Natural;
    begin
       E.N := 0;
       for I in 0 .. Count - 1 loop
          exit when E.N = Leaf_Max;
          L := Natural (Buf_LE16 (Node, Lens + 2 * U64 (I)));
          exit when U64 (L) > Leaf_Key_Max;
          E.KL (E.N) := L;
          for K in 0 .. U64 (L) - 1 loop
             E.Keys (E.N)(K) := Node (Pos + K);
          end loop;
          E.Vals (E.N) := Buf_LE64 (Node, Lens + 2 * U64 (Count)
                                    + 8 * U64 (I));
          Pos := Pos + U64 (L);
          E.N := E.N + 1;
       end loop;
    end Leaf_Decode;

    --  Encode E back into Node. Total byte count check is the
    --  caller's (Leaf_Can_Fit); encode returns False on overflow.
    function Leaf_Encode (E : Leaf_Entries; Node : out Block_Buf)
                          return Boolean
    is
       KTotal : U64 := 0;
       Pos    : U64;
       Lens   : U64;
    begin
       for I in 0 .. E.N - 1 loop
          KTotal := KTotal + U64 (E.KL (I));
       end loop;
       Lens := (28 + KTotal + 7) and not 7;
       if Lens + 2 * U64 (E.N) + 8 * U64 (E.N) > Block_Size then
          return False;
       end if;
       Node := (others => 0);
       for I in 0 .. 7 loop
          Node (U64 (I)) := 16#FF#;
          Node (8 + U64 (I)) := 16#FF#;
          Node (16 + U64 (I)) := 16#FF#;
       end loop;
       Node (24) := U8 (U64 (E.N) and 16#FF#);
       Node (25) := U8 (Interfaces.Shift_Right (U64 (E.N), 8));
       Node (26) := U8 (KTotal and 16#FF#);
       Node (27) := U8 (Interfaces.Shift_Right (KTotal, 8) and 16#FF#);
       Pos := 28;
       for I in 0 .. E.N - 1 loop
          for K in 0 .. U64 (E.KL (I)) - 1 loop
             Node (Pos + K) := E.Keys (I)(K);
          end loop;
          Pos := Pos + U64 (E.KL (I));
          Node (Lens + 2 * U64 (I)) := U8 (U64 (E.KL (I)) and 16#FF#);
          Node (Lens + 2 * U64 (I) + 1) :=
            U8 (Interfaces.Shift_Right (U64 (E.KL (I)), 8));
       end loop;
       Pos := Lens + 2 * U64 (E.N);
       for I in 0 .. E.N - 1 loop
          for B in 0 .. 7 loop
             Node (Pos + U64 (B)) :=
               U8 (Interfaces.Shift_Right (E.Vals (I), 8 * B)
                     and 16#FF#);
          end loop;
          Pos := Pos + 8;
       end loop;
       return True;
    end Leaf_Encode;

    --  Write the encoded node back through cache + transaction.
    function Leaf_Store (Node_Block : U64; Node : Block_Buf)
                         return Boolean
    is
       Slot : constant Natural := Get_Block (Node_Block);
    begin
       if Slot = Cache_Slots then
          return False;
       end if;
       for I in Node'Range loop
          Cache_Data (Slot, I) := Node (I);
       end loop;
       Trans_Add (Slot);
       Put_Block (Slot);
       return True;
    end Leaf_Store;

    --  Would Key fit into the tree's single leaf?
    function Leaf_Can_Fit (Dir : Inode_Info; Key : String)
                           return Boolean
    is
       Node  : Block_Buf;
       NBlk  : U64;
       E     : Leaf_Entries;
       KTotal : U64 := 0;
    begin
       if Key'Length = 0 or else Key'Length > Leaf_Key_Max then
          return False;
       end if;
       if not Leaf_Load (Dir, Node, NBlk) then
          return False;
       end if;
       Leaf_Decode (Node, E);
       if E.N = Leaf_Max then
          return False;
       end if;
       for I in 0 .. E.N - 1 loop
          KTotal := KTotal + U64 (E.KL (I));
       end loop;
       KTotal := KTotal + U64 (Key'Length);
       return ((28 + KTotal + 7) and not 7)
         + 2 * U64 (E.N + 1) + 8 * U64 (E.N + 1) <= Block_Size;
    end Leaf_Can_Fit;

    --  Find the value of the FIRST entry whose key equals Key.
    function Leaf_Find (Dir : Inode_Info; Key : String;
                        Value : out U64) return Boolean
    is
       Node : Block_Buf;
       NBlk : U64;
       E    : Leaf_Entries;
    begin
       Value := 0;
       if not Leaf_Load (Dir, Node, NBlk) then
          return False;
       end if;
       Leaf_Decode (Node, E);
       for I in 0 .. E.N - 1 loop
          if Key_Equal (E, I, Key) then
             Value := E.Vals (I);
             return True;
          end if;
       end loop;
       return False;
    end Leaf_Find;

    --  Insert Key/Value keeping sorted order (equal keys: after
    --  existing ones). Callers pre-check Leaf_Can_Fit.
    function Leaf_Insert (Dir : Inode_Info; Key : String; Value : U64)
                          return Boolean
    is
       Node : Block_Buf;
       NBlk : U64;
       E    : Leaf_Entries;
       Idx   : Natural := 0;
    begin
       if not Leaf_Load (Dir, Node, NBlk) then
          return False;
       end if;
       Leaf_Decode (Node, E);
       if E.N = Leaf_Max then
          return False;
       end if;
       while Idx < E.N and then Key_Less (E, Idx, Key) loop
          Idx := Idx + 1;
       end loop;
       while Idx < E.N and then Key_Equal (E, Idx, Key) loop
          Idx := Idx + 1;  --  duplicates go after existing keys
       end loop;
       for I in reverse Idx + 1 .. E.N loop
          E.KL (I) := E.KL (I - 1);
          E.Keys (I) := E.Keys (I - 1);
          E.Vals (I) := E.Vals (I - 1);
       end loop;
       E.KL (Idx) := Key'Length;
       E.Keys (Idx) := (others => 0);
       for K in 0 .. Key'Length - 1 loop
          E.Keys (Idx)(U64 (K)) :=
            U8 (Character'Pos (Key (Key'First + K)));
       end loop;
       E.Vals (Idx) := Value;
       E.N := E.N + 1;
       if not Leaf_Encode (E, Node) then
          return False;
       end if;
       return Leaf_Store (NBlk, Node);
    end Leaf_Insert;

    --  Remove the entry matching Key (and Value when Match_Value).
    function Leaf_Remove (Dir : Inode_Info; Key : String; Value : U64;
                          Match_Value : Boolean) return Boolean
    is
       Node : Block_Buf;
       NBlk : U64;
       E    : Leaf_Entries;
       Idx   : Natural := 0;
       Hit  : Boolean := False;
    begin
       if not Leaf_Load (Dir, Node, NBlk) then
          return False;
       end if;
       Leaf_Decode (Node, E);
       for I in 0 .. E.N - 1 loop
          if Key_Equal (E, I, Key)
            and then (not Match_Value or else E.Vals (I) = Value)
          then
             Idx := I;
             Hit := True;
             exit;
          end if;
       end loop;
       if not Hit then
          return False;
       end if;
       for I in Idx + 1 .. E.N - 1 loop
          E.KL (I - 1) := E.KL (I);
          E.Keys (I - 1) := E.Keys (I);
          E.Vals (I - 1) := E.Vals (I);
       end loop;
       E.N := E.N - 1;
       if not Leaf_Encode (E, Node) then
          return False;
       end if;
       return Leaf_Store (NBlk, Node);
    end Leaf_Remove;

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
    --  Write-path helpers (m82e)
    ------------------------------------------------------------------

    --  Split "a/b/c" into parent path "a/b" and final component.
    procedure Split_Path (Path : String; Parent : out String;
                          Parent_Len : out Natural; Name : out String;
                          Name_Len : out Natural)
    is
       Slash : Natural := 0;
    begin
       Parent_Len := 0;
       Name_Len := 0;
       for I in Path'Range loop
          if Path (I) = '/' then
             Slash := I;
          end if;
       end loop;
       if Slash = 0 then
          Name_Len := Path'Length;
          Name (Name'First .. Name'First + Name_Len - 1) := Path;
       else
          Parent_Len := Slash - Path'First;
          Parent (Parent'First .. Parent'First + Parent_Len - 1) :=
            Path (Path'First .. Slash - 1);
          Name_Len := Path'Last - Slash;
          Name (Name'First .. Name'First + Name_Len - 1) :=
            Path (Slash + 1 .. Path'Last);
       end if;
    end Split_Path;

    --  Wall clock in BeFS inode format (seconds << 16); the fixed
    --  fixture epoch when the board has no ticking RTC.
    function Now_Time return U64 is
       Secs  : U64;
       Nanos : U64;
    begin
       Syscalls.Read_Clock (Secs, Nanos);
       if Secs = 0 then
          Secs := 1735689600;
       end if;
       return Interfaces.Shift_Left (Secs, 16);
    end Now_Time;

    --  Build a fresh inode block into Buf (layout = mkbefs.py
    --  inode()). Stream_Run/Size describe the data stream; Name
    --  becomes the small_data name pseudo-attribute.
    procedure Build_Inode (Buf : out Block_Buf; Block : U64;
                           Mode : U32; Parent : U64;
                           Stream_Run : Block_Run; Size : U64;
                           Name : String)
    is
       T : constant U64 := Now_Time;
    begin
       Buf := (others => 0);
       --  magic, inode_num, uid, gid, mode, flags
       for B in 0 .. 3 loop
          Buf (U64 (B)) :=
            U8 (Interfaces.Shift_Right (Inode_Magic, 8 * B)
                  and 16#FF#);
          Buf (20 + U64 (B)) :=
            U8 (Interfaces.Shift_Right (Mode, 8 * B) and 16#FF#);
          Buf (24 + U64 (B)) :=
            U8 (Interfaces.Shift_Right (Inode_In_Use, 8 * B)
                  and 16#FF#);
       end loop;
       Buf (4) := 0;  Buf (5) := 0;  Buf (6) := 0;  Buf (7) := 0;
       Buf (8) := U8 (Block and 16#FF#);
       Buf (9) := U8 (Interfaces.Shift_Right (Block, 8) and 16#FF#);
       Buf (10) := 1;  Buf (11) := 0;                 --  len 1
       for B in 0 .. 7 loop
          Buf (28 + U64 (B)) :=
            U8 (Interfaces.Shift_Right (T, 8 * B) and 16#FF#);
          Buf (36 + U64 (B)) :=
            U8 (Interfaces.Shift_Right (T, 8 * B) and 16#FF#);
          Buf (216 + U64 (B)) :=
            U8 (Interfaces.Shift_Right (T, 8 * B) and 16#FF#);
       end loop;
       --  parent run (ag 0, Parent, len 1)
       Buf (48) := U8 (Parent and 16#FF#);
       Buf (49) := U8 (Interfaces.Shift_Right (Parent, 8) and 16#FF#);
       Buf (50) := 1;
       --  inode_size at 64
       Buf (64) := 0;  Buf (65) := 4;  --  1024 LE
       --  data stream at 72: direct[0]
       Buf (76) := U8 (U64 (Stream_Run.Start) and 16#FF#);
       Buf (77) := U8 (Interfaces.Shift_Right
                         (U64 (Stream_Run.Start), 8) and 16#FF#);
       Buf (78) := U8 (U64 (Stream_Run.Length) and 16#FF#);
       Buf (79) := U8 (Interfaces.Shift_Right
                         (U64 (Stream_Run.Length), 8) and 16#FF#);
       --  max_direct_range at 168, size at 208
       declare
          Covered : constant U64 :=
            Interfaces.Shift_Left (U64 (Stream_Run.Length), 10);
       begin
          for B in 0 .. 7 loop
             Buf (168 + U64 (B)) :=
               U8 (Interfaces.Shift_Right (Covered, 8 * B) and 16#FF#);
             Buf (208 + U64 (B)) :=
               U8 (Interfaces.Shift_Right (Size, 8 * B) and 16#FF#);
          end loop;
       end;
       --  small_data at 232: name pseudo-attribute + terminator
       for B in 0 .. 3 loop
          Buf (232 + U64 (B)) :=
            U8 (Interfaces.Shift_Right (File_Name_Type, 8 * B)
                  and 16#FF#);
       end loop;
       Buf (236) := 1;  Buf (237) := 0;
       Buf (238) := U8 (U64 (Name'Length) and 16#FF#);
       Buf (239) := 0;
       Buf (240) := File_Name_Name;
       for K in 0 .. Name'Length - 1 loop
          Buf (244 + U64 (K)) :=
            U8 (Character'Pos (Name (Name'First + K)));
       end loop;
    end Build_Inode;

    --  Write Buf into block Num through cache + transaction.
    function Store_Block (Num : U64; Buf : Block_Buf) return Boolean
    is
       Slot : constant Natural := Get_Block (Num);
    begin
       if Slot = Cache_Slots then
          return False;
       end if;
       for I in Buf'Range loop
          Cache_Data (Slot, I) := Buf (I);
       end loop;
       Trans_Add (Slot);
       Put_Block (Slot);
       return True;
    end Store_Block;

    --  Name-index maintenance (no-op on volumes without one;
    --  index failures are logged, never fatal to the op).
    procedure Index_Add (Name : String; Inode_Block : U64) is
       NI : Inode_Info;
    begin
       if Name_Index /= 0
         and then Read_Inode (Name_Index, NI)
         and then not Leaf_Insert (NI, Name, Inode_Block)
       then
          Akernel_User.Console.Put_Line ("bfs: name index add failed");
       end if;
    end Index_Add;

    procedure Index_Remove (Name : String; Inode_Block : U64) is
       NI : Inode_Info;
    begin
       if Name_Index /= 0
         and then Read_Inode (Name_Index, NI)
       then
          Done : begin
             if not Leaf_Remove (NI, Name, Inode_Block,
                                 Match_Value => True)
             then
                null;  --  absent entry: best-effort removal
             end if;
          end Done;
       end if;
    end Index_Remove;

    --  Create an empty file or directory under Parent; the dirent
    --  and name-index entries are inserted. The caller checks
    --  Leaf_Can_Fit first so this cannot fail on tree space after
    --  allocating.
    function Create_Entry (Parent : Inode_Info; Name : String;
                           Is_Dir : Boolean; New_Block : out U64)
                           return Boolean
    is
       Ino    : U64;
       SBlk   : U64 := 0;
       Buf    : Block_Buf;
       Hdr    : Block_Buf;
       E      : Leaf_Entries;
       Node   : Block_Buf;
    begin
       New_Block := 0;
       if Name'Length = 0 or else Name'Length > Leaf_Key_Max then
          return False;
       end if;
       --  Inode block, then (dirs) the 2-block btree stream.
       if not Alloc (1, Ino) then
          return False;
       end if;
       if Is_Dir and then not Alloc (2, SBlk) then
          Free (Ino, 1);
          return False;
       end if;
       if Is_Dir then
          --  btree header (mkbefs btree_stream): magic, node_size,
          --  max_depth 1, BTREE_STRING, root at offset 1024.
          Hdr := (others => 0);
          for B in 0 .. 3 loop
             Hdr (U64 (B)) :=
               U8 (Interfaces.Shift_Right (Btree_Magic, 8 * B)
                     and 16#FF#);
          end loop;
          Hdr (4) := 0;  Hdr (5) := 4;   --  node_size 1024
          Hdr (8) := 1;                  --  max_depth 1
          --  data_type 0 = BTREE_STRING (already zero)
          Hdr (16) := 0;  Hdr (17) := 4;  --  root node ptr 1024
          for B in 0 .. 7 loop
             Hdr (24 + U64 (B)) := 16#FF#;  --  free list -1
          end loop;
          Hdr (32) := 0;  Hdr (33) := 8;  --  total size 2048
          E.N := 2;
          E.KL (0) := 1;  E.Keys (0) := (others => 0);
          E.Keys (0)(0) := U8 (Character'Pos ('.'));
          E.Vals (0) := Ino;
          E.KL (1) := 2;  E.Keys (1) := (others => 0);
          E.Keys (1)(0) := U8 (Character'Pos ('.'));
          E.Keys (1)(1) := U8 (Character'Pos ('.'));
          E.Vals (1) := Parent.Block;
          if not Leaf_Encode (E, Node)
            or else not Store_Block (SBlk, Hdr)
            or else not Store_Block (SBlk + 1, Node)
          then
             Free (Ino, 1);
             Free (SBlk, 2);
             return False;
          end if;
       end if;
       Build_Inode
         (Buf, Ino,
          (if Is_Dir then S_IFDIR or S_STR_INDEX or 8#755#
           else S_IFREG or 8#644#),
          Parent.Block,
          (AG => 0,
           Start => (if Is_Dir then U16 (SBlk) else 0),
           Length => (if Is_Dir then 2 else 0)),
          (if Is_Dir then 2 * Block_Size else 0), Name);
       if not Store_Block (Ino, Buf) then
          if Is_Dir then
             Free (SBlk, 2);
          end if;
          Free (Ino, 1);
          return False;
       end if;
       --  Dirent, then name index (duplicate keys allowed there).
       if not Leaf_Insert (Parent, Name, Ino) then
          if Is_Dir then
             Free (SBlk, 2);
          end if;
          Free (Ino, 1);
          return False;
       end if;
       Index_Add (Name, Ino);
       New_Block := Ino;
       return True;
    end Create_Entry;

    --  Free the inode's data stream blocks (direct runs only;
    --  indirect streams are never created by the write path).
    procedure Free_Stream (Info : Inode_Info) is
    begin
       for R of Info.Direct loop
          exit when R.Length = 0;
          Free (To_Block (R), U64 (R.Length));
       end loop;
    end Free_Stream;

    --  Zero the inode block (clears magic/flags) and free it.
    function Free_Inode (Info : Inode_Info) return Boolean is
       Blank : Block_Buf := (others => 0);
    begin
       if not Store_Block (Info.Block, Blank) then
          return False;
       end if;
       Free (Info.Block, 1);
       return True;
    end Free_Inode;

    --  Replace the small_data name pseudo-attribute (always the
    --  first entry) with New_Name; the rest of the region shifts.
    function Rename_Name_Attr (Info : Inode_Info; New_Name : String)
                               return Boolean
    is
       Slot : constant Natural := Get_Block (Info.Block);
       Old_Len : U64;
       New_Total : U64;
       Old_Total : U64;
       Tail_From : U64;
       Tail_Len : U64;
       Scan : U64;
       NL : U64;
       DL : U64;
    begin
       if Slot = Cache_Slots then
          return False;
       end if;
       if LE32 (Slot, 232) /= File_Name_Type
         or else LE16 (Slot, 236) /= 1
         or else Cache_Data (Slot, 240) /= File_Name_Name
       then
          Put_Block (Slot);  --  no name attr: nothing to maintain
          return True;
       end if;
       Old_Len := U64 (LE16 (Slot, 238));
       Old_Total := 8 + 1 + 3 + Old_Len + 1;
       New_Total := 8 + 1 + 3 + U64 (New_Name'Length) + 1;
       --  End of the small_data list = first zeroed header.
       Scan := 232 + Old_Total;
       while Scan + 8 <= Block_Size loop
          NL := U64 (LE16 (Slot, Scan + 4));
          DL := U64 (LE16 (Slot, Scan + 6));
          exit when NL = 0;
          Scan := Scan + 8 + NL + 3 + DL + 1;
       end loop;
       Tail_From := 232 + Old_Total;
       Tail_Len := Scan + 8 - Tail_From;  --  includes terminator
       if 232 + New_Total + Tail_Len > Block_Size then
          Put_Block (Slot);
          return False;
       end if;
       --  Shift the tail in place (mind the overlap direction).
       if New_Total > Old_Total then
          for I in reverse 0 .. Tail_Len - 1 loop
             Cache_Data (Slot, 232 + New_Total + I) :=
               Cache_Data (Slot, Tail_From + I);
          end loop;
       elsif New_Total < Old_Total then
          for I in 0 .. Tail_Len - 1 loop
             Cache_Data (Slot, 232 + New_Total + I) :=
               Cache_Data (Slot, Tail_From + I);
          end loop;
       end if;
       Put_LE16 (Slot, 238, U16 (New_Name'Length));
       for K in 0 .. New_Name'Length - 1 loop
          Cache_Data (Slot, 244 + U64 (K)) :=
            U8 (Character'Pos (New_Name (New_Name'First + K)));
       end loop;
       Trans_Add (Slot);
       Put_Block (Slot);
       return True;
    end Rename_Name_Attr;

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
            and then U64 (LE32 (Slot, 512 + 40)) = Block_Size;
          if Is_Mounted then
             AG_Shift    := U64 (LE32 (Slot, 512 + 76));
             Num_Blocks  := LE64 (Slot, 512 + 48);
             Used_Blocks := LE64 (Slot, 512 + 56);
             Log_Base    := To_Block (Run_At (Slot, 512 + 88));
             Log_Len     := U64 (Run_At (Slot, 512 + 88).Length);
             Log_Pos_Start := LE64 (Slot, 512 + 96);
             Log_Pos_End   := LE64 (Slot, 512 + 104);
             Root_Block  := To_Block (Run_At (Slot, 512 + 116));
             Index_Block := To_Block (Run_At (Slot, 512 + 124));
             Alloc_Hint  := 2 + Log_Len;
          end if;
          Put_Block (Slot);
       end;

      --  Crash recovery: a non-empty log is replayed (m82e), which
      --  also flips the superblock back to CLEN.
      if Is_Mounted and then Log_Pos_Start /= Log_Pos_End then
         Is_Mounted := Replay_Log;
         if Is_Mounted then
            Akernel_User.Console.Put_Line ("bfs: journal replayed");
         end if;
      end if;

      if Is_Mounted then
         declare
            Root : Inode_Info;
         begin
            Is_Mounted := Read_Inode (Root_Block, Root);
         end;
      end if;

      --  Name index inode (m82e keeps it in sync on mutations):
      --  the "name" entry of the indices root's tree.
      if Is_Mounted and then Index_Block /= 0 then
         declare
            Idx  : Inode_Info;
            It   : Tree_It;
            Name : String (1 .. 32);
            NLen : Natural;
            Blk  : U64;
            Ok   : Boolean;
         begin
            if Read_Inode (Index_Block, Idx) then
               Tree_Rewind (Idx, It, Ok);
               while Ok and then Tree_Next (It, Name, NLen, Blk) loop
                  if NLen = 4 and then Name (1 .. 4) = "name" then
                     Name_Index := Blk;
                     exit;
                  end if;
               end loop;
            end if;
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
    --  Write path (m82e): one journal transaction per op
    ------------------------------------------------------------------

    function Write (Path : String; Offset : U64; Buf : System.Address;
                    Len : in out U64) return U64
    is
       Info    : Inode_Info;
       Parent  : Inode_Info;
       Root    : Boolean;
       Created : Boolean := False;
       P_Path  : String (1 .. 32);
       P_Len   : Natural;
       P_Name  : String (1 .. 32);
       N_Len   : Natural;
       New_Ino : U64;
       End_Pos : U64;
       Allocated : U64;
       Need    : U64;
       St      : U64;
       Done    : U64 := 0;
       P       : U64;
       Covered : U64;
       In_Run  : U64;
       Block   : U64;
       Skip    : U64;
       Part    : U64;
       Found   : Boolean;
       Last_End : U64;
       Slot    : Natural;
    begin
       if not Is_Mounted then
          Len := 0;
          return Status_Not_Found;
       end if;
       if Lookup (Path, Info, Root) then
          if Root then
             Len := 0;
             return Status_Bad_Args;
          end if;
          if (Info.Mode and S_IFMT) /= S_IFREG then
             Len := 0;
             return Status_Bad_Args;
          end if;
       else
          --  Create in the resolved parent directory.
          Split_Path (Path, P_Path, P_Len, P_Name, N_Len);
          if N_Len = 0
            or else not Lookup (P_Path (1 .. P_Len), Parent, Root)
            or else (Parent.Mode and S_IFMT) /= S_IFDIR
          then
             Len := 0;
             return Status_Not_Found;
          end if;
          if Offset /= 0 then
             Len := 0;
             return Status_Out_Of_Range;
          end if;
          if not Leaf_Can_Fit (Parent, P_Name (1 .. N_Len))
            or else not Create_Entry (Parent, P_Name (1 .. N_Len),
                                      False, New_Ino)
            or else not Read_Inode (New_Ino, Info)
          then
             Trans_Abort;
             Len := 0;
             return Status_Bad_Args;
          end if;
          Created := True;
       end if;

       if Offset > Info.Size then
          --  fat32 parity: a just-created empty file stays.
          if Created then
            Ok : begin
               if not Trans_Commit then
                  Len := 0;
                  return Status_Bad_Args;
               end if;
            end Ok;
          end if;
          Len := 0;
          return Status_Out_Of_Range;
       end if;

       End_Pos := Offset + Len;

       --  Grow the direct runs until they cover End_Pos.
       Allocated := 0;
       for R of Info.Direct loop
          exit when R.Length = 0;
          Allocated := Allocated + U64 (R.Length) * Block_Size;
       end loop;
       while Allocated < End_Pos loop
          Need := (End_Pos - Allocated + Block_Size - 1) / Block_Size;
          --  Free direct slot (or merge into the last run)?
          Last_End := 0;
          Found := False;
          declare
             Cov : U64 := 0;
             Free_Idx : Natural := 0;
             Have_Free : Boolean := False;
          begin
             for I in Info.Direct'Range loop
                if Info.Direct (I).Length = 0 then
                   Free_Idx := I;
                   Have_Free := True;
                   exit;
                end if;
                Cov := Cov + U64 (Info.Direct (I).Length);
                Last_End := To_Block (Info.Direct (I))
                  + U64 (Info.Direct (I).Length);
             end loop;
             if not Alloc (Need, St) then
                if Created then
                   Commit_New : begin
                      if Trans_Commit then
                         null;
                      end if;
                   end Commit_New;
                else
                   Trans_Abort;
                end if;
                Len := 0;
                return Status_Bad_Args;  --  disk full
             end if;
             if Cov > 0 and then St = Last_End then
                --  Contiguous with the last run: merge.
                for I in reverse Info.Direct'Range loop
                   if Info.Direct (I).Length /= 0 then
                      Info.Direct (I).Length :=
                        Info.Direct (I).Length + U16 (Need);
                      exit;
                   end if;
                end loop;
             elsif Have_Free then
                Info.Direct (Free_Idx) :=
                  (AG => 0, Start => U16 (St), Length => U16 (Need));
             else
                --  12 runs used and not contiguous: m82e stops
                --  here (indirect streams are future work).
                Free (St, Need);
                if Created then
                   Commit_Ok : begin
                      if Trans_Commit then
                         null;
                      end if;
                   end Commit_Ok;
                else
                   Trans_Abort;
                end if;
                Len := 0;
                return Status_Bad_Args;
             end if;
             Allocated := Cov * Block_Size + Need * Block_Size;
          end;
       end loop;

       --  Copy the bytes block-wise (read-modify-write).
       while Done < Len loop
          P := Offset + Done;
          Found := False;
          Covered := 0;
          for R of Info.Direct loop
             exit when R.Length = 0;
             if P < Covered + U64 (R.Length) * Block_Size then
                In_Run := P - Covered;
                Skip := In_Run mod Block_Size;
                Part := U64'Min (Len - Done, Block_Size - Skip);
                Block := To_Block (R) + In_Run / Block_Size;
                Slot := Get_Block (Block);
                if Slot = Cache_Slots then
                   Trans_Abort;
                   Len := 0;
                   return Status_Bad_Args;
                end if;
                declare
                   Src : Byte_Array (0 .. Part - 1)
                     with Address => Buf + Storage_Offset (Done);
                begin
                   for I in 0 .. Part - 1 loop
                      Cache_Data (Slot, Skip + I) := Src (I);
                   end loop;
                end;
                Trans_Add (Slot);
                Put_Block (Slot);
                Done := Done + Part;
                Found := True;
                exit;
             end if;
             Covered := Covered + U64 (R.Length) * Block_Size;
          end loop;
          if not Found then
             Trans_Abort;
             Len := 0;
             return Status_Bad_Args;
          end if;
       end loop;

       --  Inode: runs, covered range, size, mtime.
       Slot := Get_Block (Info.Block);
       if Slot = Cache_Slots then
          Trans_Abort;
          Len := 0;
          return Status_Bad_Args;
       end if;
       for I in Info.Direct'Range loop
          Put_LE32 (Slot, 72 + U64 (I) * 8, Info.Direct (I).AG);
          Put_LE16 (Slot, 72 + U64 (I) * 8 + 4, Info.Direct (I).Start);
          Put_LE16 (Slot, 72 + U64 (I) * 8 + 6, Info.Direct (I).Length);
       end loop;
       Put_LE64 (Slot, 168, Allocated);
       if End_Pos > Info.Size then
          Put_LE64 (Slot, 208, End_Pos);
       end if;
       Put_LE64 (Slot, 36, Now_Time);
       Trans_Add (Slot);
       Put_Block (Slot);

       if not Trans_Commit then
          Len := 0;
          return Status_Bad_Args;
       end if;
       return Status_Ok;
    end Write;

    --  Shared teardown for Delete/Rmdir: dirent + name index out,
    --  stream blocks freed, inode zeroed and freed.
    function Remove_Entry (Parent : Inode_Info; Name : String;
                           Info : Inode_Info) return Boolean is
    begin
       if not Leaf_Remove (Parent, Name, Info.Block,
                           Match_Value => True)
       then
          return False;
       end if;
       Index_Remove (Name, Info.Block);
       Free_Stream (Info);
       return Free_Inode (Info);
    end Remove_Entry;

    function Delete (Path : String) return U64 is
       Info    : Inode_Info;
       Parent  : Inode_Info;
       Root    : Boolean;
       P_Path  : String (1 .. 32);
       P_Len   : Natural;
       P_Name  : String (1 .. 32);
       N_Len   : Natural;
    begin
       if not Is_Mounted or else not Lookup (Path, Info, Root)
         or else Root
       then
          return Status_Not_Found;
       end if;
       if (Info.Mode and S_IFMT) /= S_IFREG
         or else Info.Max_Indir > 0 or else Info.Max_Double > 0
       then
          return Status_Bad_Args;  --  dir: use rmdir; streams: n/a
       end if;
       Split_Path (Path, P_Path, P_Len, P_Name, N_Len);
       if N_Len = 0
         or else not Lookup (P_Path (1 .. P_Len), Parent, Root)
       then
          return Status_Not_Found;
       end if;
       if not Remove_Entry (Parent, P_Name (1 .. N_Len), Info) then
          Trans_Abort;
          return Status_Bad_Args;
       end if;
       if not Trans_Commit then
          return Status_Bad_Args;
       end if;
       return Status_Ok;
    end Delete;

    function Truncate (Path : String) return U64 is
       Info : Inode_Info;
       Root : Boolean;
       Slot : Natural;
    begin
       if not Is_Mounted or else not Lookup (Path, Info, Root)
         or else Root
       then
          return Status_Not_Found;
       end if;
       if (Info.Mode and S_IFMT) /= S_IFREG
         or else Info.Max_Indir > 0 or else Info.Max_Double > 0
       then
          return Status_Bad_Args;
       end if;
       Free_Stream (Info);
       Slot := Get_Block (Info.Block);
       if Slot = Cache_Slots then
          Trans_Abort;
          return Status_Bad_Args;
       end if;
       for I in 0 .. 11 loop
          Put_LE32 (Slot, 72 + U64 (I) * 8, 0);
          Put_LE16 (Slot, 72 + U64 (I) * 8 + 4, 0);
          Put_LE16 (Slot, 72 + U64 (I) * 8 + 6, 0);
       end loop;
       Put_LE64 (Slot, 168, 0);   --  max_direct_range
       Put_LE64 (Slot, 208, 0);   --  size
       Put_LE64 (Slot, 36, Now_Time);
       Trans_Add (Slot);
       Put_Block (Slot);
       if not Trans_Commit then
          return Status_Bad_Args;
       end if;
       return Status_Ok;
    end Truncate;

    function Mkdir (Path : String) return U64 is
       Info    : Inode_Info;
       Parent  : Inode_Info;
       Root    : Boolean;
       P_Path  : String (1 .. 32);
       P_Len   : Natural;
       P_Name  : String (1 .. 32);
       N_Len   : Natural;
       New_Ino : U64;
    begin
       if not Is_Mounted then
          return Status_Not_Found;
       end if;
       if Lookup (Path, Info, Root) then
          return Status_Bad_Args;  --  exists already
       end if;
       Split_Path (Path, P_Path, P_Len, P_Name, N_Len);
       if N_Len = 0
         or else not Lookup (P_Path (1 .. P_Len), Parent, Root)
         or else (Parent.Mode and S_IFMT) /= S_IFDIR
       then
          return Status_Not_Found;
       end if;
       if not Leaf_Can_Fit (Parent, P_Name (1 .. N_Len))
         or else not Create_Entry (Parent, P_Name (1 .. N_Len),
                                   True, New_Ino)
         or else not Trans_Commit
       then
          Trans_Abort;
          return Status_Bad_Args;
       end if;
       return Status_Ok;
    end Mkdir;

    function Rmdir (Path : String) return U64 is
       Info    : Inode_Info;
       Parent  : Inode_Info;
       Root    : Boolean;
       P_Path  : String (1 .. 32);
       P_Len   : Natural;
       P_Name  : String (1 .. 32);
       N_Len   : Natural;
       It      : Tree_It;
       E_Name  : String (1 .. 32);
       E_Len   : Natural;
       Block   : U64;
       Ok      : Boolean;
    begin
       if not Is_Mounted or else not Lookup (Path, Info, Root)
         or else Root
       then
          return Status_Not_Found;
       end if;
       if (Info.Mode and S_IFMT) /= S_IFDIR then
          return Status_Bad_Args;
       end if;
       --  Empty means: only "." and ".." in the tree.
       Tree_Rewind (Info, It, Ok);
       if not Ok then
          return Status_Bad_Args;
       end if;
       while Tree_Next (It, E_Name, E_Len, Block) loop
          if not (E_Len = 1 and then E_Name (1) = '.')
            and then not (E_Len = 2 and then E_Name (1 .. 2) = "..")
          then
             return Status_Bad_Args;  --  not empty
          end if;
       end loop;
       Split_Path (Path, P_Path, P_Len, P_Name, N_Len);
       if N_Len = 0
         or else not Lookup (P_Path (1 .. P_Len), Parent, Root)
       then
          return Status_Not_Found;
       end if;
       if not Remove_Entry (Parent, P_Name (1 .. N_Len), Info) then
          Trans_Abort;
          return Status_Bad_Args;
       end if;
       if not Trans_Commit then
          return Status_Bad_Args;
       end if;
       return Status_Ok;
    end Rmdir;

    function Rename (From, To : String) return U64 is
       Info     : Inode_Info;
       F_Parent : Inode_Info;
       T_Parent : Inode_Info;
       Root     : Boolean;
       F_Path   : String (1 .. 32);
       F_PL     : Natural;
       F_Name   : String (1 .. 32);
       F_NL     : Natural;
       T_Path   : String (1 .. 32);
       T_PL     : Natural;
       T_Name   : String (1 .. 32);
       T_NL     : Natural;
       Cur      : Inode_Info;
       Dotdot   : U64;
       Depth    : Natural := 0;
    begin
       if not Is_Mounted or else not Lookup (From, Info, Root)
         or else Root
       then
          return Status_Not_Found;
       end if;
       --  Target must not exist; its parent must.
       declare
          Junk  : Inode_Info;
          J_Root : Boolean;
       begin
          if Lookup (To, Junk, J_Root) then
             return Status_Bad_Args;
          end if;
       end;
       Split_Path (From, F_Path, F_PL, F_Name, F_NL);
       Split_Path (To, T_Path, T_PL, T_Name, T_NL);
       if F_NL = 0 or else T_NL = 0
         or else T_Name (1 .. T_NL) = "."
         or else T_Name (1 .. T_NL) = ".."
         or else not Lookup (F_Path (1 .. F_PL), F_Parent, Root)
         or else not Lookup (T_Path (1 .. T_PL), T_Parent, Root)
       then
          return Status_Not_Found;
       end if;

       --  A directory cannot move into its own subtree: walk the
       --  ".." chain from the target parent to the root.
       if (Info.Mode and S_IFMT) = S_IFDIR then
          Cur := T_Parent;
          while Depth < 32 loop
             if Cur.Block = Info.Block then
                return Status_Bad_Args;
             end if;
             exit when Cur.Block = Root_Block;
             if not Leaf_Find (Cur, "..", Dotdot)
               or else not Read_Inode (Dotdot, Cur)
             then
                exit;
             end if;
             Depth := Depth + 1;
          end loop;
       end if;

       if not Leaf_Can_Fit (T_Parent, T_Name (1 .. T_NL)) then
          return Status_Bad_Args;
       end if;

       --  Moved directory: point ".." at the new parent first.
       if (Info.Mode and S_IFMT) = S_IFDIR
         and then F_Parent.Block /= T_Parent.Block
       then
          if not Leaf_Remove (Info, "..", F_Parent.Block,
                              Match_Value => True)
            or else not Leaf_Insert (Info, "..", T_Parent.Block)
          then
             Trans_Abort;
             return Status_Bad_Args;
          end if;
       end if;

       if not Leaf_Remove (F_Parent, F_Name (1 .. F_NL), Info.Block,
                           Match_Value => True)
         or else not Leaf_Insert (T_Parent, T_Name (1 .. T_NL),
                                  Info.Block)
       then
          Trans_Abort;
          return Status_Bad_Args;
       end if;
       Index_Remove (F_Name (1 .. F_NL), Info.Block);
       Index_Add (T_Name (1 .. T_NL), Info.Block);
       if not Rename_Name_Attr (Info, T_Name (1 .. T_NL)) then
          Trans_Abort;
          return Status_Bad_Args;
       end if;
       if not Trans_Commit then
          return Status_Bad_Args;
       end if;
       return Status_Ok;
    end Rename;

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

end Bfs_Engine;
