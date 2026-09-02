with System;
with Akernel_User.Syscalls;

--  9P-ish file protocol over endpoint RPC (docs/IPC.md): the file
--  server (System/Fileserver) holds the boot-file caps; clients hold
--  only an endpoint Send cap. Protocol labels on the message:
--
--    Op_Set_Name = 0   init -> server: (sentinel, length,
--                       name[32]) + boot-file cap transferred in
--                       slot 0; zero words + no cap = table done
--    Op_Stat     = 1   words = name[48] -> (status, size)
--    Op_Open     = 2   words = name[48] -> (status, size)
--    Op_Read     = 3   (offset, length, name[32]) + buffer memory
--                      cap in cap slot 0 -> (status, count); bytes
--                      appear at offset 0 of the client's buffer
--
--    Op_Mount    = 4   init -> server: (devlen, labellen, ci,
--                      device ++ label chars[24]) from the manifest's
--                      volume directive
--    Op_Add_Block = 5  init -> server: same words as Op_Mount plus
--                      a block-driver service endpoint cap (Send) in
--                      cap slot 0; mounts a block-backed volume whose
--                      single file "disk" is the raw device
--    Op_Add_FS  = 6    init -> server: same words as Op_Mount plus
--                      an fs-driver service endpoint cap (Send) in
--                      cap slot 0; mounts a VFS-forwarded volume —
--                      stat/open/read for its paths are relayed to
--                      the fs driver (e.g. System/Fat32), which
--                      speaks this same protocol
--    Op_Write   = 7    (offset, length, name[32]) + buffer memory
--                      cap in cap slot 0 -> (status, count); the
--                      server consumes the buffer. Boot-file
--                      volumes are read-only; raw "disk" files and
--                      fs-driver volumes accept writes (create when
--                      the parent directory exists, 8.3 component
--                      names or LFN-with-alias; sparse writes
--                      rejected)
--    Op_Delete  = 8    words = name[48] -> (status, 0); file only
--                      (directories: Op_Rmdir); frees the cluster
--                      chain, dirent + LFN run marked deleted
--    Op_Truncate = 9   words = name[48] -> (status, 0); file
--                      truncated to zero length (chain freed)
--    Op_Mkdir   = 10   words = name[48] -> (status, 0); creates a
--                      directory (one cluster, "."/".." entries)
--    Op_Rmdir   = 11   words = name[48] -> (status, 0); removes an
--                      EMPTY directory (bad args otherwise)
--    Op_Sync    = 12   no words -> (status, 0); flush all volumes
--                      (write-through today: verified no-op
--                      passthrough; real flush with write-back
--                      caches or a device flush later)
--
--  Mutating ops (7..11) are rejected by boot-file volumes (read-
--  only) and raw block volumes; fs-driver volumes receive them
--  forwarded verbatim (path repacked, buffer cap onward for 7).
--
--  Block volumes speak the block protocol to the driver (labels):
--    0 info  -> (status, capacity in sectors)
--    1 read  (sector, count<=8) + buffer memory-object cap (Manage)
--    2 write same, buffer -> device; replies (status, 0)
--
--  Statuses: 0 ok, 1 not found, 2 server not ready (name table not
--  yet pushed by init), 3 bad arguments, 4 out of range.
--
--  Wire names are volume-qualified Amiga-style: "RD0:System/Init"
--  or via the volume label "Initrd:System/Init". Volume prefixes
--  always compare case-insensitively; path comparison follows the
--  mounted filesystem's case flag. Unqualified names are resolved
--  client-side: this package prepends the default volume (RD0,
--  settable via Set_Default_Volume) — the seed of a PATH resolver.
--
--  Reads are stateless (no fids, no close). The read buffer is a
--  client-owned memory object (Buf_Pages pages) transferred with
--  each Read call; the server maps it into its own address space
--  (the transferred cap pins the frames) and copies file bytes into
--  it. Open allocates and maps the buffer at Buffer_VA on first
--  success.

package Akernel_User.Files is
   use type Syscalls.U64;

   subtype U64 is Syscalls.U64;

   Op_Set_Name : constant U64 := 0;
   Op_Stat     : constant U64 := 1;
   Op_Open     : constant U64 := 2;
   Op_Read     : constant U64 := 3;
   Op_Mount    : constant U64 := 4;
   Op_Add_Block : constant U64 := 5;
   Op_Add_FS   : constant U64 := 6;
   Op_Write    : constant U64 := 7;
   Op_Delete   : constant U64 := 8;
   Op_Truncate : constant U64 := 9;
   Op_Mkdir    : constant U64 := 10;
   Op_Rmdir    : constant U64 := 11;
   Op_Sync     : constant U64 := 12;
   Op_ReadDir  : constant U64 := 13;
   Op_Assign   : constant U64 := 14;
   Op_Assign_List : constant U64 := 15;
   Op_Rename   : constant U64 := 16;
   Op_Volume_Info : constant U64 := 17;
   Op_Close    : constant U64 := 18;
   Op_Attr_List : constant U64 := 19;
   Op_Attr_Read : constant U64 := 20;
   Op_Query     : constant U64 := 21;
   Op_Query_Open  : constant U64 := 22;
   Op_Query_Poll  : constant U64 := 23;
   Op_Query_Close : constant U64 := 24;
   --    Op_Attr_List = 19  words 0..3 = path (32 chars, "" =
   --                      volume root), word 4 = attribute index
   --                      -> (status, attr type code, attr data
   --                      size, attr name[24] in words 3..5).
   --                      Stateless like Op_ReadDir: index N
   --                      returns the N-th attribute;
   --                      Status_Not_Found ends the enumeration.
   --                      FS-driver volumes only; every other
   --                      volume answers Not_Found (behaves like
   --                      an empty attribute list). Type codes
   --                      are BeOS fourccs ('MIMS' MIME string,
   --                      'CSTR' C string, 'ULLG' u64, ...).
   --    Op_Attr_Read = 20  words 0..3 = path (32 chars), words
   --                      4..5 = attr name (16 chars) + buffer
   --                      memory cap in cap slot 0 -> (status,
   --                      count copied, attr total size, type
   --                      code). Whole-attribute read: count =
   --                      min(attr size, buffer bytes); truncation
   --                      is detectable as count < size. Only
   --                      small_data attributes today (the
   --                      fixture's attrs all live in the inode).
    --    Op_Query = 21  words 0..3 = path (32 chars; the volume
    --                      root, queries are volume-wide), word 4
    --                      = match index, cap slot 0 = buffer with
    --                      the NUL-terminated predicate (m82f
    --                      grammar: term with == != < <= > >= over
    --                      name/size/last_modified or any small_data
    --                      attribute, && || ! and parens; */? globs
    --                      for strings) -> (status, size, is_dir,
    --                      w3 = path length; the volume-relative
    --                      path is written into the buffer, m82g).
    --                      Stateless like Op_ReadDir: index N
    --                      returns the N-th match; Status_Not_Found
    --                      ends the enumeration. FS-driver volumes
    --                      only; others answer Bad_Args.
    --    Op_Query_Open = 22  words 0..3 = path (volume root), cap
    --                      slot 0 = buffer with the NUL-terminated
    --                      predicate, cap slot 1 = notification cap
    --                      (m82g live query; the FS keeps a copy and
    --                      signals bit 0 when events queue) ->
    --                      (status, 1-based handle in w1).
    --    Op_Query_Poll = 23  word 4 = handle, cap slot 0 = buffer
    --                      for the reply path -> (status, event kind
    --                      in w1: 1 = added, 2 = removed, 3 =
    --                      resync; w2 = path length, path bytes in
    --                      the buffer). Status_Not_Found = queue
    --                      empty.
    --    Op_Query_Close = 24  word 4 = handle -> (status, 0).
   --    Op_Close = 18   words 0..5 = name[48] -> (status, 0). On
   --                      a PIPE: name: writer EOF — no more
   --                      data is coming; reads keep draining
   --                      the ring and an empty EOF pipe
   --                      answers Ok+0. On every other volume
   --                      (incl. NIL:) a harmless no-op Ok:
   --                      regular files are write-through, so
   --                      close = flush = nothing.
   --    PIPE:/NIL: (milestone 46a) are server-internal virtual
   --                      volumes. PIPE:name is a bounded FIFO
   --                      (16 KiB ring): Open creates, Write
   --                      appends all-or-nothing, Read pops;
   --                      empty+no-EOF or insufficient space
   --                      -> Status_Not_Ready (poll + retry);
   --                      Delete destroys, Truncate resets
   --                      (empties + clears EOF for reuse).
   --                      NIL: discards writes (Ok+length),
   --                      reads answer immediate EOF (Ok+0),
   --                      Delete no-ops Ok.
   --    Op_Rename = 16  words 0..5 = FROM path[48]; cap slot 0 =
   --                      an 8-page buffer memobj whose first
   --                      bytes hold the NUL-terminated TO path
   --                      (volume-qualified). The VFS resolves
   --                      BOTH volumes: they must match (cross-
   --                      volume rename rejected Bad_Args), then
   --                      rewrites the buffer with the volume-
   --                      stripped TO path and forwards verbatim.
   --                      The fs driver renames/moves within the
   --                      volume: new dirent preserving cluster,
   --                      size and attributes; directories get
   --                      their ".." entry pointed at the new
   --                      parent; the old dirent run is deleted
   --                      WITHOUT freeing the chain. TO must not
   --                      exist; moving a directory into its own
   --                      subtree is rejected Bad_Args.
   --    Op_Volume_Info = 17  words 0..5 = any volume-qualified
   --                      path (only the volume matters) ->
   --                      (status, total bytes, free bytes,
   --                      bytes per cluster). Free = U64'Last
   --                      when the filesystem does not know
   --                      (FAT FSInfo count unavailable).
   --                      Boot-file volumes answer Bad_Args.
   --    Op_Assign = 14  words 0..1 = name[16] (no colon), words
   --                      2..5 = target[32]; empty target removes
   --                      -> (status, 0). Session path aliases,
   --                      Amiga-style ("C" -> "Sys:C"), resolved by
   --                      the VFS when volume lookup fails.
   --    Op_Assign_List = 15  word 0 = entry index -> (status,
   --                      packed "NAME: target"[40] in words 1..5);
   --                      Status_Not_Found ends the enumeration.
   --    Op_ReadDir = 13  words 0..3 = path (32 chars, "" = volume
   --                      root), word 4 = entry index -> (status,
   --                      size, is_dir, entry name[24] in words
   --                      3..5). Stateless: index N returns the
   --                      N-th live entry; Status_Not_Found ends
   --                      the enumeration. FS-driver volumes only.

   --  Block protocol (file server -> block driver).
   Blk_Info  : constant U64 := 0;
   Blk_Read  : constant U64 := 1;
   Blk_Write : constant U64 := 2;

   Status_Ok           : constant U64 := 0;
   Status_Not_Found    : constant U64 := 1;
   Status_Not_Ready    : constant U64 := 2;
   Status_Bad_Args     : constant U64 := 3;
   Status_Out_Of_Range : constant U64 := 4;

   Buf_Pages : constant U64 := 8;  --  32 KiB client read buffer
   Max_Name  : constant := 32;

   --  Client side: fixed VA window for the read buffer.
   Buffer_VA : constant U64 := 16#4400_0000#;

   --  Bind the package to a file-server endpoint cap (Send right).
   procedure Bind (FS_Cap : U64);

   --  The bound endpoint cap (0 before Bind): lets a spawner grant
   --  the same file service onward to a child.
   function Endpoint return U64;

   --  Default volume for unqualified names (initially "RD0").
   --  Low-level escape hatch ONLY (early boot code, tests):
   --  since milestone 44 CLI programs never call this — user
   --  paths are cwd-resolved and fully qualified by
   --  Akernel_User.CLI before they reach the file server.
   procedure Set_Default_Volume (Name : String);

   --  Stat/Open return a protocol status; Open also allocates and
   --  maps the read buffer on first success.
   function Stat (Name : String; Size : out U64) return U64;
   --  Stat_Ex (milestone 59): Stat plus the dirent write stamp
   --  in FAT encodings (date: year-1980 bits 9..15, month 5..8,
   --  day 0..4; time: hour 11..15, minute 5..10, second/2 0..4).
   --  Volumes without timestamps (initrd, procfs, pipes) return
   --  both as 0.  Milestone 64: Is_Dir (word 4) — Stat answers
   --  DIRECTORIES now (size 0), so stat of an empty drawer works
   --  and Ada.Directories enumerations no longer truncate at one.
   function Stat_Ex
     (Name       : String;
      Size       : out U64;
      Write_Date : out U64;
      Write_Time : out U64;
      Is_Dir     : out Boolean) return U64;
   function Open (Name : String; Size : out U64) return U64;

   --  Directory enumeration (milestone 32, the Dir command):
   --  Index-th live entry of the directory at Name (volume
   --  qualified; "" after the volume = its root). Returns a
   --  protocol status; Status_Not_Found = no more entries.
   --  Entry name comes back in Out_Name (caller buffer >= 24).
   function Read_Dir
     (Name         : String;
      Index        : U64;
      Out_Name     : out String;
      Out_Name_Len : out Natural;
      Is_Dir       : out Boolean;
      Size         : out U64) return U64;

   --  Read Length bytes at Offset into Dest; Count returns the
   --  bytes actually read (clamped at EOF and buffer capacity).
   --  Requires a prior successful Open.
   function Read
     (Name   : String;
      Offset : U64;
      Dest   : System.Address;
      Length : U64;
      Count  : out U64) return U64;

   --  Attribute enumeration (milestone 82d): Index-th attribute
   --  of the file at Name (volume qualified). Returns a protocol
   --  status; Status_Not_Found = no more attributes. Attr name
   --  comes back in Out_Name (caller buffer >= 24); Attr_Type is
   --  the BeOS fourcc ('MIMS', 'CSTR', 'ULLG', ...), Attr_Size
   --  the data length in bytes. Volumes without attribute
   --  support answer Not_Found at index 0 (empty list).
   function Attr_List
     (Name         : String;
      Index        : U64;
      Out_Name     : out String;
      Out_Name_Len : out Natural;
      Attr_Type    : out U64;
      Attr_Size    : out U64) return U64;

   --  Attribute read (milestone 82d): the whole attribute Attr
   --  of Name into Dest (Length bytes max through the shared
   --  client buffer, allocated on first use like Open). Count
   --  returns the bytes actually read; Attr_Size the attribute's
   --  full size (truncation = Count < Attr_Size); Attr_Type the
   --  fourcc. Attr names are limited to 16 chars on the wire.
   function Attr_Read
     (Name      : String;
      Attr      : String;
      Dest      : System.Address;
      Length    : U64;
      Count     : out U64;
      Attr_Size : out U64;
      Attr_Type : out U64) return U64;

    --  One-shot query (milestone 82f): Index-th entry on the
    --  volume of Name (only the volume prefix is used) matching
    --  Predicate — term with == != < <= > >= over "name" (glob
    --  */?), "size", "last_modified" (seconds since epoch) or any
    --  small_data attribute, combined with && || ! and parens.
    --  Path returns the match's volume-relative path (truncated to
    --  the caller buffer, 255 max), Size/Is_Dir describe it.
    --  Status_Not_Found = no (more) matches; Status_Bad_Args =
    --  parse error or the volume does not support queries.
    function Query
      (Name      : String;
       Predicate : String;
       Index     : U64;
       Path      : out String;
       Path_Len  : out Natural;
       Size      : out U64;
       Is_Dir    : out Boolean) return U64;

    --  Live queries (milestone 82g): Query_Open subscribes
    --  Predicate (same grammar) on the volume of Name; Ntfn is a
    --  notification cap (Syscalls.Ntfn_Create) the FS signals with
    --  bit 0 whenever events queue. Handle returns 1-based.
    --  Query_Poll pops the oldest queued event: Kind 1 = entry
    --  added, 2 = removed, 3 = queue overflowed (resync with
    --  one-shot Query); Path is the volume-relative path.
    --  Status_Not_Found = queue empty. Query_Close releases the
    --  subscription.
    function Query_Open
      (Name      : String;
       Predicate : String;
       Ntfn      : U64;
       Handle    : out U64) return U64;
    function Query_Poll
      (Name      : String;
       Handle    : U64;
       Kind      : out U64;
       Path      : out String;
       Path_Len  : out Natural) return U64;
    function Query_Close (Name : String; Handle : U64) return U64;


   --  Write Length bytes from the caller's buffer (Buffer_Address
   --  must be an 8-page memory object) at Offset into Name; Count
   --  returns the bytes actually written. Boot-file volumes are
   --  read-only (Status_Bad_Args). Buffer contents are undefined
   --  after the call.
   function Write
     (Name           : String;
      Offset         : U64;
      Buffer_Address : System.Address;
      Length         : U64;
      Count          : out U64) return U64;

   --  Path-only mutating ops (protocol status): Delete removes a
   --  file, Truncate cuts a file to zero length, Mkdir creates a
   --  directory, Rmdir removes an empty one. Boot-file and raw
   --  block volumes answer Status_Bad_Args.
   function Delete (Name : String) return U64;

   --  Close (milestone 46a): on PIPE: names signals writer EOF;
   --  a no-op Ok on every other volume. The protocol stays
   --  fid-less: Close names the path, not a handle.
   function Close (Name : String) return U64;

   --  Rename/move within one volume (milestone 41): TO must not
   --  exist; both names resolve to the same volume. Directories
   --  move with their contents (".." fixed up). Allocates the
   --  shared client buffer on first use like Open.
   function Rename (From, To : String) return U64;

   --  Volume capacity (milestone 41): Name picks the volume;
   --  Free = U64'Last when the filesystem cannot report it.
   function Volume_Info
     (Name    : String;
      Total   : out U64;
      Free    : out U64;
      Cluster : out U64) return U64;

   --  Assigns (milestone 36): set (Target nonempty) or remove
   --  (Target empty); Name without its colon. List enumerates
   --  "NAME: target" strings by index until Status_Not_Found.
   function Assign_Set (Name : String; Target : String) return U64;
   function Assign_List
     (Index : U64; Text : out String; Text_Len : out Natural)
      return U64;
   function Truncate (Name : String) return U64;
   function Mkdir (Name : String) return U64;
   function Rmdir (Name : String) return U64;

   --  Flush all volumes (write-through today: no-op passthrough).
   function Sync return U64;

end Akernel_User.Files;
