with Akernel_User.Syscalls;
with Akernel_User.Tables;

--  Fileserver's big tables, library level.  M80d: they are
--  grow-on-demand chunk chains now (Akernel_User.Tables over the
--  Table_Arena window) instead of static Max_* arrays — capacity
--  is RAM, not a literal.  Historical burn notes: the tables used
--  to live in BSS because declared inside procedure Fileserver
--  they sat on the 16 KiB mapped main stack (12 KiB at 128
--  files; the 512-name bump for milestone 38b pushed the main
--  frame to ~40 KiB and the store fault killed the server at
--  startup; same burn class as the M29 init stack and M33a Type
--  buffer).  Max_Files itself was born when 16 was silently full
--  (17th boot file lost its slot, m37b) — the class this
--  milestone deletes.
--
--  The old array names survive as renames of Ref, so the
--  hundred-plus `Table (I).Field` sites read unchanged; loops
--  over 'Range become 1 .. <pkg>.Last and free-slot scans fall
--  through to <pkg>.Append.
package Fileserver_Tables is
   subtype U64 is Akernel_User.Syscalls.U64;

   Max_Name  : constant := 32;

   type File_Entry is record
      Valid   : Boolean := False;
      Handle  : U64 := 0;
      Name    : String (1 .. Max_Name) := (others => Character'Val (0));
      Name_Len : Natural := 0;
      Size    : U64 := 0;
      Lead_Known : Boolean := False;
      Lead_In : U64 := 0;
   end record;

   --  Volumes (Amiga-style device/label mounts): the boot-file
   --  set is mounted under a device name and a volume label,
   --  either resolves on the wire.
   type Volume_Entry is record
      Valid   : Boolean := False;
      Device  : String (1 .. 16) := (others => Character'Val (0));
      Dev_Len : Natural := 0;
      Label   : String (1 .. 16) := (others => Character'Val (0));
      Lab_Len : Natural := 0;
      Case_Insensitive : Boolean := False;
      --  Block-backed volume (Op_Add_Block): the single file
      --  "disk" is the raw device, Blk_Size bytes, served by the
      --  block driver at Blk_EP (block protocol, see
      --  Akernel_User.Files).
      Is_Block : Boolean := False;
      Blk_EP   : U64 := 0;
      Blk_Size : U64 := 0;
      --  FS-driver volume (Op_Add_FS): stat/open/read for its
      --  paths are forwarded verbatim to the fs driver at FS_EP
      --  (this server is the VFS layer; filesystems are
      --  independent driver processes).
      Is_FS    : Boolean := False;
      FS_EP    : U64 := 0;
      --  Server-internal virtual volumes (milestone 46a):
      --  seeded by the fileserver itself, never mounted by
      --  init. Is_Pipe: Amiga-style named pipes backed by
      --  Fileserver_Pipes rings (poll semantics — see that
      --  package). Is_Nil: the NIL: sink — writes discarded,
      --  reads answer immediate EOF.
      Is_Pipe  : Boolean := False;
      Is_Nil   : Boolean := False;
   end record;

   --  Assigns (milestone 36): session path aliases, Amiga-style.
   type Assign_Entry is record
      Valid    : Boolean := False;
      Name     : String (1 .. 16) := (others => Character'Val (0));
      Name_Len : Natural := 0;
      Target   : String (1 .. 48) := (others => Character'Val (0));
      Tgt_Len  : Natural := 0;
   end record;

   package File_Tab is new Akernel_User.Tables (File_Entry);
   package Vol_Tab is new Akernel_User.Tables (Volume_Entry);
   package Asn_Tab is new Akernel_User.Tables (Assign_Entry);

   function File_Table
     (I : Natural) return File_Tab.Element_Access renames File_Tab.Ref;
   function Volumes
     (I : Natural) return Vol_Tab.Element_Access renames Vol_Tab.Ref;
   function Assigns
     (I : Natural) return Asn_Tab.Element_Access renames Asn_Tab.Ref;
end Fileserver_Tables;
