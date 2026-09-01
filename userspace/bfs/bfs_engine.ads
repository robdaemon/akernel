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
--  allocation is first-fit over bitmap block 1; btrees are
--  single-leaf only (no node splits — a full leaf answers
--  Bad_Args, fixture-scale directories stay far below that); file
--  data lives in the 12 direct runs only (no indirect streams).
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

    --  Index-th visible entry ("." and ".." skipped). Name is NUL
    --  padding aside, up to 24 chars (wire limit).
    function Read_Dir (Path : String; Index : U64;
                       Name : out String; Name_Len : out Natural;
                       Size : out U64; Is_Dir : out Boolean)
                       return U64;

    --  M82e write path. All ops are journaled (see header).

    --  Writes Len bytes from Buf at Offset; Len is clamped by the
    --  caller's buffer. Creates Path as a regular file when it does
    --  not exist and the parent directory resolves (Offset must be
    --  0 then). No sparse writes: Offset past the file size answers
    --  status 4. Growth allocates whole blocks into the direct
    --  runs; a file needing more than 12 runs answers status 3.
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

    procedure Volume_Info (Total, Free, Block : out U64);
end Bfs_Engine;
