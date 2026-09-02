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
with Akernel_User.Tables;
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

    --  size / last_modified indices (m82g): int64-keyed trees,
    --  kept in sync for regular files on create/write/truncate/
    --  delete. 0 when the volume lacks them.
    Size_Index   : U64 := 0;
    Mtime_Index  : U64 := 0;

    --  Block allocator state: net used_blocks change of the open
    --  transaction (folded into Used_Blocks at commit) and the
    --  first-fit scan hint.
    Used_Pending : U64 := 0;
    Alloc_Hint   : U64 := 514;

    --  Block cache: 16 slots of one block each. Writes always go
    --  through the journal transaction below: modify the slot,
    --  Trans_Add snapshots it, Trans_Commit does the WAL dance.
    Cache_Slots : constant := 24;
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

    --  Live queries (m82g): mutation ops capture subscriber
    --  transitions into a pending list; a successful commit
    --  delivers them (queue + doorbell), an abort drops them.
    --  Bodies live with the live-query section near the end.
    procedure Live_Deliver;
    procedure Live_Clear;

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
       Live_Clear;
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
          Live_Deliver;  --  no-op unless events are pending
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
       Live_Deliver;
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
       Mtime       : U64;   --  last_modified (secs << 16 format)
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
       Info.Mtime := LE64 (Slot, 36);
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

    --  small_data region of the inode: runs from offset 232 to the
    --  end of the inode block. Entry layout (tools/mkbefs.py,
    --  Haiku Inode::AddSmallData): le32 type, le16 name_size (no
    --  NUL), le16 data_size, name bytes, 3 pad bytes (NUL + 2),
    --  data bytes, 1 pad byte. A zeroed header (name_size = 0)
    --  ends the list.
    Small_Data_Off : constant U64 := 232;

    --  True when the small_data entry at Pos is the internal
    --  name pseudo-attribute (every named inode carries it first:
    --  type FILE_NAME_TYPE 'CSTR', name_size = 1, name byte
    --  0x13 = FILE_NAME_NAME, data = the file name).
    function Is_Name_Attr (Slot : Natural; Pos : U64; NLen : U64)
                           return Boolean is
      (NLen = 1 and then Cache_Data (Slot, Pos + 8) = File_Name_Name);

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

         --  Indirect range (Haiku FindBlockRun semantics): the
         --  indirect run covers Indirect.Length contiguous INDEX
         --  blocks, each holding Block_Size/8 VARIABLE-length
         --  block_runs; coverage accumulates from Max_Direct.
         --  (m82h fixes the m82c fixed-length misreading, never
         --  exercised by the fixture.)
         if not Found
           and then Info.Max_Indir > 0
           and then Info.Indirect.Length > 0
           and then P >= Info.Max_Direct
           and then P < Info.Max_Indir
         then
            declare
               Base      : U64 := Info.Max_Direct;
               RLen      : U64 := 0;
               RStart    : U64 := 0;
               Hit       : Boolean := False;
               Done_Runs : Boolean := False;
            begin
               for BI in 0 .. U64 (Info.Indirect.Length) - 1 loop
                  exit when Hit or else Done_Runs;
                  declare
                     Ind_Slot : constant Natural := Get_Block
                       (To_Block (Info.Indirect) + BI);
                  begin
                     if Ind_Slot = Cache_Slots then
                        return Done;
                     end if;
                     for J in 0 .. (Block_Size / 8) - 1 loop
                        declare
                           R : constant Block_Run :=
                             Run_At (Ind_Slot, J * 8);
                        begin
                           if R.Length = 0 then
                              Done_Runs := True;
                              exit;
                           end if;
                           RLen := U64 (R.Length) * Block_Size;
                           if P < Base + RLen then
                              RStart := To_Block (R);
                              Hit := True;
                              exit;
                           end if;
                           Base := Base + RLen;
                        end;
                     end loop;
                     Put_Block (Ind_Slot);
                  end;
               end loop;
               if Hit then
                  In_Run := P - Base;
                  Chunk := U64'Min (Len - Done, RLen - In_Run);
                  Block := RStart + In_Run / Block_Size;
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
               end if;
            end;
         end if;

         --  Double-indirect: not needed at fixture scale; bail out
         --  cleanly rather than misread (M82e work).
         exit when not Found;
      end loop;
      return Done;
   end Stream_Read;

    --  Physical block holding stream offset P, through the direct
    --  runs and the indirect array (Haiku variable-length
    --  semantics); U64'Last when uncovered.
    function Data_Block (Info : Inode_Info; P : U64) return U64
    is
       Covered : U64 := 0;
    begin
       for R of Info.Direct loop
          exit when R.Length = 0;
          if P < Covered + U64 (R.Length) * Block_Size then
             return To_Block (R) + (P - Covered) / Block_Size;
          end if;
          Covered := Covered + U64 (R.Length) * Block_Size;
       end loop;
       if Info.Max_Indir > 0
         and then Info.Indirect.Length > 0
         and then P >= Info.Max_Direct
         and then P < Info.Max_Indir
       then
          declare
             Base : U64 := Info.Max_Direct;
             Hit  : U64 := U64'Last;
             Done_Runs : Boolean := False;
          begin
             for BI in 0 .. U64 (Info.Indirect.Length) - 1 loop
                exit when Hit /= U64'Last or else Done_Runs;
                declare
                   Ind_Slot : constant Natural := Get_Block
                     (To_Block (Info.Indirect) + BI);
                begin
                   if Ind_Slot = Cache_Slots then
                      return U64'Last;
                   end if;
                   for J in 0 .. (Block_Size / 8) - 1 loop
                      declare
                         R : constant Block_Run :=
                           Run_At (Ind_Slot, J * 8);
                      begin
                         if R.Length = 0 then
                            Done_Runs := True;
                            exit;
                         end if;
                         if P < Base + U64 (R.Length) * Block_Size then
                            Hit := To_Block (R)
                              + (P - Base) / Block_Size;
                            exit;
                         end if;
                         Base := Base + U64 (R.Length) * Block_Size;
                      end;
                   end loop;
                   Put_Block (Ind_Slot);
                end;
             end loop;
             return Hit;
          end;
       end if;
       return U64'Last;
    end Data_Block;

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
    --  Multi-level btree mutation (m82h; m82e was single-leaf).
    --
    --  Node layout is shared between leaves and internal nodes:
    --  28-byte header (left/right/overflow links, key count and
    --  total key bytes), then keys, 8-aligned u16 key lengths and
    --  int64 values. Leaf values are inode blocks; internal node
    --  values are STREAM OFFSETS of child nodes. Internal entry
    --  (k_i, v_i) means: child v_i covers keys in [k_{i-1}, k_i);
    --  the overflow link is the rightmost child (keys >= k_last).
    --  Descent follows the first separator strictly greater than
    --  the target, else the overflow link. Splits move the lower
    --  half into a NEW LEFT node (Haiku's _SplitNode shape) and
    --  push the first key of the upper half to the parent (copied
    --  for leaves, dropped from the level for internal nodes). A
    --  full root allocates a new root one level up; max_depth is
    --  capped at 3 (loud Bad_Args beyond). Removed entries never
    --  free nodes (no merge, free-node list stays -1) — a
    --  documented small leak per delete-heavy tree.
    ------------------------------------------------------------------

    subtype Block_Buf is Byte_Array (0 .. Block_Size - 1);

    function Buf_LE16 (B : Block_Buf; Off : U64) return U64 is
      (U64 (B (Off)) + Interfaces.Shift_Left (U64 (B (Off + 1)), 8));

    function Buf_LE32 (B : Block_Buf; Off : U64) return U64 is
      (Buf_LE16 (B, Off)
         + Interfaces.Shift_Left (Buf_LE16 (B, Off + 2), 16));

    function Buf_LE64 (B : Block_Buf; Off : U64) return U64 is
       V : U64 := 0;
    begin
       for I in 0 .. 7 loop
          V := V or Interfaces.Shift_Left (U64 (B (Off + U64 (I))),
                                           8 * I);
       end loop;
       return V;
    end Buf_LE64;

    procedure Put_Buf_LE64 (B : in out Block_Buf; Off : U64; V : U64)
    is
    begin
       for I in 0 .. 7 loop
          B (Off + U64 (I)) :=
            U8 (Interfaces.Shift_Right (V, 8 * I) and 16#FF#);
       end loop;
    end Put_Buf_LE64;

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

    --  Decoded node: keys as raw bytes, sorted; duplicate keys
    --  allowed (the name index has one entry per same-named file).
    --  Leaf_Max caps entries per node (covers a physically full
    --  1024-byte node of int64 keys = 55 entries); scratch rows
    --  hold one extra entry for the split combine step.
    Leaf_Max     : constant := 64;
    Leaf_Key_Max : constant := 64;
    Scratch_Cap  : constant := Leaf_Max + 1;
    type Leaf_KL_Array   is array (0 .. Scratch_Cap - 1) of Natural;
    type Leaf_Key_Row    is array (U64 range 0 .. Leaf_Key_Max - 1)
       of U8;
    type Leaf_Keys_Array is array (0 .. Scratch_Cap - 1)
       of Leaf_Key_Row;
    type Leaf_Vals_Array is array (0 .. Scratch_Cap - 1) of U64;
    type Leaf_Entries is record
       N    : Natural := 0;
       KL   : Leaf_KL_Array := (others => 0);
       Keys : Leaf_Keys_Array := (others => (others => 0));
       Vals : Leaf_Vals_Array := (others => 0);
    end record;

    --  The record is ~5 KiB: package state, not stack (the 48 KiB
    --  process stack ceiling bit in m82g). The server is
    --  single-threaded and leaf ops never nest; split needs two
    --  (combined set + a half).
    Leaf_Scratch   : Leaf_Entries;
    Leaf_Scratch_B : Leaf_Entries;

    --  Search key: raw bytes plus a numeric flag (int64 index keys
    --  are 8-byte little-endian values compared numerically).
    type Search_Key is record
       Bytes   : Leaf_Key_Row := (others => 0);
       Len     : Natural := 0;
       Num     : U64 := 0;
       Numeric : Boolean := False;
    end record;

    function SK_Str (S : String) return Search_Key is
       K : Search_Key;
    begin
       K.Len := S'Length;
       for I in 0 .. S'Length - 1 loop
          K.Bytes (U64 (I)) := U8 (Character'Pos (S (S'First + I)));
       end loop;
       return K;
    end SK_Str;

    function SK_Int (V : U64) return Search_Key is
       K : Search_Key;
    begin
       K.Len := 8;
       K.Num := V;
       K.Numeric := True;
       for I in 0 .. 7 loop
          K.Bytes (U64 (I)) :=
            U8 (Interfaces.Shift_Right (V, 8 * I) and 16#FF#);
       end loop;
       return K;
    end SK_Int;

    function SK_Entry (E : Leaf_Entries; I : Natural; Numeric : Boolean)
                       return Search_Key is
       K : Search_Key;
    begin
       K.Len := E.KL (I);
       K.Bytes := E.Keys (I);
       K.Numeric := Numeric;
       if Numeric and then K.Len = 8 then
          for B in 0 .. 7 loop
             K.Num := K.Num or Interfaces.Shift_Left
               (U64 (E.Keys (I)(U64 (B))), 8 * B);
          end loop;
       end if;
       return K;
    end SK_Entry;

    --  Entry I's key as a little-endian int64 (KL must be 8).
    function Entry_Num (E : Leaf_Entries; I : Natural) return U64
    is
       V : U64 := 0;
    begin
       for K in 0 .. 7 loop
          V := V or Interfaces.Shift_Left
            (U64 (E.Keys (I)(U64 (K))), 8 * K);
       end loop;
       return V;
    end Entry_Num;

    --  Compare search key K against entry I's key: -1 / 0 / +1.
    --  String order is bytewise with shorter-is-less on equal
    --  prefix; numeric order is by value.
    function SK_Cmp (K : Search_Key; E : Leaf_Entries; I : Natural)
                     return Integer
    is
       L : constant Natural := Natural'Min (K.Len, E.KL (I));
    begin
       if K.Numeric then
          if E.KL (I) /= 8 then
             return 1;   --  malformed entry sorts first
          elsif K.Num < Entry_Num (E, I) then
             return -1;
          elsif K.Num > Entry_Num (E, I) then
             return 1;
          end if;
          return 0;
       end if;
       for J in 0 .. L - 1 loop
          if K.Bytes (U64 (J)) < E.Keys (I)(U64 (J)) then
             return -1;
          elsif K.Bytes (U64 (J)) > E.Keys (I)(U64 (J)) then
             return 1;
          end if;
       end loop;
       if K.Len < E.KL (I) then
          return -1;
       elsif K.Len > E.KL (I) then
          return 1;
       end if;
       return 0;
    end SK_Cmp;

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

    --  Would one more entry of Add_Len key bytes fit into E's
    --  node (byte budget + entry cap)?
    function Node_Fits (E : Leaf_Entries; Add_Len : Natural)
                        return Boolean
    is
       KT : U64 := U64 (Add_Len);
    begin
       if E.N = Leaf_Max then
          return False;
       end if;
       for I in 0 .. E.N - 1 loop
          KT := KT + U64 (E.KL (I));
       end loop;
       return ((28 + KT + 7) and not 7)
         + 10 * U64 (E.N + 1) <= Block_Size;
    end Node_Fits;

    --  Encoded size of entries Lo .. Hi - 1 as a node.
    function Entries_Bytes (C : Leaf_Entries; Lo, Hi : Natural)
                            return U64
    is
       KT : U64 := 0;
    begin
       for I in Lo .. Hi - 1 loop
          KT := KT + U64 (C.KL (I));
       end loop;
       return ((28 + KT + 7) and not 7) + 10 * U64 (Hi - Lo);
    end Entries_Bytes;

    --  Split point M for the combined entry set C: entries
    --  0 .. M - 1 go to the new left node, M .. C.N - 1 stay.
    --  Greedy half-node fill, verified; falls back to the first
    --  point where both halves encode. 0 = no legal split.
    function Split_Point (C : Leaf_Entries) return Natural is
       M : Natural := 1;
    begin
       while M < C.N - 1
         and then Entries_Bytes (C, 0, M) < Block_Size / 2
       loop
          M := M + 1;
       end loop;
       if M <= Leaf_Max and then C.N - M <= Leaf_Max
         and then Entries_Bytes (C, 0, M) <= Block_Size
         and then Entries_Bytes (C, M, C.N) <= Block_Size
       then
          return M;
       end if;
       for Try in 1 .. C.N - 1 loop
          if Try <= Leaf_Max and then C.N - Try <= Leaf_Max
            and then Entries_Bytes (C, 0, Try) <= Block_Size
            and then Entries_Bytes (C, Try, C.N) <= Block_Size
          then
             return Try;
          end if;
       end loop;
       return 0;
    end Split_Point;

    procedure Entry_Set (E : in out Leaf_Entries; I : Natural;
                         K : Search_Key; V : U64) is
    begin
       E.KL (I) := K.Len;
       E.Keys (I) := K.Bytes;
       E.Vals (I) := V;
    end Entry_Set;

    --  Shift entries Pos .. E.N - 1 one up and insert (K, V).
    --  Caller guarantees E.N < Scratch_Cap.
    procedure Entry_Insert_At (E : in out Leaf_Entries; Pos : Natural;
                               K : Search_Key; V : U64) is
    begin
       for I in reverse Pos + 1 .. E.N loop
          E.KL (I) := E.KL (I - 1);
          E.Keys (I) := E.Keys (I - 1);
          E.Vals (I) := E.Vals (I - 1);
       end loop;
       Entry_Set (E, Pos, K, V);
       E.N := E.N + 1;
    end Entry_Insert_At;

    --  Leaf_Encode resets the links to -1; restore them after.
    procedure Set_Links (Node : in out Block_Buf;
                         Left, Right, Overflow : U64) is
    begin
       Put_Buf_LE64 (Node, 0, Left);
       Put_Buf_LE64 (Node, 8, Right);
       Put_Buf_LE64 (Node, 16, Overflow);
    end Set_Links;

    --  Parsed btree header (stream offset 0).
    type Tree_Ctx is record
       Dir     : Inode_Info;
       Depth   : U64;   --  max_number_of_levels @8
       Root    : U64;   --  root node stream offset @16
       Total   : U64;   --  next free stream offset @32
       Hdr_Blk : U64;   --  physical block of the header
    end record;

    function Tree_Open (Dir : Inode_Info; Ctx : out Tree_Ctx)
                        return Boolean
    is
       Hdr : Block_Buf;
       Got : U64;
    begin
       Got := Stream_Read (Dir, 0, Hdr (Hdr'First)'Address, Block_Size);
       if Got /= Block_Size
         or else U32 (Buf_LE32 (Hdr, 0)) /= Btree_Magic
       then
          return False;
       end if;
       Ctx.Dir     := Dir;
       Ctx.Depth   := Buf_LE32 (Hdr, 8);
       Ctx.Root    := Buf_LE64 (Hdr, 16);
       Ctx.Total   := Buf_LE64 (Hdr, 32);
       Ctx.Hdr_Blk := Stream_Block (Dir, 0);
       return Ctx.Hdr_Blk /= U64'Last;
    end Tree_Open;

    --  Load the node at stream offset Off through the cache;
    --  Blk is its physical block.
    function Node_Load (Ctx : Tree_Ctx; Off : U64;
                        Node : out Block_Buf; Blk : out U64)
                        return Boolean
    is
    begin
       Blk := Stream_Block (Ctx.Dir, Off);
       if Blk = U64'Last then
          return False;
       end if;
       declare
          Slot : constant Natural := Get_Block (Blk);
       begin
          if Slot = Cache_Slots then
             Blk := U64'Last;
             return False;
          end if;
          for I in Node'Range loop
             Node (I) := Cache_Data (Slot, I);
          end loop;
          Put_Block (Slot);
       end;
       return True;
    end Node_Load;

    --  Write one header field (root pointer / total size / depth)
    --  through cache + transaction.
    function Hdr_Put64 (Ctx : Tree_Ctx; Off : U64; V : U64)
                        return Boolean
    is
       Slot : constant Natural := Get_Block (Ctx.Hdr_Blk);
    begin
       if Slot = Cache_Slots then
          return False;
       end if;
       Put_LE64 (Slot, Off, V);
       Trans_Add (Slot);
       Put_Block (Slot);
       return True;
    end Hdr_Put64;

    function Hdr_Put32 (Ctx : Tree_Ctx; Off : U64; V : U32)
                        return Boolean
    is
       Slot : constant Natural := Get_Block (Ctx.Hdr_Blk);
    begin
       if Slot = Cache_Slots then
          return False;
       end if;
       Put_LE32 (Slot, Off, V);
       Trans_Add (Slot);
       Put_Block (Slot);
       return True;
    end Hdr_Put32;

    --  Descent path from root to leaf: Path (0) is the root,
    --  Path (PLen - 1) the leaf. Idx records the separator index
    --  followed at internal levels (= entry count: overflow link).
    Path_Max : constant := 4;   --  depth cap 3: root + 2 + leaf
    type Path_Elem is record
       Off : U64 := 0;
       Idx : Natural := 0;
    end record;
    type Tree_Path is array (0 .. Path_Max - 1) of Path_Elem;

    --  Follow the first separator STRICTLY greater than K, else
    --  the overflow link (rightmost child), down to the leaf.
    procedure Tree_Descend (Ctx : Tree_Ctx; K : Search_Key;
                            Path : out Tree_Path; PLen : out Natural;
                            Leaf : out Block_Buf; Leaf_Blk : out U64;
                            Ok : out Boolean)
    is
       Off : U64 := Ctx.Root;
       E   : Leaf_Entries renames Leaf_Scratch;
       Idx : Natural;
    begin
       Ok := False;
       PLen := 0;
       Leaf_Blk := U64'Last;
       loop
          if PLen = Path_Max then
             return;   --  deeper than the cap: refuse
          end if;
          if not Node_Load (Ctx, Off, Leaf, Leaf_Blk) then
             return;
          end if;
          Path (PLen).Off := Off;
          Path (PLen).Idx := 0;
          PLen := PLen + 1;
          exit when Buf_LE64 (Leaf, 16) = Btree_Null;   --  leaf
          Leaf_Decode (Leaf, E);
          Idx := 0;
          while Idx < E.N and then SK_Cmp (K, E, Idx) >= 0 loop
             Idx := Idx + 1;
          end loop;
          Path (PLen - 1).Idx := Idx;
          Off := (if Idx < E.N then E.Vals (Idx)
                  else Buf_LE64 (Leaf, 16));
       end loop;
       Ok := True;
    end Tree_Descend;

    --  Allocate a fresh node at the stream's total_size, growing
    --  the stream (direct runs) by one block when full. Updates
    --  the header's total size; on growth the inode's runs,
    --  max_direct_range and size are patched. All changes join
    --  the open transaction.
    function Tree_Alloc_Node (Ctx : in out Tree_Ctx; Off : out U64;
                              Blk : out U64) return Boolean
    is
       Capacity  : U64 := 0;
       Last_End  : U64 := 0;
       Free_Idx  : Natural := 0;
       Have_Free : Boolean := False;
       St        : U64;
       Slot      : Natural;
    begin
       Off := 0;
       Blk := U64'Last;
       for I in Ctx.Dir.Direct'Range loop
          if Ctx.Dir.Direct (I).Length = 0 then
             Free_Idx := I;
             Have_Free := True;
             exit;
          end if;
          Capacity := Capacity
            + U64 (Ctx.Dir.Direct (I).Length) * Block_Size;
          Last_End := To_Block (Ctx.Dir.Direct (I))
            + U64 (Ctx.Dir.Direct (I).Length);
       end loop;
       if Ctx.Total + Block_Size > Capacity then
          if not Alloc (1, St) then
             return False;
          end if;
          if Capacity > 0 and then St = Last_End then
             --  Contiguous with the last run: merge.
             for I in reverse Ctx.Dir.Direct'Range loop
                if Ctx.Dir.Direct (I).Length /= 0 then
                   Ctx.Dir.Direct (I).Length :=
                     Ctx.Dir.Direct (I).Length + 1;
                   exit;
                end if;
             end loop;
          elsif Have_Free then
             Ctx.Dir.Direct (Free_Idx) :=
               (AG => 0, Start => U16 (St), Length => 1);
          else
             Free (St, 1);
             Akernel_User.Console.Put_Line
               ("bfs: tree stream out of runs");
             return False;
          end if;
          Slot := Get_Block (Ctx.Dir.Block);
          if Slot = Cache_Slots then
             return False;
          end if;
          for I in Ctx.Dir.Direct'Range loop
             if Ctx.Dir.Direct (I).Length /= 0 then
                Put_LE16 (Slot, 76 + 8 * U64 (I),
                          Ctx.Dir.Direct (I).Start);
                Put_LE16 (Slot, 78 + 8 * U64 (I),
                          Ctx.Dir.Direct (I).Length);
             end if;
          end loop;
          Put_LE64 (Slot, 168, Capacity + Block_Size);
          Put_LE64 (Slot, 208, Capacity + Block_Size);
          Trans_Add (Slot);
          Put_Block (Slot);
       end if;
       Off := Ctx.Total;
       Blk := Stream_Block (Ctx.Dir, Off);
       if Blk = U64'Last then
          return False;
       end if;
       Ctx.Total := Ctx.Total + Block_Size;
       return Hdr_Put64 (Ctx, 32, Ctx.Total);
    end Tree_Alloc_Node;

    --  Locate the leaf + entry index of key K (and Value when
    --  Match_Value). Duplicate keys can straddle a split boundary
    --  to the LEFT of the descended leaf (inserts always land in
    --  the rightmost leaf holding the key), so keep walking left
    --  while the left neighbour's last key still equals K.
    function Tree_Locate (Ctx : Tree_Ctx; K : Search_Key; Value : U64;
                          Match_Value : Boolean;
                          Buf : out Block_Buf; Blk : out U64;
                          Idx : out Natural) return Boolean
    is
       Path  : Tree_Path;
       PLen  : Natural;
       Ok    : Boolean;
       E     : Leaf_Entries renames Leaf_Scratch;
       Left  : U64;
       Steps : Natural := 0;
    begin
       Idx := 0;
       Tree_Descend (Ctx, K, Path, PLen, Buf, Blk, Ok);
       if not Ok then
          return False;
       end if;
       loop
          Leaf_Decode (Buf, E);
          for I in 0 .. E.N - 1 loop
             exit when SK_Cmp (K, E, I) < 0;   --  keys past K
             if SK_Cmp (K, E, I) = 0
               and then (not Match_Value or else E.Vals (I) = Value)
             then
                Idx := I;
                return True;
             end if;
          end loop;
          Left := Buf_LE64 (Buf, 0);
          exit when Left = Btree_Null;
          Steps := Steps + 1;
          exit when Steps > 40;   --  sanity bound (corrupt guard)
          declare
             PBuf : Block_Buf;
             PBlk : U64;
          begin
             if not Node_Load (Ctx, Left, PBuf, PBlk) then
                return False;
             end if;
             Leaf_Decode (PBuf, E);
             exit when E.N = 0
               or else SK_Cmp (K, E, E.N - 1) /= 0;
             Buf := PBuf;
             Blk := PBlk;
          end;
       end loop;
       return False;
    end Tree_Locate;

    --  Find the value of an entry whose key equals K.
    function Tree_Find (Dir : Inode_Info; K : Search_Key;
                        Value : out U64) return Boolean
    is
       Ctx : Tree_Ctx;
       Buf : Block_Buf;
       Blk : U64;
       Idx : Natural;
       E   : Leaf_Entries renames Leaf_Scratch;
    begin
       Value := 0;
       if not Tree_Open (Dir, Ctx)
         or else not Tree_Locate (Ctx, K, 0, False, Buf, Blk, Idx)
       then
          return False;
       end if;
       Leaf_Decode (Buf, E);
       Value := E.Vals (Idx);
       return True;
    end Tree_Find;

    --  Insert (K, Value) keeping sorted order (equal keys: after
    --  existing ones). Splits full nodes: the lower half moves to
    --  a fresh LEFT node, the first key of the upper half is
    --  pushed to the parent (copied for leaves, dropped from the
    --  level for internal nodes); a full root grows the tree one
    --  level. False on corrupt trees, disk full, a tree stream
    --  out of direct runs, or the depth cap (3).
    function Tree_Insert (Dir : Inode_Info; K : Search_Key;
                          Value : U64) return Boolean
    is
       Ctx     : Tree_Ctx;
       Path    : Tree_Path;
       PLen    : Natural;
       Ok      : Boolean;
       XBuf    : Block_Buf;   --  node being inserted into / split
       X_Blk   : U64;
       X_Off   : U64;
       NewBuf  : Block_Buf;   --  fresh left node on a split
       New_Off : U64;
       New_Blk : U64;
       E       : Leaf_Entries renames Leaf_Scratch;
       C       : Leaf_Entries renames Leaf_Scratch_B;
       Push    : Search_Key;
       Push_V  : U64;
       Sep     : Search_Key;
       Pos     : Natural;
       Level   : Integer;
       M       : Natural;
       Is_Leaf : Boolean;
       L_Link  : U64;
       R_Link  : U64;
       O_Link  : U64;
    begin
       if not Tree_Open (Dir, Ctx) then
          return False;
       end if;
       Tree_Descend (Ctx, K, Path, PLen, XBuf, X_Blk, Ok);
       if not Ok then
          return False;
       end if;
       X_Off := Path (PLen - 1).Off;
       Level := PLen - 1;
       Is_Leaf := True;
       Push := K;
       Push_V := Value;
       Leaf_Decode (XBuf, E);
       Pos := 0;
       while Pos < E.N and then SK_Cmp (Push, E, Pos) >= 0 loop
          Pos := Pos + 1;   --  duplicates go after existing keys
       end loop;
       loop
          if Node_Fits (E, Push.Len) then
             --  In-place insert; node links are preserved.
             L_Link := Buf_LE64 (XBuf, 0);
             R_Link := Buf_LE64 (XBuf, 8);
             O_Link := Buf_LE64 (XBuf, 16);
             Entry_Insert_At (E, Pos, Push, Push_V);
             if not Leaf_Encode (E, XBuf) then
                return False;
             end if;
             Set_Links (XBuf, L_Link, R_Link, O_Link);
             return Leaf_Store (X_Blk, XBuf);
          end if;
          --  Split: combined set = E plus the new entry at Pos.
          C := E;
          Entry_Insert_At (C, Pos, Push, Push_V);
          M := Split_Point (C);
          if M = 0 then
             Akernel_User.Console.Put_Line ("bfs: no legal tree split");
             return False;
          end if;
          if Level = 0 and then Ctx.Depth >= 3 then
             Akernel_User.Console.Put_Line ("bfs: tree depth cap hit");
             return False;
          end if;
          if not Tree_Alloc_Node (Ctx, New_Off, New_Blk) then
             return False;
          end if;
          L_Link := Buf_LE64 (XBuf, 0);
          R_Link := Buf_LE64 (XBuf, 8);
          O_Link := Buf_LE64 (XBuf, 16);
          --  Lower half -> E (goes into NewBuf).
          E.N := M;
          for I in 0 .. M - 1 loop
             E.KL (I) := C.KL (I);
             E.Keys (I) := C.Keys (I);
             E.Vals (I) := C.Vals (I);
          end loop;
          if Is_Leaf then
             --  Upper half stays in X (compact C down). The
             --  separator is its first key; it STAYS in the leaf
             --  and is only copied up.
             for I in M .. C.N - 1 loop
                C.KL (I - M) := C.KL (I);
                C.Keys (I - M) := C.Keys (I);
                C.Vals (I - M) := C.Vals (I);
             end loop;
             C.N := C.N - M;
             Sep := SK_Entry (C, 0, Push.Numeric);
             if not Leaf_Encode (E, NewBuf)
               or else not Leaf_Encode (C, XBuf)
             then
                return False;
             end if;
             Set_Links (NewBuf, L_Link, X_Off, Btree_Null);
             Set_Links (XBuf, New_Off, R_Link, O_Link);
             if not Leaf_Store (New_Blk, NewBuf)
               or else not Leaf_Store (X_Blk, XBuf)
             then
                return False;
             end if;
             --  The old left neighbour's right link moves to the
             --  new node.
             if L_Link /= Btree_Null then
                declare
                   NBuf : Block_Buf;
                   NBlk : U64;
                begin
                   if not Node_Load (Ctx, L_Link, NBuf, NBlk) then
                      return False;
                   end if;
                   Put_Buf_LE64 (NBuf, 8, New_Off);
                   if not Leaf_Store (NBlk, NBuf) then
                      return False;
                   end if;
                end;
             end if;
          else
             --  Internal split: entry M is DROPPED from the level
             --  and pushed up; its value becomes the left half's
             --  rightmost child (overflow link).
             Sep := SK_Entry (C, M, Push.Numeric);
             declare
                Lo_Ovfl : constant U64 := C.Vals (M);
             begin
                for I in M + 1 .. C.N - 1 loop
                   C.KL (I - M - 1) := C.KL (I);
                   C.Keys (I - M - 1) := C.Keys (I);
                   C.Vals (I - M - 1) := C.Vals (I);
                end loop;
                C.N := C.N - M - 1;
                if not Leaf_Encode (E, NewBuf)
                  or else not Leaf_Encode (C, XBuf)
                then
                   return False;
                end if;
                Set_Links (NewBuf, Btree_Null, Btree_Null, Lo_Ovfl);
                Set_Links (XBuf, Btree_Null, Btree_Null, O_Link);
             end;
             if not Leaf_Store (New_Blk, NewBuf)
               or else not Leaf_Store (X_Blk, XBuf)
             then
                return False;
             end if;
          end if;
          if Level = 0 then
             --  New root: one entry (separator -> left node),
             --  overflow link = the old root.
             declare
                Left_Off : constant U64 := New_Off;
             begin
                if not Tree_Alloc_Node (Ctx, New_Off, New_Blk) then
                   return False;
                end if;
                E.N := 1;
                Entry_Set (E, 0, Sep, Left_Off);
                if not Leaf_Encode (E, NewBuf) then
                   return False;
                end if;
                Set_Links (NewBuf, Btree_Null, Btree_Null, X_Off);
                if not Leaf_Store (New_Blk, NewBuf) then
                   return False;
                end if;
                return Hdr_Put64 (Ctx, 16, New_Off)
                  and then Hdr_Put32 (Ctx, 8, U32 (Ctx.Depth + 1));
             end;
          end if;
          --  Push the separator into the parent at the descent
          --  index; loop when the parent itself overflows.
          Level := Level - 1;
          X_Off := Path (Level).Off;
          if not Node_Load (Ctx, X_Off, XBuf, X_Blk) then
             return False;
          end if;
          Leaf_Decode (XBuf, E);
          Pos := Path (Level).Idx;
          Push := Sep;
          Push_V := New_Off;
          Is_Leaf := False;
       end loop;
    end Tree_Insert;

    --  Remove the entry matching K (and Value when Match_Value).
    --  No merge-on-remove: emptied nodes stay in the tree (their
    --  blocks are only reclaimed with the whole stream).
    function Tree_Remove (Dir : Inode_Info; K : Search_Key;
                          Value : U64; Match_Value : Boolean)
                          return Boolean
    is
       Ctx    : Tree_Ctx;
       Buf    : Block_Buf;
       Blk    : U64;
       Idx    : Natural;
       E      : Leaf_Entries renames Leaf_Scratch;
       L_Link : U64;
       R_Link : U64;
       O_Link : U64;
    begin
       if not Tree_Open (Dir, Ctx)
         or else not Tree_Locate (Ctx, K, Value, Match_Value,
                                  Buf, Blk, Idx)
       then
          return False;
       end if;
       L_Link := Buf_LE64 (Buf, 0);
       R_Link := Buf_LE64 (Buf, 8);
       O_Link := Buf_LE64 (Buf, 16);
       Leaf_Decode (Buf, E);
       for I in Idx + 1 .. E.N - 1 loop
          E.KL (I - 1) := E.KL (I);
          E.Keys (I - 1) := E.Keys (I);
          E.Vals (I - 1) := E.Vals (I);
       end loop;
       E.N := E.N - 1;
       if not Leaf_Encode (E, Buf) then
          return False;
       end if;
       Set_Links (Buf, L_Link, R_Link, O_Link);
       return Leaf_Store (Blk, Buf);
    end Tree_Remove;

    --  String/int wrappers: directory and name-index trees take
    --  raw name bytes; the size / last_modified indices (m82g)
    --  take int64 keys compared numerically.

    function Tree_Insert_Str (Dir : Inode_Info; Key : String;
                              Value : U64) return Boolean is
    begin
       if Key'Length = 0 or else Key'Length > Leaf_Key_Max then
          return False;
       end if;
       return Tree_Insert (Dir, SK_Str (Key), Value);
    end Tree_Insert_Str;

    function Tree_Insert_Int (Dir : Inode_Info; Key : U64;
                              Value : U64) return Boolean is
    begin
       return Tree_Insert (Dir, SK_Int (Key), Value);
    end Tree_Insert_Int;

    function Tree_Remove_Str (Dir : Inode_Info; Key : String;
                              Value : U64; Match_Value : Boolean)
                              return Boolean is
    begin
       if Key'Length = 0 or else Key'Length > Leaf_Key_Max then
          return False;
       end if;
       return Tree_Remove (Dir, SK_Str (Key), Value, Match_Value);
    end Tree_Remove_Str;

    function Tree_Remove_Int (Dir : Inode_Info; Key : U64;
                              Value : U64) return Boolean is
    begin
       return Tree_Remove (Dir, SK_Int (Key), Value, True);
    end Tree_Remove_Int;

    function Tree_Find_Str (Dir : Inode_Info; Key : String;
                            Value : out U64) return Boolean is
    begin
       if Key'Length = 0 or else Key'Length > Leaf_Key_Max then
          Value := 0;
          return False;
       end if;
       return Tree_Find (Dir, SK_Str (Key), Value);
    end Tree_Find_Str;

   ------------------------------------------------------------------
   --  Live queries (m82g): mutation ops diff per-subscription match
   --  bits before/after their change into a pending list; a
   --  successful Trans_Commit delivers it (queue + doorbell), an
   --  abort drops it (Live_Clear, forward-declared above). State
   --  and bodies live with the query section near the end.
   ------------------------------------------------------------------

    --  m80f: the subscription table is chunk-appended
    --  (Akernel_User.Tables); the before/after diff machinery
    --  passes match sets around BY VALUE, so it keeps a fixed
    --  64-wide bitset — Live_Width is now the (generous) policy
    --  cap on concurrent subscriptions, not a storage bound.
    --  The full-queue Ev_Resync stays as the queue-depth
    --  backstop regardless.
    Live_Width : constant := 64;   --  concurrent subscriptions

    type Pend_Bits is array (0 .. Live_Width - 1) of Boolean;
    No_Bits : constant Pend_Bits := (others => False);

    function Live_Eval (Name : String; Info : Inode_Info)
                        return Pend_Bits;
    procedure Live_Diff (Was, Now : Pend_Bits; Info : Inode_Info);

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
    --  becomes the small_data name pseudo-attribute; Time (secs
    --  << 16) stamps create/mtime so the caller can mirror the
    --  exact value into the last_modified index.
    procedure Build_Inode (Buf : out Block_Buf; Block : U64;
                           Mode : U32; Parent : U64;
                           Stream_Run : Block_Run; Size : U64;
                           Name : String; Time : U64)
    is
       T : constant U64 := Time;
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
         and then not Tree_Insert_Str (NI, Name, Inode_Block)
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
             if not Tree_Remove_Str (NI, Name, Inode_Block,
                                     Match_Value => True)
             then
                null;  --  absent entry: best-effort removal
             end if;
          end Done;
       end if;
    end Index_Remove;

    --  Numeric index maintenance (m82g): Index_Blk is the
    --  size/last_modified index inode (0 = absent). Same
    --  best-effort policy as the name index.
    procedure Index_Add_Num (Index_Blk : U64; Key : U64;
                             Inode_Block : U64) is
       II : Inode_Info;
    begin
       if Index_Blk /= 0
         and then Read_Inode (Index_Blk, II)
         and then not Tree_Insert_Int (II, Key, Inode_Block)
       then
          Akernel_User.Console.Put_Line ("bfs: numeric index add failed");
       end if;
    end Index_Add_Num;

    procedure Index_Remove_Num (Index_Blk : U64; Key : U64;
                                Inode_Block : U64) is
       II : Inode_Info;
    begin
       if Index_Blk /= 0
         and then Read_Inode (Index_Blk, II)
       then
          Done : begin
             if not Tree_Remove_Int (II, Key, Inode_Block) then
                null;  --  absent entry: best-effort removal
             end if;
          end Done;
       end if;
    end Index_Remove_Num;

    --  Create an empty file or directory under Parent; the dirent
    --  and name-index entries are inserted. Tree_Insert_Str
    --  splits full nodes, so a tree-space failure here means disk
    --  full / depth cap and rolls back the allocations.
    function Create_Entry (Parent : Inode_Info; Name : String;
                           Is_Dir : Boolean; New_Block : out U64)
                           return Boolean
    is
       Ino    : U64;
       SBlk   : U64 := 0;
       Buf    : Block_Buf;
       Hdr    : Block_Buf;
       E      : Leaf_Entries renames Leaf_Scratch;
       Node   : Block_Buf;
       C_Time : constant U64 := Now_Time;
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
          (if Is_Dir then 2 * Block_Size else 0), Name, C_Time);
       if not Store_Block (Ino, Buf) then
          if Is_Dir then
             Free (SBlk, 2);
          end if;
          Free (Ino, 1);
          return False;
       end if;
       --  Dirent, then name index (duplicate keys allowed there).
       if not Tree_Insert_Str (Parent, Name, Ino) then
          if Is_Dir then
             Free (SBlk, 2);
          end if;
          Free (Ino, 1);
          return False;
       end if;
       Index_Add (Name, Ino);
       if not Is_Dir then
          --  m82g: regular files join the size / last_modified
          --  indices at creation (size 0, create time).
          Index_Add_Num (Size_Index, 0, Ino);
          Index_Add_Num (Mtime_Index, C_Time, Ino);
       end if;
       New_Block := Ino;
       return True;
    end Create_Entry;

    --  Append the freshly allocated data run (St, Need blocks) to
    --  the inode's indirect array (m82h), allocating the first
    --  index block on demand. Merges with the last entry when
    --  contiguous. One index block (128 runs) is supported; a
    --  full array is a loud failure (double-indirect is out of
    --  scope). All changes join the open transaction.
    function Indirect_Append (Info : in out Inode_Info; St : U64;
                              Need : U64) return Boolean
    is
       Slot : Natural;
    begin
       if Info.Indirect.Length = 0 then
          --  First indirect run: one zeroed index block; coverage
          --  starts at the direct range end (absolute offset).
          declare
             IBlk : U64;
          begin
             if not Alloc (1, IBlk) then
                return False;
             end if;
             Info.Indirect := (AG => 0, Start => U16 (IBlk),
                               Length => 1);
             Info.Max_Indir := Info.Max_Direct;
             Slot := Get_Block (IBlk);
             if Slot = Cache_Slots then
                return False;
             end if;
             for I in 0 .. Block_Size - 1 loop
                Cache_Data (Slot, I) := 0;
             end loop;
             Trans_Add (Slot);
             Put_Block (Slot);
          end;
       end if;
       Slot := Get_Block (To_Block (Info.Indirect));
       if Slot = Cache_Slots then
          return False;
       end if;
       declare
          Free_Idx : U64 := U64'Last;
          Last_Run : Block_Run;
       begin
          for J in 0 .. (Block_Size / 8) - 1 loop
             declare
                R : constant Block_Run := Run_At (Slot, J * 8);
             begin
                if R.Length = 0 then
                   Free_Idx := J;
                   exit;
                end if;
                Last_Run := R;
             end;
          end loop;
          if Free_Idx = U64'Last then
             Put_Block (Slot);
             Akernel_User.Console.Put_Line ("bfs: indirect full");
             return False;
          end if;
          if Free_Idx > 0
            and then Last_Run.AG = 0
            and then To_Block (Last_Run) + U64 (Last_Run.Length) = St
          then
             Put_LE16 (Slot, (Free_Idx - 1) * 8 + 6,
                       Last_Run.Length + U16 (Need));
          else
             Put_LE32 (Slot, Free_Idx * 8, 0);
             Put_LE16 (Slot, Free_Idx * 8 + 4, U16 (St));
             Put_LE16 (Slot, Free_Idx * 8 + 6, U16 (Need));
          end if;
          Trans_Add (Slot);
          Put_Block (Slot);
       end;
       Info.Max_Indir := Info.Max_Indir + Need * Block_Size;
       return True;
    end Indirect_Append;

    --  Free the inode's data stream blocks: direct runs, the
    --  indirect array's data runs, and the index blocks
    --  themselves (m82h).
    procedure Free_Stream (Info : Inode_Info) is
    begin
       for R of Info.Direct loop
          exit when R.Length = 0;
          Free (To_Block (R), U64 (R.Length));
       end loop;
       if Info.Indirect.Length > 0 then
          for BI in 0 .. U64 (Info.Indirect.Length) - 1 loop
             declare
                Slot : constant Natural := Get_Block
                  (To_Block (Info.Indirect) + BI);
             begin
                if Slot = Cache_Slots then
                   return;   --  best effort; rest stays allocated
                end if;
                for J in 0 .. (Block_Size / 8) - 1 loop
                   declare
                      R : constant Block_Run := Run_At (Slot, J * 8);
                   begin
                      exit when R.Length = 0;
                      Free (To_Block (R), U64 (R.Length));
                   end;
                end loop;
                Put_Block (Slot);
             end;
          end loop;
          Free (To_Block (Info.Indirect), U64 (Info.Indirect.Length));
       end if;
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

       --  Index inodes (m82e/m82g keep them in sync on
       --  mutations): entries of the indices root's tree.
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
                   elsif NLen = 4 and then Name (1 .. 4) = "size" then
                      Size_Index := Blk;
                   elsif NLen = 13
                     and then Name (1 .. 13) = "last_modified"
                   then
                      Mtime_Index := Blk;
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
       Was     : Pend_Bits := No_Bits;
    begin
       if not Is_Mounted then
          Len := 0;
          return Status_Not_Found;
       end if;
       Split_Path (Path, P_Path, P_Len, P_Name, N_Len);
       if Lookup (Path, Info, Root) then
          if Root then
             Len := 0;
             return Status_Bad_Args;
          end if;
          if (Info.Mode and S_IFMT) /= S_IFREG then
             Len := 0;
             return Status_Bad_Args;
          end if;
          --  m82g: capture the pre-write match state.
          if N_Len /= 0 then
             Was := Live_Eval (P_Name (1 .. N_Len), Info);
          end if;
       else
          --  Create in the resolved parent directory.
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
          if not Create_Entry (Parent, P_Name (1 .. N_Len),
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
             Live_Diff (Was, Live_Eval (P_Name (1 .. N_Len), Info),
                        Info);
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

       --  Grow the stream until it covers End_Pos: direct runs
       --  first, the indirect array once they are full (m82h).
       Allocated := 0;
       for R of Info.Direct loop
          exit when R.Length = 0;
          Allocated := Allocated + U64 (R.Length) * Block_Size;
       end loop;
       Info.Max_Direct := Allocated;
       if Info.Max_Indir > Allocated then
          Allocated := Info.Max_Indir;
       end if;
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
                    Live_Diff (Was, Live_Eval (P_Name (1 .. N_Len),
                                               Info), Info);
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
             if Info.Indirect.Length = 0
               and then
                 ((Cov > 0 and then St = Last_End) or else Have_Free)
             then
                --  Still in the direct range: merge into the last
                --  run or take a free slot.
                if Cov > 0 and then St = Last_End then
                   for I in reverse Info.Direct'Range loop
                      if Info.Direct (I).Length /= 0 then
                         Info.Direct (I).Length :=
                           Info.Direct (I).Length + U16 (Need);
                         exit;
                      end if;
                   end loop;
                else
                   Info.Direct (Free_Idx) :=
                     (AG => 0, Start => U16 (St), Length => U16 (Need));
                end if;
                Info.Max_Direct :=
                  Cov * Block_Size + Need * Block_Size;
             else
                 --  Direct range full (or the indirect array is
                 --  already started — the direct range must stay
                 --  below it): append to the indirect array.
                 if not Indirect_Append (Info, St, Need) then
                    Free (St, Need);
                    if Created then
                       Live_Diff (Was, Live_Eval (P_Name (1 .. N_Len),
                                                  Info), Info);
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
             end if;
             Allocated := Allocated + Need * Block_Size;
          end;
       end loop;

       --  Copy the bytes block-wise (read-modify-write), through
       --  the direct and indirect ranges.
       while Done < Len loop
          P := Offset + Done;
          Block := Data_Block (Info, P);
          if Block = U64'Last then
             Trans_Abort;
             Len := 0;
             return Status_Bad_Args;
          end if;
          Skip := P mod Block_Size;
          Part := U64'Min (Len - Done, Block_Size - Skip);
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
       end loop;

       --  Inode: runs, covered range, size, mtime.
       Slot := Get_Block (Info.Block);
       if Slot = Cache_Slots then
          Trans_Abort;
          Len := 0;
          return Status_Bad_Args;
       end if;
       declare
          Old_Size  : constant U64 := Info.Size;
          Old_Mtime : constant U64 := Info.Mtime;
          New_Size  : constant U64 :=
            (if End_Pos > Info.Size then End_Pos else Info.Size);
          W_Time    : constant U64 := Now_Time;
       begin
          for I in Info.Direct'Range loop
             Put_LE32 (Slot, 72 + U64 (I) * 8, Info.Direct (I).AG);
             Put_LE16 (Slot, 72 + U64 (I) * 8 + 4, Info.Direct (I).Start);
             Put_LE16 (Slot, 72 + U64 (I) * 8 + 6, Info.Direct (I).Length);
          end loop;
          Put_LE64 (Slot, 168, Info.Max_Direct);
          --  m82h: indirect run + covered range.
          Put_LE32 (Slot, 176, Info.Indirect.AG);
          Put_LE16 (Slot, 180, Info.Indirect.Start);
          Put_LE16 (Slot, 182, Info.Indirect.Length);
          Put_LE64 (Slot, 184, Info.Max_Indir);
          if End_Pos > Info.Size then
             Put_LE64 (Slot, 208, End_Pos);
          end if;
          Put_LE64 (Slot, 36, W_Time);
          Trans_Add (Slot);
          Put_Block (Slot);

          --  m82g: keep the size / last_modified indices in sync
          --  (journaled with the data).
          if New_Size /= Old_Size then
             Index_Remove_Num (Size_Index, Old_Size, Info.Block);
             Index_Add_Num (Size_Index, New_Size, Info.Block);
          end if;
          Index_Remove_Num (Mtime_Index, Old_Mtime, Info.Block);
          Index_Add_Num (Mtime_Index, W_Time, Info.Block);
       end;

       --  m82g: diff against the post-write state (the overlay
       --  shows the grown size and fresh mtime).
       declare
          Cur : Inode_Info;
       begin
          if N_Len /= 0 and then Read_Inode (Info.Block, Cur) then
             Live_Diff (Was, Live_Eval (P_Name (1 .. N_Len), Cur),
                        Cur);
          end if;
       end;

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
       if not Tree_Remove_Str (Parent, Name, Info.Block,
                               Match_Value => True)
       then
          return False;
       end if;
       Index_Remove (Name, Info.Block);
       if (Info.Mode and S_IFMT) = S_IFREG then
          --  m82g: regular files leave the numeric indices.
          Index_Remove_Num (Size_Index, Info.Size, Info.Block);
          Index_Remove_Num (Mtime_Index, Info.Mtime, Info.Block);
       end if;
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
         or else Info.Max_Double > 0
       then
          return Status_Bad_Args;  --  dir: use rmdir; d-ind: n/a
       end if;
       Split_Path (Path, P_Path, P_Len, P_Name, N_Len);
       if N_Len = 0
         or else not Lookup (P_Path (1 .. P_Len), Parent, Root)
       then
          return Status_Not_Found;
       end if;
       --  m82g: capture the removal transition while the inode
       --  and its parent chain are still intact.
       Live_Diff (Live_Eval (P_Name (1 .. N_Len), Info), No_Bits,
                  Info);
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
       P_Path  : String (1 .. 32);
       P_Len   : Natural;
       P_Name  : String (1 .. 32);
       N_Len   : Natural := 0;
       Was     : Pend_Bits := No_Bits;
    begin
       if not Is_Mounted or else not Lookup (Path, Info, Root)
         or else Root
       then
          return Status_Not_Found;
       end if;
       if (Info.Mode and S_IFMT) /= S_IFREG
         or else Info.Max_Double > 0
       then
          return Status_Bad_Args;
       end if;
       --  m82g: capture the pre-truncate match state.
       Split_Path (Path, P_Path, P_Len, P_Name, N_Len);
       if N_Len /= 0 then
          Was := Live_Eval (P_Name (1 .. N_Len), Info);
       end if;
       Free_Stream (Info);
       Slot := Get_Block (Info.Block);
       if Slot = Cache_Slots then
          Trans_Abort;
          return Status_Bad_Args;
       end if;
       declare
          Old_Size  : constant U64 := Info.Size;
          Old_Mtime : constant U64 := Info.Mtime;
          T_Time    : constant U64 := Now_Time;
       begin
          for I in 0 .. 11 loop
             Put_LE32 (Slot, 72 + U64 (I) * 8, 0);
             Put_LE16 (Slot, 72 + U64 (I) * 8 + 4, 0);
             Put_LE16 (Slot, 72 + U64 (I) * 8 + 6, 0);
          end loop;
          Put_LE64 (Slot, 168, 0);   --  max_direct_range
          Put_LE64 (Slot, 176, 0);   --  indirect run (m82h)
          Put_LE64 (Slot, 184, 0);   --  max_indirect_range
          Put_LE64 (Slot, 208, 0);   --  size
          Put_LE64 (Slot, 36, T_Time);
          Trans_Add (Slot);
          Put_Block (Slot);

          --  m82g: size / last_modified index sync.
          if Old_Size /= 0 then
             Index_Remove_Num (Size_Index, Old_Size, Info.Block);
             Index_Add_Num (Size_Index, 0, Info.Block);
          end if;
          Index_Remove_Num (Mtime_Index, Old_Mtime, Info.Block);
          Index_Add_Num (Mtime_Index, T_Time, Info.Block);
       end;
       --  m82g: diff against the post-truncate state (the overlay
       --  shows the zeroed size and fresh mtime).
       declare
          Cur : Inode_Info;
       begin
          if N_Len /= 0 and then Read_Inode (Info.Block, Cur) then
             Live_Diff (Was, Live_Eval (P_Name (1 .. N_Len), Cur),
                        Cur);
          end if;
       end;
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
       if not Create_Entry (Parent, P_Name (1 .. N_Len),
                            True, New_Ino)
       then
          Trans_Abort;
          return Status_Bad_Args;
       end if;
       --  m82g: the new directory enters matching result sets.
       declare
          NInfo : Inode_Info;
       begin
          if Read_Inode (New_Ino, NInfo) then
             Live_Diff (No_Bits,
                        Live_Eval (P_Name (1 .. N_Len), NInfo),
                        NInfo);
          end if;
       end;
       if not Trans_Commit then
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
       --  m82g: removal transition (see Delete).
       Live_Diff (Live_Eval (P_Name (1 .. N_Len), Info), No_Bits,
                  Info);
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
       Was      : Pend_Bits := No_Bits;
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
             if not Tree_Find_Str (Cur, "..", Dotdot)
               or else not Read_Inode (Dotdot, Cur)
             then
                exit;
             end if;
             Depth := Depth + 1;
          end loop;
       end if;

       --  m82g: capture the removal transition while the old name
       --  and parent chain are still in place.
       Was := Live_Eval (F_Name (1 .. F_NL), Info);
       Live_Diff (Was, No_Bits, Info);

       --  Moved directory: point ".." at the new parent first.
       if (Info.Mode and S_IFMT) = S_IFDIR
         and then F_Parent.Block /= T_Parent.Block
       then
          if not Tree_Remove_Str (Info, "..", F_Parent.Block,
                                  Match_Value => True)
            or else not Tree_Insert_Str (Info, "..", T_Parent.Block)
          then
             Trans_Abort;
             return Status_Bad_Args;
          end if;
       end if;

       if not Tree_Remove_Str (F_Parent, F_Name (1 .. F_NL),
                               Info.Block, Match_Value => True)
         or else not Tree_Insert_Str (T_Parent, T_Name (1 .. T_NL),
                                      Info.Block)
       then
          Trans_Abort;
          return Status_Bad_Args;
       end if;
       Index_Remove (F_Name (1 .. F_NL), Info.Block);
       Index_Add (T_Name (1 .. T_NL), Info.Block);
       --  Keep the inode parent run in sync on cross-directory
       --  moves (query path materialization walks it).
       if F_Parent.Block /= T_Parent.Block then
          declare
             P_Slot : constant Natural := Get_Block (Info.Block);
          begin
             if P_Slot = Cache_Slots then
                Trans_Abort;
                return Status_Bad_Args;
             end if;
             Put_LE16 (P_Slot, 48, U16 (T_Parent.Block));
             Trans_Add (P_Slot);
             Put_Block (P_Slot);
          end;
       end if;
       if not Rename_Name_Attr (Info, T_Name (1 .. T_NL)) then
          Trans_Abort;
          return Status_Bad_Args;
       end if;
       --  m82g: the entry joins matching sets under its new name.
       declare
          NInfo : Inode_Info;
       begin
          if Read_Inode (Info.Block, NInfo) then
             Live_Diff (No_Bits,
                        Live_Eval (T_Name (1 .. T_NL), NInfo),
                        NInfo);
          end if;
       end;
       if not Trans_Commit then
          return Status_Bad_Args;
       end if;
       return Status_Ok;
    end Rename;

    ------------------------------------------------------------------
    --  One-shot queries (m82f)
    --
    --  Predicate grammar (recursive descent; Haiku QueryParser
    --  subset):
    --    expr  := or_expr
    --    or    := and_expr ('||' and_expr)*
    --    and   := unary ('&&' unary)*
    --    unary := '!' unary | '(' expr ')' | term
    --    term  := IDENT (=='|'!='|'<'|'<='|'>'|'>=') VALUE
    --  IDENT = [A-Za-z0-9_:.]+, VALUE = "quoted string" (escapes
    --  \" and \\) or unsigned decimal integer. Built-in terms:
    --  "name" (glob match on the entry name), "size" (int64 vs
    --  file size), "last_modified" (int64 SECONDS since epoch,
    --  compared against mtime >> 16 — Haiku's shifted-index
    --  special case does not apply to us). Any other IDENT reads
    --  the inode's small_data attribute of that name: string
    --  predicates glob-match the data bytes, numeric predicates
    --  compare 4/8-byte LE data as an integer.
    --
    --  Enumeration is index-driven: the NAME index contains every
    --  named entry on the volume, so its leaf chain is the match
    --  stream; the full predicate filters per inode. Result paths
    --  are materialized by walking the parent chain (inode+44)
    --  collecting small_data name attributes up to the root.
    --  Stateless: each call re-evaluates and returns the Index-th
    --  match.
    ------------------------------------------------------------------

    Pred_Max : constant := 255;   --  predicate length cap
    Pred_Buf : String (1 .. Pred_Max);
    Pred_Len : Natural := 0;
    Pred_Pos : Natural := 1;
    Pred_Ok  : Boolean := False;

    type Cmp_Op is (C_Eq, C_Ne, C_Lt, C_Le, C_Gt, C_Ge);
    type Node_Kind is (N_Term, N_And, N_Or, N_Not);

    Pred_Node_Max : constant := 24;
    type Pred_Node is record
       Kind   : Node_Kind := N_Term;
       Left   : Natural := 0;   --  1-based index, 0 = none
       Right  : Natural := 0;
       Attr   : String (1 .. 24) := (others => ' ');
       Attr_L : Natural := 0;
       Cmp    : Cmp_Op := C_Eq;
       Is_Num : Boolean := False;
       Num    : U64 := 0;
       Str    : String (1 .. 48) := (others => ' ');
       Str_L  : Natural := 0;
    end record;
    type Pred_Node_Store is array (1 .. Pred_Node_Max) of Pred_Node;
    type Pred_Store_Access is access constant Pred_Node_Store;
    Pred_Nodes : aliased Pred_Node_Store;
    Pred_Count : Natural := 0;

    procedure Pred_Skip_Ws is
    begin
       while Pred_Pos <= Pred_Len
         and then (Pred_Buf (Pred_Pos) = ' '
                   or else Pred_Buf (Pred_Pos) = Character'Val (9))
       loop
          Pred_Pos := Pred_Pos + 1;
       end loop;
    end Pred_Skip_Ws;

    --  Allocate an AST node; 0 on overflow. The record is reset
    --  to defaults: nodes are package state reused across calls.
    function Pred_New (Kind : Node_Kind) return Natural is
    begin
       if Pred_Count = Pred_Node_Max then
          Pred_Ok := False;
          return 0;
       end if;
       Pred_Count := Pred_Count + 1;
       Pred_Nodes (Pred_Count) := (Kind => Kind, others => <>);
       return Pred_Count;
    end Pred_New;

    function Parse_Or return Natural;

    function Parse_Term return Natural is
       N    : Natural;
       Ch   : Character;
       Dig  : U64;
    begin
       Pred_Skip_Ws;
       N := Pred_New (N_Term);
       if N = 0 then
          return 0;
       end if;
       --  IDENT
       while Pred_Pos <= Pred_Len loop
          Ch := Pred_Buf (Pred_Pos);
          exit when not (Ch in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9'
                         | '_' | ':' | '.');
          exit when Pred_Nodes (N).Attr_L = 24;
          Pred_Nodes (N).Attr_L := Pred_Nodes (N).Attr_L + 1;
          Pred_Nodes (N).Attr (Pred_Nodes (N).Attr_L) := Ch;
          Pred_Pos := Pred_Pos + 1;
       end loop;
       if Pred_Nodes (N).Attr_L = 0 then
          Pred_Ok := False;
          return 0;
       end if;
       --  operator
       Pred_Skip_Ws;
       if Pred_Pos > Pred_Len then
          Pred_Ok := False;
          return 0;
       end if;
       Ch := Pred_Buf (Pred_Pos);
       if Ch = '=' then
          Pred_Pos := Pred_Pos + 1;
          if Pred_Pos <= Pred_Len and then Pred_Buf (Pred_Pos) = '='
          then
             Pred_Pos := Pred_Pos + 1;
             Pred_Nodes (N).Cmp := C_Eq;
          else
             Pred_Ok := False;
             return 0;
          end if;
       elsif Ch = '!' then
          Pred_Pos := Pred_Pos + 1;
          if Pred_Pos <= Pred_Len and then Pred_Buf (Pred_Pos) = '='
          then
             Pred_Pos := Pred_Pos + 1;
             Pred_Nodes (N).Cmp := C_Ne;
          else
             Pred_Ok := False;
             return 0;
          end if;
       elsif Ch = '<' or else Ch = '>' then
          Pred_Pos := Pred_Pos + 1;
          if Pred_Pos <= Pred_Len and then Pred_Buf (Pred_Pos) = '='
          then
             Pred_Pos := Pred_Pos + 1;
             Pred_Nodes (N).Cmp := (if Ch = '<' then C_Le else C_Ge);
          else
             Pred_Nodes (N).Cmp := (if Ch = '<' then C_Lt else C_Gt);
          end if;
       else
          Pred_Ok := False;
          return 0;
       end if;
       --  value: "string" or decimal integer
       Pred_Skip_Ws;
       if Pred_Pos > Pred_Len then
          Pred_Ok := False;
          return 0;
       end if;
       if Pred_Buf (Pred_Pos) = '"' then
          Pred_Pos := Pred_Pos + 1;
          Value_Loop : loop
             if Pred_Pos > Pred_Len then
                Pred_Ok := False;  --  unterminated string
                return 0;
             end if;
            Ch := Pred_Buf (Pred_Pos);
             exit Value_Loop when Ch = '"';
             if Ch = '\' then
                Pred_Pos := Pred_Pos + 1;
                if Pred_Pos > Pred_Len then
                   Pred_Ok := False;  --  escape at end of input
                   return 0;
                end if;
                Ch := Pred_Buf (Pred_Pos);
                if Ch /= '\' and then Ch /= '"' then
                   Pred_Ok := False;  --  unknown escape
                   return 0;
                end if;
             end if;
             if Pred_Nodes (N).Str_L = 48 then
                Pred_Ok := False;
                return 0;
             end if;
             Pred_Nodes (N).Str_L := Pred_Nodes (N).Str_L + 1;
             Pred_Nodes (N).Str (Pred_Nodes (N).Str_L) := Ch;
             Pred_Pos := Pred_Pos + 1;
          end loop Value_Loop;
          Pred_Pos := Pred_Pos + 1;  --  closing quote
          Pred_Nodes (N).Is_Num := False;
       else
          Dig := 0;
          if Pred_Pos > Pred_Len
            or else Pred_Buf (Pred_Pos) not in '0' .. '9'
          then
             Pred_Ok := False;
             return 0;
          end if;
          while Pred_Pos <= Pred_Len
            and then Pred_Buf (Pred_Pos) in '0' .. '9'
          loop
             Dig := Dig * 10
               + U64 (Character'Pos (Pred_Buf (Pred_Pos))
                        - Character'Pos ('0'));
             Pred_Pos := Pred_Pos + 1;
          end loop;
          Pred_Nodes (N).Is_Num := True;
          Pred_Nodes (N).Num := Dig;
       end if;
       return N;
    end Parse_Term;

    function Parse_Unary return Natural is
       N   : Natural;
       Sub : Natural;
    begin
       Pred_Skip_Ws;
       if Pred_Pos <= Pred_Len and then Pred_Buf (Pred_Pos) = '!'
       then
          Pred_Pos := Pred_Pos + 1;
          Sub := Parse_Unary;
          if Sub = 0 then
             return 0;
          end if;
          N := Pred_New (N_Not);
          if N = 0 then
             return 0;
          end if;
          Pred_Nodes (N).Left := Sub;
          return N;
       elsif Pred_Pos <= Pred_Len and then Pred_Buf (Pred_Pos) = '('
       then
          Pred_Pos := Pred_Pos + 1;
          N := Parse_Or;
          Pred_Skip_Ws;
          if N = 0 or else Pred_Pos > Pred_Len
            or else Pred_Buf (Pred_Pos) /= ')'
          then
             Pred_Ok := False;
             return 0;
          end if;
          Pred_Pos := Pred_Pos + 1;
          return N;
       else
          return Parse_Term;
       end if;
    end Parse_Unary;

    function Parse_And return Natural is
       L   : Natural;
       R   : Natural;
       N   : Natural;
    begin
       L := Parse_Unary;
       loop
          Pred_Skip_Ws;
          exit when L = 0
            or else Pred_Pos + 1 > Pred_Len
            or else Pred_Buf (Pred_Pos) /= '&'
            or else Pred_Buf (Pred_Pos + 1) /= '&';
          Pred_Pos := Pred_Pos + 2;
          R := Parse_Unary;
          if R = 0 then
             return 0;
          end if;
          N := Pred_New (N_And);
          if N = 0 then
             return 0;
          end if;
          Pred_Nodes (N).Left := L;
          Pred_Nodes (N).Right := R;
          L := N;
       end loop;
       return L;
    end Parse_And;

    function Parse_Or return Natural is
       L   : Natural;
       R   : Natural;
       N   : Natural;
    begin
       L := Parse_And;
       loop
          Pred_Skip_Ws;
          exit when L = 0
            or else Pred_Pos + 1 > Pred_Len
            or else Pred_Buf (Pred_Pos) /= '|'
            or else Pred_Buf (Pred_Pos + 1) /= '|';
          Pred_Pos := Pred_Pos + 2;
          R := Parse_And;
          if R = 0 then
             return 0;
          end if;
          N := Pred_New (N_Or);
          if N = 0 then
             return 0;
          end if;
          Pred_Nodes (N).Left := L;
          Pred_Nodes (N).Right := R;
          L := N;
       end loop;
       return L;
    end Parse_Or;

    --  Glob match: '*' any run, '?' any single char.
    function Glob_Match (P : String; S : String) return Boolean is
    begin
       if P'Length = 0 then
          return S'Length = 0;
       end if;
       if P (P'First) = '*' then
          for K in 0 .. S'Length loop
             if Glob_Match
               (P (P'First + 1 .. P'Last),
                S (S'First + K .. S'Last))
             then
                return True;
             end if;
          end loop;
          return False;
       end if;
       if S'Length = 0 then
          return False;
       end if;
       if P (P'First) = '?' or else P (P'First) = S (S'First) then
          return Glob_Match
            (P (P'First + 1 .. P'Last), S (S'First + 1 .. S'Last));
       end if;
       return False;
    end Glob_Match;

    function Cmp_Apply (Op : Cmp_Op; A : U64; B : U64) return Boolean is
      (case Op is
          when C_Eq => A = B,
          when C_Ne => A /= B,
          when C_Lt => A < B,
          when C_Le => A <= B,
          when C_Gt => A > B,
          when C_Ge => A >= B);

    --  Evaluate a term against the entry (name + inode).
    function Eval_Term (N : Pred_Node; Name : String;
                        Info : Inode_Info) return Boolean
    is
    begin
       if N.Attr_L = 4 and then N.Attr (1 .. 4) = "name" then
          return not N.Is_Num
            and then Glob_Match (N.Str (1 .. N.Str_L), Name);
       elsif N.Attr_L = 4 and then N.Attr (1 .. 4) = "size" then
          return N.Is_Num and then Cmp_Apply (N.Cmp, Info.Size, N.Num);
       elsif N.Attr_L = 13
         and then N.Attr (1 .. 13) = "last_modified"
       then
          return N.Is_Num
            and then Cmp_Apply
              (N.Cmp, Interfaces.Shift_Right (Info.Mtime, 16), N.Num);
       end if;
       --  Arbitrary small_data attribute term.
       declare
          Slot : constant Natural := Get_Block (Info.Block);
          Pos  : U64;
          NLen : U64;
          DLen : U64;
          Hit  : Boolean := False;
          Result : Boolean := False;
       begin
          if Slot = Cache_Slots then
             return False;
          end if;
          Pos := Small_Data_Off;
          while Pos + 8 <= Block_Size loop
             NLen := U64 (LE16 (Slot, Pos + 4));
             DLen := U64 (LE16 (Slot, Pos + 6));
             exit when NLen = 0;
             exit when Pos + 8 + NLen + 3 + DLen + 1 > Block_Size;
             if not Is_Name_Attr (Slot, Pos, NLen)
               and then NLen = U64 (N.Attr_L)
             then
                Hit := True;
                for I in 0 .. NLen - 1 loop
                   if Cache_Data (Slot, Pos + 8 + I) /=
                     U8 (Character'Pos (N.Attr (Natural (I) + 1)))
                   then
                      Hit := False;
                      exit;
                   end if;
                end loop;
                if Hit then
                   if N.Is_Num then
                      if DLen = 8 then
                         Result := Cmp_Apply (N.Cmp,
                                              LE64 (Slot, Pos + 8
                                                      + NLen + 3),
                                              N.Num);
                      elsif DLen = 4 then
                         Result := Cmp_Apply (N.Cmp,
                                              U64 (LE32 (Slot, Pos + 8
                                                           + NLen + 3)),
                                              N.Num);
                      end if;
                   elsif DLen <= 64 then
                      declare
                         S : String (1 .. 64);
                      begin
                         for I in 0 .. DLen - 1 loop
                            S (Natural (I) + 1) := Character'Val
                              (Natural (Cache_Data
                                 (Slot, Pos + 8 + NLen + 3 + I)));
                         end loop;
                         Result := Glob_Match
                           (N.Str (1 .. N.Str_L),
                            S (1 .. Natural (DLen)));
                      end;
                   end if;
                   exit;
                end if;
             end if;
             Pos := Pos + 8 + NLen + 3 + DLen + 1;
          end loop;
          Put_Block (Slot);
          return Result;
       end;
    end Eval_Term;

    --  Nodes is the parsed AST: the one-shot parser state for
    --  Query, the subscription's snapshot for live events. Passed
    --  by access: the store is ~2.5 KiB and Eval_Node recurses,
    --  a by-value parameter would blow the 48 KiB process stack.
    function Eval_Node (Nodes : Pred_Store_Access; N : Natural;
                        Name : String; Info : Inode_Info)
                        return Boolean is
    begin
       case Nodes (N).Kind is
          when N_Term =>
             return Eval_Term (Nodes (N), Name, Info);
          when N_And =>
             return Eval_Node (Nodes, Nodes (N).Left, Name, Info)
               and then Eval_Node (Nodes, Nodes (N).Right, Name, Info);
          when N_Or =>
             return Eval_Node (Nodes, Nodes (N).Left, Name, Info)
               or else Eval_Node (Nodes, Nodes (N).Right, Name, Info);
          when N_Not =>
             return not Eval_Node (Nodes, Nodes (N).Left, Name, Info);
       end case;
    end Eval_Node;

    --  Build the volume-relative path of an inode by walking the
    --  parent chain, collecting name attributes. False when the
    --  chain is broken or the path does not fit Path'Length.
    --  Caps: 16 components of up to 64 chars (the wire carries
    --  the path in the client buffer, so only Path'Length is the
    --  real limit).
    function Materialize_Path (Info : Inode_Info; Path : out String;
                               Path_Len : out Natural) return Boolean
    is
       Comp      : array (0 .. 15, 1 .. 64) of U8;
       Comp_Len  : array (0 .. 15) of Natural := (others => 0);
       Depth     : Natural := 0;
       Cur       : Inode_Info := Info;
       Parent_Run : Block_Run;
       Total     : Natural;
    begin
       Path_Len := 0;
       loop
          exit when Cur.Block = Root_Block;
          if Depth = 16 then
             return False;
          end if;
          --  Name pseudo-attribute of Cur (first small_data entry).
          declare
             Slot : constant Natural := Get_Block (Cur.Block);
             DL   : U64;
          begin
             if Slot = Cache_Slots
               or else LE32 (Slot, 232) /= File_Name_Type
               or else LE16 (Slot, 236) /= 1
               or else Cache_Data (Slot, 240) /= File_Name_Name
             then
                Put_Block (Slot);
                return False;
             end if;
             DL := U64 (LE16 (Slot, 238));
             if DL = 0 or else DL > 64 then
                Put_Block (Slot);
                return False;
             end if;
             for I in 0 .. DL - 1 loop
                Comp (Depth, Natural (I) + 1) :=
                  Cache_Data (Slot, 244 + I);
             end loop;
             Comp_Len (Depth) := Natural (DL);
             Parent_Run := Run_At (Slot, 44);
             Put_Block (Slot);
          end;
          Depth := Depth + 1;
          if not Read_Inode (To_Block (Parent_Run), Cur) then
             return False;
          end if;
       end loop;
       --  Reverse-join with '/'.
       Total := 0;
       for I in 0 .. Depth - 1 loop
          Total := Total + Comp_Len (I);
       end loop;
       Total := Total + Depth - 1;  --  separators
       if Depth = 0 or else Total > Path'Length then
          return False;
       end if;
       Path_Len := 0;
       for I in reverse 0 .. Depth - 1 loop
          if Path_Len > 0 then
             Path_Len := Path_Len + 1;
             Path (Path'First + Path_Len - 1) := '/';
          end if;
          for K in 1 .. Comp_Len (I) loop
             Path_Len := Path_Len + 1;
             Path (Path'First + Path_Len - 1) :=
               Character'Val (Natural (Comp (I, K)));
          end loop;
       end loop;
       return True;
    end Materialize_Path;

    function Query (Predicate : String; Index : U64;
                    Path : out String; Path_Len : out Natural;
                    Size : out U64; Is_Dir : out Boolean)
                    return U64
    is
       NI      : Inode_Info;
       It      : Tree_It;
       E_Name  : String (1 .. 32);
       E_Len   : Natural;
       E_Block : U64;
       Info    : Inode_Info;
       Ok      : Boolean;
       Root_N  : Natural;
       Seen    : U64 := 0;
    begin
       Path_Len := 0;
       Size := 0;
       Is_Dir := False;
       if not Is_Mounted or else Name_Index = 0
         or else Predicate'Length = 0
         or else Predicate'Length > Pred_Max
       then
          return Status_Not_Found;
       end if;
       --  Parse.
       Pred_Count := 0;
       Pred_Ok := True;
       Pred_Len := Predicate'Length;
       Pred_Pos := 1;
       for I in 1 .. Pred_Len loop
          Pred_Buf (I) := Predicate (Predicate'First + I - 1);
       end loop;
       Root_N := Parse_Or;
       Pred_Skip_Ws;
       if not Pred_Ok or else Root_N = 0 or else Pred_Pos <= Pred_Len
       then
          return Status_Bad_Args;  --  parse error / trailing junk
       end if;
       if not Read_Inode (Name_Index, NI) then
          return Status_Not_Found;
       end if;
       Tree_Rewind (NI, It, Ok);
       if not Ok then
          return Status_Not_Found;
       end if;
       while Tree_Next (It, E_Name, E_Len, E_Block) loop
          if Read_Inode (E_Block, Info)
            and then Eval_Node (Pred_Nodes'Access, Root_N,
                                E_Name (1 .. E_Len), Info)
          then
             if Seen = Index then
                Is_Dir := (Info.Mode and S_IFMT) = S_IFDIR;
                if not Is_Dir then
                   Size := Info.Size;
                end if;
                if not Materialize_Path (Info, Path, Path_Len) then
                   return Status_Bad_Args;  --  unrepresentable path
                end if;
                return Status_Ok;
             end if;
             Seen := Seen + 1;
          end if;
       end loop;
       return Status_Not_Found;
    end Query;

    ------------------------------------------------------------------
    --  Live queries (m82g)
    --
    --  A subscription snapshots the parsed predicate AST plus a
    --  client-supplied notification cap. Mutation ops evaluate the
    --  entry state before and after their change per subscription
    --  and diff the match bits (entry entered the result set →
    --  Ev_Added, left it → Ev_Removed); events carry the
    --  volume-relative path and are delivered only after the
    --  journal commit succeeds. A full event queue raises a
    --  one-shot Ev_Resync instead (the client re-runs the query).
    ------------------------------------------------------------------

    Live_Ev_Max : constant := 8;   --  queued events per subscription

    Ev_Added   : constant := 1;
    Ev_Removed : constant := 2;
    Ev_Resync  : constant := 3;

    type Live_Path is record
       Len  : Natural := 0;
       Text : String (1 .. 255) := (others => ' ');
    end record;

    type Live_Ev is record
       Kind : U8 := 0;
       Path : Live_Path;
    end record;

    type Live_Ev_Queue is array (0 .. Live_Ev_Max - 1) of Live_Ev;

    type Live_Sub is record
       Active : Boolean := False;
       Ntfn   : U64 := 0;
       Root   : Natural := 0;
       Nodes  : aliased Pred_Node_Store;
       Ev     : Live_Ev_Queue;
       Ev_N   : Natural := 0;
       Resync : Boolean := False;
    end record;

    --  m80f: chunk-appended; the wrapper keeps the existing
    --  0-based slot numbering (wire handle = slot + 1).
    package Live_Tab is new Akernel_User.Tables (Live_Sub);
    function Subs (I : Natural) return Live_Tab.Element_Access is
      (Live_Tab.Ref (I + 1));

    --  Events captured by the in-flight mutation op, delivered by
    --  Trans_Commit (4 covers the write/truncate/rename diffs).
    type Pend_Rec is record
       Any   : Boolean := False;
       Kind  : U8 := 0;
       Match : Pend_Bits := No_Bits;
       Path  : Live_Path;
    end record;
    type Pend_List is array (0 .. 3) of Pend_Rec;
    Pend : Pend_List;

    procedure Live_Clear is
    begin
       Pend := (others => <>);
    end Live_Clear;

    --  Evaluate every active subscription against (Name, Info).
    function Live_Eval (Name : String; Info : Inode_Info)
                        return Pend_Bits
    is
       R : Pend_Bits := No_Bits;
    begin
       for S in Integer range 0 .. Live_Tab.Last - 1 loop
          if Subs (S).Active and then Subs (S).Root /= 0 then
             R (S) := Eval_Node (Subs (S).Nodes'Access,
                                 Subs (S).Root, Name, Info);
          end if;
       end loop;
       return R;
    end Live_Eval;

    --  Queue a pending event when any subscription matches; the
    --  path is materialized from Info while the transaction
    --  overlay still shows the capture-time state.
    procedure Live_Push (Kind : U8; Match : Pend_Bits;
                         Info : Inode_Info)
    is
       Any : Boolean := False;
       P   : Live_Path;
    begin
       for S in Integer range 0 .. Live_Tab.Last - 1 loop
          Any := Any or else Match (S);
       end loop;
       if not Any then
          return;
       end if;
       if not Materialize_Path (Info, P.Text, P.Len) then
          return;  --  unrepresentable path: events are advisory
       end if;
       for R of Pend loop
          if not R.Any then
             R := (Any => True, Kind => Kind, Match => Match,
                   Path => P);
             return;
          end if;
       end loop;
    end Live_Push;

    --  Diff before/after match bits and queue the transitions.
    procedure Live_Diff (Was, Now : Pend_Bits; Info : Inode_Info)
    is
       RM : Pend_Bits := No_Bits;
       AD : Pend_Bits := No_Bits;
       A_RM : Boolean := False;
       A_AD : Boolean := False;
    begin
       for S in Integer range 0 .. Live_Tab.Last - 1 loop
          if Subs (S).Active then
             RM (S) := Was (S) and not Now (S);
             AD (S) := Now (S) and not Was (S);
             A_RM := A_RM or else RM (S);
             A_AD := A_AD or else AD (S);
          end if;
       end loop;
       if A_RM then
          Live_Push (Ev_Removed, RM, Info);
       end if;
       if A_AD then
          Live_Push (Ev_Added, AD, Info);
       end if;
    end Live_Diff;

    --  Trans_Commit epilogue: enqueue pending events and ring the
    --  doorbells (bit 0; the client polls to drain the queue).
    procedure Live_Deliver is
    begin
       for R of Pend loop
          exit when not R.Any;
          for S in Integer range 0 .. Live_Tab.Last - 1 loop
             if Subs (S).Active and then R.Match (S) then
                if Subs (S).Ev_N < Live_Ev_Max then
                   Subs (S).Ev (Subs (S).Ev_N) :=
                     (Kind => R.Kind, Path => R.Path);
                   Subs (S).Ev_N := Subs (S).Ev_N + 1;
                else
                   Subs (S).Resync := True;
                end if;
                Done : begin
                   if Syscalls.Ntfn_Signal (Subs (S).Ntfn, 1) /= 0
                   then
                      null;  --  doorbell is advisory
                   end if;
                end Done;
             end if;
          end loop;
       end loop;
       Pend := (others => <>);
    end Live_Deliver;

    --  Parse Predicate and subscribe; Ntfn_Cap stays owned by the
    --  engine (deleted at Live_Close). Handle is 1-based.
    function Live_Open (Predicate : String; Ntfn_Cap : U64;
                        Handle : out U64) return U64
    is
       Root_N : Natural;
       Slot   : Integer := -1;
    begin
       Handle := 0;
       if not Is_Mounted or else Name_Index = 0
         or else Predicate'Length = 0
         or else Predicate'Length > Pred_Max
       then
          return Status_Not_Found;
       end if;
       for I in Integer range 0 .. Live_Tab.Last - 1 loop
          if not Subs (I).Active then
             Slot := I;
             exit;
          end if;
       end loop;
       if Slot < 0 then
          --  Grow; the 64-wide diff bitset is the policy cap.
          if Live_Tab.Last >= Live_Width then
             return Status_Bad_Args;  --  subscription policy cap
          end if;
          Slot := Live_Tab.Append - 1;  --  wrapper is 0-based
          if Slot < 0 then
             return Status_Bad_Args;  --  arena OOM
          end if;
       end if;
       --  Parse with the one-shot parser, then snapshot the AST.
       Pred_Count := 0;
       Pred_Ok := True;
       Pred_Len := Predicate'Length;
       Pred_Pos := 1;
       for I in 1 .. Pred_Len loop
          Pred_Buf (I) := Predicate (Predicate'First + I - 1);
       end loop;
       Root_N := Parse_Or;
       Pred_Skip_Ws;
       if not Pred_Ok or else Root_N = 0 or else Pred_Pos <= Pred_Len
       then
          return Status_Bad_Args;
       end if;
       Subs (Slot).all := (Active => True, Ntfn => Ntfn_Cap,
                           Root => Root_N, Nodes => Pred_Nodes,
                           others => <>);
       Handle := U64 (Slot) + 1;
       return Status_Ok;
    end Live_Open;

    --  Pop the oldest queued event (Status_Not_Found when empty);
    --  a pending overflow yields a single Ev_Resync event.
    function Live_Poll (Handle : U64; Kind : out U64;
                        Path : out String; Path_Len : out Natural)
                        return U64
    is
    begin
       Kind := 0;
       Path_Len := 0;
       if Handle = 0 or else Handle > U64 (Live_Tab.Last) then
          return Status_Bad_Args;
       end if;
       declare
          H : constant Natural := Natural (Handle) - 1;
          E : Live_Ev;
       begin
          if not Subs (H).Active then
             return Status_Bad_Args;
          end if;
          if Subs (H).Ev_N = 0 then
             if Subs (H).Resync then
                Subs (H).Resync := False;
                Kind := Ev_Resync;
                return Status_Ok;
             end if;
             return Status_Not_Found;
          end if;
          E := Subs (H).Ev (0);
          for I in 1 .. Subs (H).Ev_N - 1 loop
             Subs (H).Ev (I - 1) := Subs (H).Ev (I);
          end loop;
          Subs (H).Ev_N := Subs (H).Ev_N - 1;
          Kind := U64 (E.Kind);
          while Path_Len < Path'Length
            and then Path_Len < E.Path.Len
          loop
             Path_Len := Path_Len + 1;
             Path (Path'First + Path_Len - 1) :=
               E.Path.Text (Path_Len);
          end loop;
          return Status_Ok;
       end;
    end Live_Poll;

    procedure Live_Close (Handle : U64) is
       Unused : U64;
    begin
       if Handle >= 1 and then Handle <= U64 (Live_Tab.Last) then
          declare
             H : constant Natural := Natural (Handle) - 1;
          begin
             if Subs (H).Active then
                Subs (H).Active := False;
                Unused := Syscalls.Cap_Delete (Subs (H).Ntfn);
             end if;
          end;
       end if;
    end Live_Close;

    ------------------------------------------------------------------
    --  Attributes (small_data region of the inode, m82d)
    --
    --  Like Haiku's attribute iterator and tools/befs_dump.py, the
    --  NAME pseudo-attribute is NOT user-visible: the walks below
    --  skip it via Is_Name_Attr (region layout documented at
    --  Small_Data_Off above).
    ------------------------------------------------------------------

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

    function Attr_Write (Path : String; Attr : String;
                         Attr_Type : U64; Buf : System.Address;
                         Len : U64) return U64
    is
       Info    : Inode_Info;
       Root    : Boolean;
       P_Path  : String (1 .. 32);
       P_Len   : Natural;
       P_Name  : String (1 .. 32);
       N_Len   : Natural := 0;
       Was     : Pend_Bits := No_Bits;
       Pos     : U64;
       NLen    : U64 := 0;
       DLen    : U64;
       Match   : Boolean;
       Hit     : U64 := U64'Last;   --  offset of existing entry
       Hit_Tot : U64 := 0;          --  its total size
       End_Pos : U64;               --  terminator offset
       New_Tot : U64;
    begin
       if not Is_Mounted or else not Lookup (Path, Info, Root) then
          return Status_Not_Found;
       end if;
       if Attr'Length = 0
         or else Attr'Length > 255
         or else (Attr'Length = 1
                  and then Attr (Attr'First) = Character'Val (16#13#))
         or else Len > Block_Size   --  real room check below
       then
          return Status_Bad_Args;
       end if;
       --  m82g: capture the pre-write match state (attr terms).
       Split_Path (Path, P_Path, P_Len, P_Name, N_Len);
       if N_Len /= 0 then
          Was := Live_Eval (P_Name (1 .. N_Len), Info);
       end if;
       New_Tot := 8 + U64 (Attr'Length) + 3 + Len + 1;
       declare
          Slot : constant Natural := Get_Block (Info.Block);
       begin
          if Slot = Cache_Slots then
             return Status_Bad_Args;
          end if;
          Pos := Small_Data_Off;
          while Pos + 8 <= Block_Size loop
             NLen := U64 (LE16 (Slot, Pos + 4));
             DLen := U64 (LE16 (Slot, Pos + 6));
             exit when NLen = 0;
             exit when Pos + 8 + NLen + 3 + DLen + 1 > Block_Size;
             if not Is_Name_Attr (Slot, Pos, NLen)
               and then Hit = U64'Last
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
                   Hit := Pos;
                   Hit_Tot := 8 + NLen + 3 + DLen + 1;
                end if;
             end if;
             Pos := Pos + 8 + NLen + 3 + DLen + 1;
          end loop;
          if NLen /= 0 then
             --  Region ran to the block end without a terminator.
             Put_Block (Slot);
             return Status_Bad_Args;
          end if;
          End_Pos := Pos;
          if Hit = U64'Last then
             if Len = 0 then
                Put_Block (Slot);
                return Status_Not_Found;   --  remove of absent
             end if;
             Hit := End_Pos;
             Hit_Tot := 0;   --  insert: nothing overwritten
          end if;
          --  Tail after the replaced entry, terminator included
          --  (8 bytes; Rename_Name_Attr uses the same convention).
          declare
             Tail_From : constant U64 := Hit + Hit_Tot;
             Tail_Len  : constant U64 := End_Pos + 8 - Tail_From;
          begin
             if Len > 0
               and then Hit + New_Tot + Tail_Len > Block_Size
             then
                Put_Block (Slot);
                return Status_Bad_Args;   --  no small_data room
             end if;
             if Len = 0 then
                --  Remove: shift the tail down over the entry.
                for I in 0 .. Tail_Len - 1 loop
                   Cache_Data (Slot, Hit + I) :=
                     Cache_Data (Slot, Tail_From + I);
                end loop;
             else
                --  Shift the tail (mind the overlap direction),
                --  then write header, name, pads and data.
                if New_Tot > Hit_Tot then
                   for I in reverse 0 .. Tail_Len - 1 loop
                      Cache_Data (Slot, Hit + New_Tot + I) :=
                        Cache_Data (Slot, Tail_From + I);
                   end loop;
                elsif New_Tot < Hit_Tot then
                   for I in 0 .. Tail_Len - 1 loop
                      Cache_Data (Slot, Hit + New_Tot + I) :=
                        Cache_Data (Slot, Tail_From + I);
                   end loop;
                end if;
                Put_LE32 (Slot, Hit,
                          U32 (Attr_Type and 16#FFFF_FFFF#));
                Put_LE16 (Slot, Hit + 4, U16 (Attr'Length));
                Put_LE16 (Slot, Hit + 6, U16 (Len));
                for K in 0 .. Attr'Length - 1 loop
                   Cache_Data (Slot, Hit + 8 + U64 (K)) :=
                     U8 (Character'Pos (Attr (Attr'First + K)));
                end loop;
                for K in 0 .. 2 loop   --  3 pad bytes (NUL + 2)
                   Cache_Data
                     (Slot, Hit + 8 + U64 (Attr'Length) + U64 (K)) := 0;
                end loop;
                if Len > 0 then
                   declare
                      Src : Byte_Array (0 .. Len - 1)
                        with Address => Buf;
                   begin
                      for I in 0 .. Len - 1 loop
                         Cache_Data
                           (Slot, Hit + 8 + U64 (Attr'Length) + 3 + I)
                           := Src (I);
                      end loop;
                   end;
                end if;
                Cache_Data (Slot, Hit + New_Tot - 1) := 0;  --  pad
             end if;
          end;
          Trans_Add (Slot);
          Put_Block (Slot);
       end;
       --  m82g: diff against the post-write state (the transaction
       --  overlay shows the new small_data).
       if N_Len /= 0 then
          declare
             Cur : Inode_Info;
          begin
             if Read_Inode (Info.Block, Cur) then
                Live_Diff (Was, Live_Eval (P_Name (1 .. N_Len), Cur),
                           Cur);
             end if;
          end;
       end if;
       if not Trans_Commit then
          return Status_Bad_Args;
       end if;
       return Status_Ok;
    end Attr_Write;

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
