with Akernel_User.Syscalls;

--  Fileserver's big static tables, library level so they live in
--  BSS — declared inside procedure Fileserver they sat on the
--  16 KiB mapped main stack (12 KiB at 128 files; the 512-name
--  bump for milestone 38b pushed the main frame to ~40 KiB and
--  the store fault killed the server at startup; same burn class
--  as the M29 init stack and M33a Type buffer).
package Fileserver_Tables is
   subtype U64 is Akernel_User.Syscalls.U64;

   --  16 was silently full: 17 boot files with System/Procfs
   --  (milestone 37b) and Tests/Teardown, last in cpio sort
   --  order, lost its name-table slot (same shape as the
   --  milestone-34 Max_Process_Slots burn). 512 names is
   --  RAM-only (~28 KB) — since 38b there is no per-file VA
   --  window, so the table size no longer scales address space.
   Max_Files : constant := 512;
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

   File_Table : array (1 .. Max_Files) of File_Entry;

   --  Volumes (Amiga-style device/label mounts): the boot-file
   --  set is mounted under a device name and a volume label,
   --  either resolves on the wire.
   Max_Volumes : constant := 8;

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

   Volumes : array (1 .. Max_Volumes) of Volume_Entry;

   --  Assigns (milestone 36): session path aliases, Amiga-style.
   Max_Assigns : constant := 8;

   type Assign_Entry is record
      Valid    : Boolean := False;
      Name     : String (1 .. 16) := (others => Character'Val (0));
      Name_Len : Natural := 0;
      Target   : String (1 .. 48) := (others => Character'Val (0));
      Tgt_Len  : Natural := 0;
   end record;

   Assigns : array (1 .. Max_Assigns) of Assign_Entry;
end Fileserver_Tables;
