--  Pure-Ada BeFS (Haiku BFS) engine (milestone 82c read path,
--  82e journaled write path). Re-implemented from the on-disk
--  format with the MIT-licensed Haiku sources
--  (src/add-ons/kernel/file_systems/bfs/) as reference reading
--  only; validated against the tools/mkbefs.py fixture and its
--  tools/befs_dump.py ground truth.
--
--  Mount gate: little-endian volume, 1024-byte blocks. A non-empty
--  log (log_start /= log_end) is replayed before mounting — crash
--  recovery for the write path.
--
--  Write path (M82e): every mutating wire op is ONE journal
--  transaction. Modified blocks are snapshotted into the
--  transaction, written to the log as a Haiku run_array block +
--  contents, the superblock goes DIRT with the new log_end, the
--  blocks land at their real offsets, then the superblock goes
--  CLEN with log_start = log_end (immediate checkpoint). Block
--  allocation is first-fit; btrees split full nodes up to depth 3
--  (m82h) — removed entries never free nodes (no merge, free-node
--  list stays -1); file data lives in the 12 direct runs only (no
--  indirect streams).
--
--  Allocation groups (M93): a volume is num_ags allocation groups
--  of 1 << ag_shift blocks each (the fixture uses ag_shift 13 =
--  8192 blocks per group). DEVIATION FROM HAIKU, documented:
--  Haiku stores AG g's block bitmap at the start of AG g's own region;
--  this engine keeps every AG's single bitmap block consecutively
--  at blocks 1..num_ags (block 1 + g = AG g's bitmap, bit i =
--  global block g * 8192 + i) with the log right after, so the
--  superblock's blocks_per_ag = 1 describes the whole volume and
--  the allocator indexes the right bitmap block by global
--  block / 8192. Runs NEVER cross an AG boundary (the allocator
--  and the journal run-coalescing both enforce it), which keeps
--  the u16 run start/length fields valid. This lifts the old
--  8 MiB ceiling (one bitmap block) to arbitrary sizes: a 256 MiB
--  volume = 32 AGs. Mount reads ag_shift / num_blocks from the
--  superblock, so the layout stays self-describing.
--
--  Status returns mirror the fs wire protocol: 0 ok, 1 not found,
--  3 bad args, 4 out of range.

with Akernel_User.Syscalls;
with System;

package Bfs_Engine is
   subtype U64 is Akernel_User.Syscalls.U64;

   --  Block service endpoint + bounce buffer cap for block RPCs.
   procedure Init (Blk_EP : U64; Buf_Cap : U64);

   function Mounted return Boolean;

   --  Path: '/'-separated components, no volume prefix; "" = root.
   function Stat (Path : String; Size : out U64; Is_Dir : out Boolean)
                  return U64;

   --  Reads up to Len bytes at Offset into Buf; Len is clamped to
   --  the remaining file size. Offset past the file size answers
   --  status 4; Offset exactly at EOF answers ok with Len = 0.
   function Read (Path : String; Offset : U64; Buf : System.Address;
                  Len : in out U64) return U64;

   --  Attribute enumeration (m82d): Index-th small_data attribute
   --  of the inode at Path. Attr_Type is the BeOS fourcc, Data_Size
   --  the data byte count; Name takes up to Name'Length chars.
   --  Status 1 when Path (or index) does not exist.
   function Attr_List (Path : String; Index : U64;
                       Name : out String; Name_Len : out Natural;
                       Attr_Type : out U64; Data_Size : out U64)
                       return U64;

   --  Whole-attribute read (m82d): the attribute named Attr of the
   --  inode at Path, copied into Buf (Buf_Len bytes max). Count =
   --  bytes copied, Data_Size = full attribute size (truncation is
   --  Count < Data_Size), Attr_Type = the fourcc. Status 1 when
   --  the path or the attribute does not exist.
    function Attr_Read (Path : String; Attr : String;
                        Buf : System.Address; Buf_Len : U64;
                        Count : out U64; Data_Size : out U64;
                        Attr_Type : out U64) return U64;

    --  Attribute write (m82h): insert or replace the small_data
    --  attribute Attr of the inode at Path with Len bytes from
    --  Buf and fourcc Attr_Type; Len = 0 REMOVES the attribute
    --  (Buf and Attr_Type ignored). Journaled like every other
    --  mutation. Status 1 when the path (or, for removal, the
    --  attribute) does not exist; status 3 for over-long
    --  names/data, the internal name pseudo-attribute, a corrupt
    --  small_data region, or no room in the inode.
    function Attr_Write (Path : String; Attr : String;
                         Attr_Type : U64; Buf : System.Address;
                         Len : U64) return U64;

    --  Index-th visible entry ("." and ".." skipped). Name is NUL
    --  padding aside, up to 24 chars (wire limit). Modified is the
    --  entry's mtime in seconds since the Unix epoch (0 when the
    --  driver has no clock/record for it).
    function Read_Dir (Path : String; Index : U64;
                       Name : out String; Name_Len : out Natural;
                       Size : out U64; Is_Dir : out Boolean;
                       Modified : out U64)
                       return U64;

    --  M82e write path. All ops are journaled (see header).

    --  Writes Len bytes from Buf at Offset; Len is clamped by the
    --  caller's buffer. Creates Path as a regular file when it does
    --  not exist and the parent directory resolves (Offset must be
    --  0 then). No sparse writes: Offset past the file size answers
    --  status 4. Growth allocates whole blocks into the direct
    --  runs, then the indirect array (m82h; one 128-entry index
    --  block — a full array answers status 3).
    function Write (Path : String; Offset : U64; Buf : System.Address;
                    Len : in out U64) return U64;

    --  Deletes the regular file at Path (frees data runs, inode
    --  block, dirent, name-index entry). Directories answer 3.
    function Delete (Path : String) return U64;

    --  Truncates the regular file at Path to zero bytes.
    function Truncate (Path : String) return U64;

    --  Creates the directory at Path (parent must resolve, Path
    --  must not exist).
    function Mkdir (Path : String) return U64;

    --  Removes the EMPTY directory at Path (only "." and "..").
    function Rmdir (Path : String) return U64;

    --  Rename/move within the volume. To must not exist; moving a
    --  directory into its own subtree answers 3.
    function Rename (From, To : String) return U64;

    --  One-shot query (m82f): Index-th entry on the volume whose
    --  inode matches Predicate. Grammar: term with == != < <= > >=
    --  over "name" (glob with */?), "size", "last_modified"
    --  (seconds since epoch) or any small_data attribute name,
    --  combined with && || ! and parens. Enumeration rides the
    --  name index leaf chain. Path returns the match's path
    --  relative to the volume root (up to Path'Length chars).
    --  Status 1 = no (more) matches, 3 = parse error or an
    --  unrepresentable result path.
    function Query (Predicate : String; Index : U64;
                    Path : out String; Path_Len : out Natural;
                    Size : out U64; Is_Dir : out Boolean)
                    return U64;

    --  Live queries (m82g): Live_Open subscribes Predicate and
    --  takes ownership of Ntfn_Cap (deleted at Live_Close);
    --  returns a 1-based Handle. Matching mutations queue path
    --  events (Kind 1 = added, 2 = removed, 3 = resync after queue
    --  overflow) and signal the notification. Live_Poll pops the
    --  oldest event (status 1 = queue empty, 3 = bad handle).
    function Live_Open (Predicate : String; Ntfn_Cap : U64;
                        Handle : out U64) return U64;
    function Live_Poll (Handle : U64; Kind : out U64;
                        Path : out String; Path_Len : out Natural)
                        return U64;
    procedure Live_Close (Handle : U64);

    procedure Volume_Info (Total, Free, Block : out U64);
end Bfs_Engine;
