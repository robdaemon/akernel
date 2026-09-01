--  Pure-Ada BeFS (Haiku BFS) read-only engine (milestone 82c).
--  Re-implemented from the on-disk format with the MIT-licensed
--  Haiku sources (src/add-ons/kernel/file_systems/bfs/) as
--  reference reading only; validated against the tools/mkbefs.py
--  fixture and its tools/befs_dump.py ground truth.
--
--  Mount gate: little-endian volume, 1024-byte blocks, EMPTY log
--  (log_start = log_end — a dirty journal would need replay, i.e.
--  write support, which is M82e). Anything else refuses to mount.
--
--  Status returns mirror the fs wire protocol: 0 ok, 1 not found,
--  4 out of range.

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

   procedure Volume_Info (Total, Free, Block : out U64);
end Bfs_Engine;
