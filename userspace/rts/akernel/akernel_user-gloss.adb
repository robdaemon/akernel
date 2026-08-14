with System;
with System.Storage_Elements;  use System.Storage_Elements;
with Interfaces.C;
with Interfaces.C.Strings;
with Ada.Unchecked_Conversion;
with System.Machine_Code;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.Syscalls;

package body Akernel_User.Gloss is

   use type Syscalls.U64;
   use type Interfaces.C.int;
   use type System.Address;

   subtype U64 is Syscalls.U64;
   subtype C_Int is Interfaces.C.int;

   --  newlib errno: errno is (*__errno()) per <sys/errno.h>.
   function C_Errno return access C_Int
     with Import, Convention => C, External_Name => "__errno";

   EPERM   : constant C_Int := 1;
   ENOENT  : constant C_Int := 2;
   EBADF   : constant C_Int := 9;
   ENOMEM  : constant C_Int := 12;
   EEXIST  : constant C_Int := 17;
   EINVAL  : constant C_Int := 22;
   ENFILE  : constant C_Int := 23;
   EMFILE  : constant C_Int := 24;
   ENOSPC  : constant C_Int := 28;
   ENOSYS  : constant C_Int := 88;

   procedure Fail (E : C_Int) is
   begin
      C_Errno.all := E;
   end Fail;

   --  open(2) flags (newlib sys/_default_fcntl.h). Interfaces.C.int
   --  is signed (no bitwise ops), so flag tests go through a modular
   --  view.
   type Flag_Bits is mod 2 ** 32;
   O_ACCMODE : constant Flag_Bits := 3;
   O_WRONLY  : constant Flag_Bits := 1;
   O_RDWR    : constant Flag_Bits := 2;
   O_APPEND  : constant Flag_Bits := 16#0008#;
   O_CREAT   : constant Flag_Bits := 16#0200#;
   O_TRUNC   : constant Flag_Bits := 16#0400#;
   O_EXCL    : constant Flag_Bits := 16#0800#;

   function Neg1_Address return System.Address is
     (System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address'Last))
     with Inline;

   SEEK_SET : constant C_Int := 0;
   SEEK_CUR : constant C_Int := 1;
   SEEK_END : constant C_Int := 2;

   --  stat(2) mode bits (newlib sys/stat.h).
   S_IFCHR : constant := 8#020000#;
   S_IFREG : constant := 8#100000#;
   S_IRWXU : constant := 8#000700#;

   ----------------------------------------------------------------------
   --  struct stat, layout verified against the toolchain headers
   --  (riscv64-elf newlib): dev/ino/nlink/uid/gid/rdev are u16,
   --  mode u32, size/timespecs/blksize/blocks i64, spare tail.
   --  sizeof = 104 bytes.

   type U16 is mod 2 ** 16 with Convention => C, Size => 16;
   type U32 is mod 2 ** 32 with Convention => C, Size => 32;

   type TimeSpec is record
      Sec  : U64;
      NSec : U64;
   end record with Convention => C;

   type Stat_Rec is record
      Dev     : U16;
      Ino     : U16;
      Mode    : U32;
      NLink   : U16;
      UID     : U16;
      GID     : U16;
      RDev    : U16;
      Size    : U64;
      Atim    : TimeSpec;
      Mtim    : TimeSpec;
      Ctim    : TimeSpec;
      BlkSize : U64;
      Blocks  : U64;
      Spare1  : U64;
      Spare2  : U64;
   end record with Convention => C;

   type Stat_Access is access all Stat_Rec with Convention => C;

   ----------------------------------------------------------------------
   --  fd table (library level — never on the stack). fds 0..2 are
   --  the console; 3..Last_FD are path-backed files.

   First_File_FD : constant := 3;
   Last_FD       : constant := 18;

   type FD_Rec is record
      Used     : Boolean := False;
      Readable : Boolean := False;
      Writable : Boolean := False;
      Offset   : U64     := 0;
      Size     : U64     := 0;
      Path     : String (1 .. 256);
      Path_Len : Natural := 0;
   end record;

   FDs : array (First_File_FD .. Last_FD) of FD_Rec;

   --  Lazy endpoint binding. This package is linked via ld -u (no
   --  program withs it), so its body never elaborates under the
   --  binder — package elaboration would NOT run. Instead the
   --  first operation binds the uniform-ABI handles (1 = console
   --  Send, 2 = fs Send), but ONLY when the program has not bound
   --  its own (a test program with a custom grant layout — fuzz
   --  keeps fs on handle 4 — must never be clobbered).
   Bound : Boolean := False;

   procedure Ensure_Bound is
   begin
      if Bound then
         return;
      end if;
      Bound := True;
      if Files.Endpoint = 0 then
         Files.Bind (2);
      end if;
      --  Same for the console, but never clobber a program's own
      --  binding (fuzz's handle 1 is ipc_test, not console).
      if Console.Endpoint = 0 then
         Console.Set_Endpoint (1);
      end if;
   end Ensure_Bound;

   ----------------------------------------------------------------------
   --  53c: cwd (ENV:CWD), environment (ENV:<NAME>), directory walks
   --  (fs Op_ReadDir) and the Ada.Command_Line argv bridge. The
   --  env/dir ops are C-exported for the vendored C support layer
   --  (env.c, adaint.c); akernel_init_args runs from crt0.

   --  ENV:CWD holds the session cwd string (m42 convention; "Sys:"
   --  when unset). Relative newlib paths qualify against it
   --  Amiga-style: "<cwd><name>" when the cwd ends at the volume
   --  colon, else "<cwd>/<name>".
   function Get_CWD return String is
      Buf : String (1 .. 256);
      Sz  : U64 := 0;
      Cnt : U64 := 0;
   begin
      if Files.Open ("ENV:CWD", Sz) = Files.Status_Ok then
         Sz := U64'Min (Sz, U64 (Buf'Length));
         if Files.Read ("ENV:CWD", 0, Buf'Address, Sz, Cnt)
              = Files.Status_Ok
           and then Cnt > 0
         then
            return Buf (1 .. Natural (Cnt));
         end if;
      end if;
      return "Sys:";
   end Get_CWD;

   function Set_CWD (V : String) return U64 is
      Buf : String (1 .. 256);
      Cnt : U64 := 0;
      St  : U64;
   begin
      if V'Length = 0 or else V'Length > Buf'Length then
         return Files.Status_Bad_Args;
      end if;
      for I in V'Range loop
         Buf (I - V'First + 1) := V (I);
      end loop;
      St := Files.Truncate ("ENV:CWD");
      --  Op_Write creates the file when Prefs/Env exists; a missing
      --  truncate just means "not there yet".
      return Files.Write
        ("ENV:CWD", 0, Buf'Address, U64 (V'Length), Cnt);
   end Set_CWD;

   function Qualify (P : String) return String is
   begin
      for Ch of P loop
         if Ch = ':' then
            return P;  --  already volume-qualified
         end if;
      end loop;
      declare
         Cwd : constant String := Get_CWD;
      begin
         if Cwd (Cwd'Last) = ':' then
            return Cwd & P;
         end if;
         return Cwd & "/" & P;
      end;
   end Qualify;

   --  Environment: variables ARE files (m33a ruling), ENV:<NAME>.
   --  env.c calls these under AKERNEL_ENV_FILES.
   function Akernel_Env_Get
     (Name  : Interfaces.C.Strings.chars_ptr;
      Buf   : System.Address;
      Bufsz : C_Int) return C_Int;
   pragma Export (C, Akernel_Env_Get, "akernel_env_get");

   function Akernel_Env_Get
     (Name  : Interfaces.C.Strings.chars_ptr;
      Buf   : System.Address;
      Bufsz : C_Int) return C_Int
   is
      P   : constant String := "ENV:" & Interfaces.C.Strings.Value (Name);
      Sz  : U64 := 0;
      Cnt : U64 := 0;
   begin
      Ensure_Bound;
      if Files.Open (P, Sz) /= Files.Status_Ok then
         return -1;
      end if;
      Sz := U64'Min (Sz, U64 (Bufsz));
      if Files.Read (P, 0, Buf, Sz, Cnt) /= Files.Status_Ok
        or else Cnt = 0
      then
         return -1;
      end if;
      return C_Int (Cnt);
   end Akernel_Env_Get;

   function Akernel_Env_Set
     (Name  : Interfaces.C.Strings.chars_ptr;
      Value : Interfaces.C.Strings.chars_ptr) return C_Int;
   pragma Export (C, Akernel_Env_Set, "akernel_env_set");

   function Akernel_Env_Set
     (Name  : Interfaces.C.Strings.chars_ptr;
      Value : Interfaces.C.Strings.chars_ptr) return C_Int
   is
      P   : constant String := "ENV:" & Interfaces.C.Strings.Value (Name);
      V   : constant String := Interfaces.C.Strings.Value (Value);
      Buf : String (1 .. 1024);
      Cnt : U64 := 0;
      St  : U64;
   begin
      Ensure_Bound;
      if V'Length > Buf'Length then
         Fail (EINVAL);
         return -1;
      end if;
      for I in V'Range loop
         Buf (I - V'First + 1) := V (I);
      end loop;
      St := Files.Truncate (P);
      St := Files.Write (P, 0, Buf'Address, U64 (V'Length), Cnt);
      if St /= Files.Status_Ok then
         Fail (EPERM);
         return -1;
      end if;
      return 0;
   end Akernel_Env_Set;

   function Akernel_Env_Unset
     (Name : Interfaces.C.Strings.chars_ptr) return C_Int;
   pragma Export (C, Akernel_Env_Unset, "akernel_env_unset");

   function Akernel_Env_Unset
     (Name : Interfaces.C.Strings.chars_ptr) return C_Int
   is
      P  : constant String := "ENV:" & Interfaces.C.Strings.Value (Name);
      St : U64;
   begin
      Ensure_Bound;
      St := Files.Delete (P);
      if St /= Files.Status_Ok
        and then St /= Files.Status_Not_Found
      then
         Fail (EPERM);
         return -1;
      end if;
      return 0;
   end Akernel_Env_Unset;

   --  Directory walks over the stateless by-index Op_ReadDir.
   --  adaint.c's AKERNEL_NO_DIRENT branch calls these; DIR* is the
   --  slot index + 1 (0/NULL = open failed).
   Max_Open_Dirs : constant := 8;

   type Dir_Rec is record
      Used : Boolean := False;
      Path : String (1 .. 256);
      Len  : Natural := 0;
      Next : U64 := 0;
   end record;
   Dir_Slots : array (1 .. Max_Open_Dirs) of Dir_Rec;

   function Akernel_Opendir
     (Name : Interfaces.C.Strings.chars_ptr) return C_Int;
   pragma Export (C, Akernel_Opendir, "akernel_opendir");

   function Akernel_Opendir
     (Name : Interfaces.C.Strings.chars_ptr) return C_Int
   is
      P : constant String := Qualify (Interfaces.C.Strings.Value (Name));
   begin
      Ensure_Bound;
      if P'Length = 0 or else P'Length > 256 then
         return -1;
      end if;
      for I in Dir_Slots'Range loop
         if not Dir_Slots (I).Used then
            Dir_Slots (I).Used := True;
            Dir_Slots (I).Len  := P'Length;
            Dir_Slots (I).Next := 0;
            Dir_Slots (I).Path := (others => ' ');
            Dir_Slots (I).Path (1 .. P'Length) := P;
            return C_Int (I - 1);
         end if;
      end loop;
      return -1;
   end Akernel_Opendir;

   --  Copies the next entry name (NUL-terminated) into Buf; returns
   --  the name length, or -1 at end of directory / on error (both
   --  stop GNAT's iteration).
   function Akernel_Readdir
     (D     : C_Int;
      Buf   : System.Address;
      Bufsz : C_Int) return C_Int;
   pragma Export (C, Akernel_Readdir, "akernel_readdir");

   function Akernel_Readdir
     (D     : C_Int;
      Buf   : System.Address;
      Bufsz : C_Int) return C_Int
   is
      Ent    : String (1 .. 256);
      Ent_L  : Natural;
      Is_Dir : Boolean;
      Sz     : U64;
      Slot   : Natural;
      Out_B  : String (1 .. Ent'Length + 1) with Address => Buf;
   begin
      if D < 0 or else Natural (D) >= Max_Open_Dirs then
         return -1;
      end if;
      Slot := Natural (D) + 1;
      if not Dir_Slots (Slot).Used then
         return -1;
      end if;
      if Files.Read_Dir
           (Dir_Slots (Slot).Path (1 .. Dir_Slots (Slot).Len),
            Dir_Slots (Slot).Next, Ent, Ent_L, Is_Dir, Sz)
           /= Files.Status_Ok
        or else Ent_L = 0
        or else Ent_L + 1 > Natural (Bufsz)
      then
         return -1;
      end if;
      Dir_Slots (Slot).Next := Dir_Slots (Slot).Next + 1;
      Out_B (1 .. Ent_L + 1) := Ent (1 .. Ent_L) & Character'Val (0);
      return C_Int (Ent_L);
   end Akernel_Readdir;

   function Akernel_Closedir (D : C_Int) return C_Int;
   pragma Export (C, Akernel_Closedir, "akernel_closedir");

   function Akernel_Closedir (D : C_Int) return C_Int is
   begin
      if D < 0 or else Natural (D) >= Max_Open_Dirs then
         return -1;
      end if;
      Dir_Slots (Natural (D) + 1).Used := False;
      return 0;
   end Akernel_Closedir;

   --  Ada.Command_Line bridge. argv.c (vendored, 53c) owns
   --  gnat_argc/gnat_argv; crt0 calls akernel_init_args, which
   --  tokenizes the m33a args page exactly like CLI.Parse_Args
   --  (space-separated, no quoting) and points gnat_argv at a
   --  static table. argv[0] is "" — the uniform ABI does not
   --  carry the program's own name; Ada.Command_Line.Argument
   --  numbers then match CLI token numbers.
   Max_Argv  : constant := 64;   --  matches CLI.Max_Args
   Arg_Width : constant := 128;
   Argv_Text : array (0 .. Max_Argv) of aliased
     Interfaces.C.char_array (1 .. Arg_Width)
     := (others => (others => Interfaces.C.nul));
   Argv_Ptrs : array (0 .. Max_Argv) of aliased
     Interfaces.C.Strings.chars_ptr
     := (others => Interfaces.C.Strings.Null_Ptr);

   Gnat_Argc : aliased C_Int
     with Import, External_Name => "gnat_argc";  --  defined by argv.c
   Gnat_Argv : System.Address
     with Import, External_Name => "gnat_argv";

   procedure Akernel_Init_Args;
   pragma Export (C, Akernel_Init_Args, "akernel_init_args");

   procedure Akernel_Init_Args is
      function To_Ptr is new Ada.Unchecked_Conversion
        (System.Address, Interfaces.C.Strings.chars_ptr);
      --  chars_ptr is address-sized; this avoids the char_array_access
      --  static-match dance for fixed-width table rows.

      S   : String (1 .. 512);
      Len : Natural;
      I   : Natural := 1;
      N   : Natural := 1;   --  argv[0] stays the empty command name
   begin
      Argv_Ptrs (0) := To_Ptr (Argv_Text (0)'Address);
      Syscalls.Read_Args (S, Len);
      while I <= Len and then N <= Max_Argv loop
         while I <= Len and then S (I) = ' ' loop
            I := I + 1;
         end loop;
         exit when I > Len;
         declare
            F : constant Natural := I;
            L : Natural;
         begin
            while I <= Len and then S (I) /= ' ' loop
               I := I + 1;
            end loop;
            L := Natural'Min (I - F, Arg_Width - 1);
            for J in 0 .. L - 1 loop
               Argv_Text (N) (Interfaces.C.size_t (J + 1)) :=
                 Interfaces.C.To_C (S (F + J));
            end loop;
            Argv_Text (N) (Interfaces.C.size_t (L + 1)) :=
              Interfaces.C.nul;
            Argv_Ptrs (N) := To_Ptr (Argv_Text (N)'Address);
            N := N + 1;
         end;
      end loop;
      Gnat_Argc := C_Int (N);
      Gnat_Argv := Argv_Ptrs'Address;
   end Akernel_Init_Args;

   ----------------------------------------------------------------------
   --  _sbrk arena (own VA range per the 53b ruling): memobj chunks
   --  mapped on demand, same pattern as s-memory's GNAT heap.

   Sbrk_Base      : constant U64 := 16#5200_0000#;
   Sbrk_Chunk_Pgs : constant U64 := 64;   --  256 KiB per memobj
   Sbrk_Max_Chunk : constant := 16;       --  4 MiB arena
   Page_Bytes     : constant U64 := 4096;

   Sbrk_Caps   : array (0 .. Sbrk_Max_Chunk - 1) of U64 := (others => 0);
   Sbrk_Mapped : U64 := 0;
   Sbrk_Break  : U64 := 0;

   ----------------------------------------------------------------------
   --  Console output for fds 1/2: overlay a String on the caller's
   --  buffer in chunks and hand to Console.Put (shell redirection
   --  composes through Console's own machinery).

   procedure Write_Console (Buf : System.Address; N : U64) is
      use type System.Address;
      Done : U64 := 0;
   begin
      while Done < N loop
         declare
            Chunk : constant U64 := U64'Min (N - Done, 1024);
            S     : String (1 .. Natural (Chunk))
              with Address => Buf + System.Storage_Elements.Storage_Offset (Done);
         begin
            Console.Put (S);
            Done := Done + Chunk;
         end;
      end loop;
   end Write_Console;

   ----------------------------------------------------------------------
   --  File ops.

   function Gloss_Open
     (Path  : Interfaces.C.Strings.chars_ptr;
      Flags : C_Int;
      Mode  : C_Int) return C_Int;
   pragma Export (C, Gloss_Open, "_open");

   function Gloss_Open
     (Path  : Interfaces.C.Strings.chars_ptr;
      Flags : C_Int;
      Mode  : C_Int) return C_Int
   is
      pragma Unreferenced (Mode);
      Raw_P   : constant String :=
        Interfaces.C.Strings.Value (Path);
      P       : constant String := Qualify (Raw_P);
      F       : constant Flag_Bits := Flag_Bits (Flags);
      Slot    : Natural := 0;
      Size    : U64;
      St      : U64;
      Existed : Boolean;
      Written : U64;
      Dummy   : aliased Interfaces.C.char := Interfaces.C.nul;
   begin
      if P'Length = 0 or else P'Length > 256 then
         Fail (EINVAL);
         return -1;
      end if;

      for I in FDs'Range loop
         if not FDs (I).Used then
            Slot := I;
            exit;
         end if;
      end loop;
      if Slot = 0 then
         Fail (EMFILE);
         return -1;
      end if;

      Ensure_Bound;
      St := Files.Open (P, Size);
      Existed := St = Files.Status_Ok;

      if not Existed and then (F and O_CREAT) /= 0 then
         --  The fs protocol creates files on Op_Write; a zero-
         --  length Write is Bad_Args client-side, so create with
         --  one byte and truncate back to empty.
         if Files.Write
              (P, 0, Dummy'Address, 1, Written) = Files.Status_Ok
           and then Files.Truncate (P) = Files.Status_Ok
         then
            St := Files.Open (P, Size);
         end if;
      end if;

      if St /= Files.Status_Ok then
         Fail (ENOENT);
         return -1;
      end if;

      if Existed
        and then (F and O_CREAT) /= 0
        and then (F and O_EXCL) /= 0
      then
         Fail (EEXIST);
         return -1;
      end if;

      if (F and O_TRUNC) /= 0
        and then (F and O_ACCMODE) /= 0
      then
         if Files.Truncate (P) = Files.Status_Ok then
            Size := 0;
         end if;
      end if;

      FDs (Slot) :=
        (Used     => True,
         Readable => (F and O_ACCMODE) /= O_WRONLY,
         Writable => (F and O_ACCMODE) /= 0,
         Offset   => (if (F and O_APPEND) /= 0 then Size else 0),
         Size     => Size,
         Path     => (others => ' '),
         Path_Len => P'Length);
      FDs (Slot).Path (1 .. P'Length) := P;
      return C_Int (Slot);
   end Gloss_Open;

   function Gloss_Close (FD : C_Int) return C_Int;
   pragma Export (C, Gloss_Close, "_close");

   function Gloss_Close (FD : C_Int) return C_Int is
   begin
      if FD < C_Int (First_File_FD) then
         return 0;  --  console fds: nothing to do
      elsif FD > C_Int (Last_FD)
        or else not FDs (Natural (FD)).Used
      then
         Fail (EBADF);
         return -1;
      end if;
      --  Files.Close = pipe EOF on PIPE:, harmless no-op elsewhere.
      declare
         St : constant U64 := Files.Close
           (FDs (Natural (FD)).Path (1 .. FDs (Natural (FD)).Path_Len));
         pragma Unreferenced (St);
      begin
         FDs (Natural (FD)).Used := False;
         return 0;
      end;
   end Gloss_Close;

   function Gloss_Read
     (FD  : C_Int;
      Buf : System.Address;
      N   : U64) return C_Int;
   pragma Export (C, Gloss_Read, "_read");

   function Gloss_Read
     (FD  : C_Int;
      Buf : System.Address;
      N   : U64) return C_Int
   is
      Count : U64;
      St    : U64;
   begin
      Ensure_Bound;
      if FD < C_Int (First_File_FD) then
         return 0;  --  stdin: EOF (no console input endpoint yet)
      elsif FD > C_Int (Last_FD)
        or else not FDs (Natural (FD)).Used
        or else not FDs (Natural (FD)).Readable
      then
         Fail (EBADF);
         return -1;
      end if;

      declare
         F : FD_Rec renames FDs (Natural (FD));
      begin
         St := Files.Read
           (F.Path (1 .. F.Path_Len), F.Offset, Buf, N, Count);
         if St = Files.Status_Out_Of_Range then
            return 0;  --  past-EOF read = POSIX EOF (m54:
                       --  newlib treats -1 as ferror and GNAT's
                       --  Getc then raises Device_Error instead of
                       --  a clean End_Of_File)
         elsif St /= Files.Status_Ok then
            Fail (ENOENT);
            return -1;
         end if;
         F.Offset := F.Offset + Count;
         return C_Int (Count);
      end;
   end Gloss_Read;

   function Gloss_Write
     (FD  : C_Int;
      Buf : System.Address;
      N   : U64) return C_Int;
   pragma Export (C, Gloss_Write, "_write");

   function Gloss_Write
     (FD  : C_Int;
      Buf : System.Address;
      N   : U64) return C_Int
   is
      use type System.Address;
      Done  : U64 := 0;
      Count : U64;
      St    : U64;
   begin
      Ensure_Bound;
      if FD = 1 or else FD = 2 then
         Write_Console (Buf, N);
         return C_Int (N);
      elsif FD < C_Int (First_File_FD) or else FD > C_Int (Last_FD)
        or else not FDs (Natural (FD)).Used
        or else not FDs (Natural (FD)).Writable
      then
         Fail (EBADF);
         return -1;
      end if;

      declare
         F : FD_Rec renames FDs (Natural (FD));
      begin
         while Done < N loop
            declare
               --  Files.Write chunks through its own 32 KiB shared
               --  buffer; keep calls under it.
               Chunk : constant U64 := U64'Min (N - Done, 16#8000#);
            begin
               St := Files.Write
                 (F.Path (1 .. F.Path_Len), F.Offset,
                  Buf + System.Storage_Elements.Storage_Offset (Done), Chunk, Count);
               if St /= Files.Status_Ok or else Count = 0 then
                  Fail (ENOSPC);
                  return (if Done = 0 then -1 else C_Int (Done));
               end if;
               F.Offset := F.Offset + Count;
               if F.Offset > F.Size then
                  F.Size := F.Offset;
               end if;
               Done := Done + Count;
            end;
         end loop;
         return C_Int (Done);
      end;
   end Gloss_Write;

   function Gloss_Lseek
     (FD     : C_Int;
      Off    : U64;
      Whence : C_Int) return U64;
   pragma Export (C, Gloss_Lseek, "_lseek");

   function Gloss_Lseek
     (FD     : C_Int;
      Off    : U64;
      Whence : C_Int) return U64
   is
   begin
      if FD < C_Int (First_File_FD) or else FD > C_Int (Last_FD)
        or else not FDs (Natural (FD)).Used
      then
         Fail (EBADF);
         return U64'Last;  --  (off_t)-1
      end if;

      declare
         F : FD_Rec renames FDs (Natural (FD));
         Base : U64;
         Sz   : U64;
      begin
         case Whence is
            when SEEK_SET =>
               Base := 0;
            when SEEK_CUR =>
               Base := F.Offset;
            when SEEK_END =>
               --  Fresh stat: another writer may have grown it.
               if Files.Stat (F.Path (1 .. F.Path_Len), Sz)
                    = Files.Status_Ok
               then
                  F.Size := Sz;
               end if;
               Base := F.Size;
            when others =>
               Fail (EINVAL);
               return U64'Last;
         end case;
         F.Offset := Base + Off;
         return F.Offset;
      end;
   end Gloss_Lseek;

   ----------------------------------------------------------------------
   --  stat family.

   S_IFDIR : constant := 8#040000#;

   procedure Fill_Stat
     (S : Stat_Access; Size : U64; Is_TTY : Boolean;
      Is_Dir : Boolean := False) is
   begin
      S.all := (others => <>);
      S.Mode   := U32
        ((if Is_TTY then S_IFCHR
          elsif Is_Dir then S_IFDIR
          else S_IFREG) + S_IRWXU);
      S.NLink  := 1;
      S.Size   := Size;
      S.BlkSize := 512;
      S.Blocks := (Size + 511) / 512;
   end Fill_Stat;

   function Gloss_Fstat (FD : C_Int; S : Stat_Access) return C_Int;
   pragma Export (C, Gloss_Fstat, "_fstat");

   function Gloss_Fstat (FD : C_Int; S : Stat_Access) return C_Int is
      Sz : U64;
   begin
      if FD >= 0 and then FD < C_Int (First_File_FD) then
         Fill_Stat (S, 0, True);
         return 0;
      elsif FD > C_Int (Last_FD)
        or else not FDs (Natural (FD)).Used
      then
         Fail (EBADF);
         return -1;
      end if;
      declare
         F : FD_Rec renames FDs (Natural (FD));
      begin
         if Files.Stat (F.Path (1 .. F.Path_Len), Sz)
              = Files.Status_Ok
         then
            F.Size := Sz;
         end if;
         Fill_Stat (S, F.Size, False);
         return 0;
      end;
   end Gloss_Fstat;

   function Gloss_Stat
     (Path : Interfaces.C.Strings.chars_ptr;
      S    : Stat_Access) return C_Int;
   pragma Export (C, Gloss_Stat, "_stat");

   function Gloss_Stat
     (Path : Interfaces.C.Strings.chars_ptr;
      S    : Stat_Access) return C_Int
   is
      P  : constant String := Qualify (Interfaces.C.Strings.Value (Path));
      Sz : U64;
   begin
      Ensure_Bound;
      if Files.Stat (P, Sz) /= Files.Status_Ok then
         --  53c: the fs Stat rejects DIRECTORIES (fat32-style
         --  Bad_Args). Probe with a by-index Read_Dir so that
         --  stat("some/dir") — and therefore Ada.Directories.
         --  Exists/Kind — sees directories as directories.
         declare
            Junk_N : String (1 .. 32);
            Junk_L : Natural;
            Junk_D : Boolean;
            Junk_S : U64;
         begin
            if Files.Read_Dir (P, 0, Junk_N, Junk_L, Junk_D, Junk_S)
                 = Files.Status_Ok
            then
               Fill_Stat (S, 0, False, Is_Dir => True);
               return 0;
            end if;
         end;
         Fail (ENOENT);
         return -1;
      end if;
      Fill_Stat (S, Sz, False);
      return 0;
   end Gloss_Stat;

   function Gloss_Isatty (FD : C_Int) return C_Int;
   pragma Export (C, Gloss_Isatty, "_isatty");

   function Gloss_Isatty (FD : C_Int) return C_Int is
   begin
      return (if FD >= 0 and then FD < C_Int (First_File_FD)
              then 1 else 0);
   end Gloss_Isatty;

   function Gloss_Unlink (Path : Interfaces.C.Strings.chars_ptr)
     return C_Int;
   pragma Export (C, Gloss_Unlink, "_unlink");

   function Gloss_Unlink (Path : Interfaces.C.Strings.chars_ptr)
     return C_Int
   is
   begin
      Ensure_Bound;
      if Files.Delete (Qualify (Interfaces.C.Strings.Value (Path)))
           /= Files.Status_Ok
      then
         Fail (ENOENT);
         return -1;
      end if;
      return 0;
   end Gloss_Unlink;

   function Gloss_Mkdir
     (Path : Interfaces.C.Strings.chars_ptr;
      Mode : C_Int) return C_Int;
   pragma Export (C, Gloss_Mkdir, "_mkdir");

   function Gloss_Mkdir
     (Path : Interfaces.C.Strings.chars_ptr;
      Mode : C_Int) return C_Int
   is
      pragma Unreferenced (Mode);
   begin
      Ensure_Bound;
      if Files.Mkdir (Qualify (Interfaces.C.Strings.Value (Path)))
           /= Files.Status_Ok
      then
         Fail (ENOENT);
         return -1;
      end if;
      return 0;
   end Gloss_Mkdir;

   function Gloss_Rename
     (Old_Path, New_Path : Interfaces.C.Strings.chars_ptr) return C_Int;
   pragma Export (C, Gloss_Rename, "_rename");

   function Gloss_Rename
     (Old_Path, New_Path : Interfaces.C.Strings.chars_ptr) return C_Int
   is
   begin
      Ensure_Bound;
      if Files.Rename
           (Qualify (Interfaces.C.Strings.Value (Old_Path)),
            Qualify (Interfaces.C.Strings.Value (New_Path)))
           /= Files.Status_Ok
      then
         Fail (EPERM);
         return -1;
      end if;
      return 0;
   end Gloss_Rename;

   function Gloss_Mkdir_Alias
     (Path : Interfaces.C.Strings.chars_ptr; Mode : C_Int)
     return C_Int;
   pragma Export (C, Gloss_Mkdir_Alias, "mkdir");
   --  53c: the vendored mkdir.c (__gnat_mkdir, used by
   --  Ada.Directories.Create_Directory) calls plain mkdir(2),
   --  which this newlib does not carry.

   function Gloss_Mkdir_Alias
     (Path : Interfaces.C.Strings.chars_ptr; Mode : C_Int)
     return C_Int is
   begin
      return Gloss_Mkdir (Path, Mode);
   end Gloss_Mkdir_Alias;

   ----------------------------------------------------------------------
   --  Process / misc.

   function Gloss_Sbrk (Incr : Interfaces.C.ptrdiff_t)
     return System.Address;
   pragma Export (C, Gloss_Sbrk, "_sbrk");

   function Gloss_Sbrk (Incr : Interfaces.C.ptrdiff_t)
     return System.Address
   is
      use type Interfaces.C.ptrdiff_t;
      Need : U64;
   begin
      if Incr < 0 then
         Fail (ENOMEM);
         return Neg1_Address;
      end if;
      Need := Sbrk_Break + U64 (Incr);
      while Need > Sbrk_Mapped loop
         declare
            Page_Index : constant U64 := Sbrk_Mapped / Page_Bytes;
            Chunk      : constant Natural :=
              Natural (Page_Index / Sbrk_Chunk_Pgs);
            In_Chunk   : constant U64 := Page_Index mod Sbrk_Chunk_Pgs;
            Result     : U64;
         begin
            if Chunk >= Sbrk_Max_Chunk then
               Fail (ENOMEM);
               return Neg1_Address;
            end if;
            if Sbrk_Caps (Chunk) = 0 then
               Result := Syscalls.Mem_Alloc (Sbrk_Chunk_Pgs);
               if Result = Syscalls.Syscall_Failed then
                  Fail (ENOMEM);
                  return Neg1_Address;
               end if;
               Sbrk_Caps (Chunk) := Result;
            end if;
            if Syscalls.Mem_Map
                 (Address_Space => Syscalls.Address_Space_Cap,
                  Cap           => Sbrk_Caps (Chunk),
                  VA            => Sbrk_Base + Sbrk_Mapped,
                  Offset        => In_Chunk * Page_Bytes,
                  Length        => Page_Bytes,
                  Flags         => 3) /= 0
            then
               Fail (ENOMEM);
               return Neg1_Address;
            end if;
            Sbrk_Mapped := Sbrk_Mapped + Page_Bytes;
         end;
      end loop;

      declare
         Old : constant U64 := Sbrk_Base + Sbrk_Break;
      begin
         Sbrk_Break := Need;
         return System.Storage_Elements.To_Address
           (System.Storage_Elements.Integer_Address (Old));
      end;
   end Gloss_Sbrk;

   procedure Gloss_Exit (Code : C_Int);
   pragma Export (C, Gloss_Exit, "_exit");

   procedure Gloss_Exit (Code : C_Int) is
   begin
      if Console.Redirected then
         Console.Close_Redirect;
      end if;
      Syscalls.Process_Exit (U64 (Code));
      loop
         null;  --  unreachable: Process_Exit does not return
      end loop;
   end Gloss_Exit;

   function Gloss_Getpid return C_Int;
   pragma Export (C, Gloss_Getpid, "_getpid");

   function Gloss_Getpid return C_Int is
   begin
      return 1;
   end Gloss_Getpid;

   --  Wall clock (milestone 55): seed once, then synthesize from
   --  the rdtime CSR (10 MHz on qemu virt — akernel_rtclock.c).
   --  Seed order: semihosting SYS_TIME (host wall clock when qemu
   --  runs with -semihosting; the kernel's breakpoint handler
   --  answers -1 otherwise), then the baked RD0:System/Epoch file
   --  (build time stamped by the Makefile), then epoch 0 (the old
   --  m53 stub behavior). Monotonic within a boot by
   --  construction; a real RTC device can replace the seed later.
   Clock_Seeded : Boolean := False;
   Epoch_Seed   : U64 := 0;
   Ticks_Seed   : U64 := 0;
   Tick_Hz      : constant U64 := 10_000_000;

   --  Semihosting SYS_TIME probe (17): the guard sequence makes
   --  qemu -semihosting intercept the ebreak; without it the
   --  kernel's breakpoint handler sees the a7 magic, answers -1
   --  and skips. Inline asm so the syscall-RTS programs that link
   --  gloss without libgnat still resolve it.
   function SH_Time return Long_Long_Integer is
      Result : Long_Long_Integer;
   begin
      --  Magic baked as an immediate: 16#5E41_C10C# = the
      --  SH_Clock_Magic handshake in arch-traps.adb.
      System.Machine_Code.Asm
        (Template =>
           "li a7, 0x5E41C10C" & ASCII.LF &
           "li a0, 17" & ASCII.LF &
           "li a1, 0" & ASCII.LF &
           "slli x0, x0, 0x1f" & ASCII.LF &
           "ebreak" & ASCII.LF &
           "srli x0, x0, 7" & ASCII.LF &
           "mv %0, a0",
         Outputs  => Long_Long_Integer'Asm_Output ("=r", Result),
         Clobber  => "a0, a1, a7, memory",
         Volatile => True);
      return Result;
   end SH_Time;

   function Rdtime return U64 is
      Result : U64;
   begin
      System.Machine_Code.Asm
        (Template => "csrr %0, time",
         Outputs  => U64'Asm_Output ("=r", Result),
         Clobber  => "memory",
         Volatile => True);
      return Result;
   end Rdtime;

   procedure Seed_Clock is
      SH  : constant Long_Long_Integer := SH_Time;
      Buf : String (1 .. 32);
      Cnt : U64;
      St  : U64;
      Acc : U64 := 0;
      Got : Boolean := False;
   begin
      if SH > 0 then
         Epoch_Seed := U64 (SH);
      else
         --  Baked build epoch: RD0:System/Epoch holds decimal
         --  seconds, one line, stamped at image build time.
         Ensure_Bound;
         St := Files.Read ("RD0:System/Epoch", 0, Buf'Address,
                           U64 (Buf'Length), Cnt);
         if St = Files.Status_Ok and then Cnt > 0 then
            for I in 1 .. Natural (Cnt) loop
               exit when Buf (I) not in '0' .. '9';
               Acc := Acc * 10
                 + U64 (Character'Pos (Buf (I))
                        - Character'Pos ('0'));
               Got := True;
            end loop;
         end if;
         if Got then
            Epoch_Seed := Acc;
         end if;
      end if;
      Ticks_Seed := Rdtime;
      Clock_Seeded := True;
   end Seed_Clock;

   function Gloss_Gettimeofday (TV, TZ : System.Address) return C_Int;
   pragma Export (C, Gloss_Gettimeofday, "_gettimeofday");

   function Gloss_Gettimeofday (TV, TZ : System.Address) return C_Int is
      pragma Unreferenced (TZ);
      type U64_Pair is array (1 .. 2) of U64;
      TVW     : U64_Pair with Address => TV;
      Elapsed : U64;
   begin
      if not Clock_Seeded then
         Seed_Clock;
      end if;
      Elapsed := Rdtime - Ticks_Seed;
      TVW := (Epoch_Seed + Elapsed / Tick_Hz,
              (Elapsed mod Tick_Hz) * 1_000_000 / Tick_Hz);
      return 0;
   end Gloss_Gettimeofday;

   function Gloss_Times (Buf : System.Address) return U64;
   pragma Export (C, Gloss_Times, "_times");

   function Gloss_Times (Buf : System.Address) return U64 is
      type U64_Quad is array (1 .. 4) of U64;
      TMS : U64_Quad with Address => Buf;
   begin
      TMS := (others => 0);
      return 0;
   end Gloss_Times;

   ----------------------------------------------------------------------
   --  Unimplementable stubs: fail ENOSYS so newlib wrappers return
   --  -1 cleanly instead of crashing.

   function Gloss_Stub_PID_Sig (A, B : C_Int) return C_Int;
   pragma Export (C, Gloss_Stub_PID_Sig, "_kill");

   function Gloss_Stub_PID_Sig (A, B : C_Int) return C_Int is
      pragma Unreferenced (A, B);
   begin
      Fail (ENOSYS);
      return -1;
   end Gloss_Stub_PID_Sig;

   function Gloss_Stub_Noargs return C_Int;
   pragma Export (C, Gloss_Stub_Noargs, "_fork");

   function Gloss_Stub_Noargs return C_Int is
   begin
      Fail (ENOSYS);
      return -1;
   end Gloss_Stub_Noargs;

   function Gloss_Stub_Path (Path : Interfaces.C.Strings.chars_ptr)
     return C_Int;
   pragma Export (C, Gloss_Stub_Path, "_chdir");

   function Gloss_Stub_Path (Path : Interfaces.C.Strings.chars_ptr)
     return C_Int
   is
      --  53c: chdir writes ENV:CWD (the m42 cwd convention), Amiga-
      --  style. Relative targets qualify against the current cwd.
      P : constant String :=
        Qualify (Interfaces.C.Strings.Value (Path));
   begin
      Ensure_Bound;
      if Set_CWD (P) /= Files.Status_Ok then
         Fail (ENOENT);
         return -1;
      end if;
      return 0;
   end Gloss_Stub_Path;

   function Gloss_Stub_Exec
     (Path : Interfaces.C.Strings.chars_ptr;
      Argv : System.Address;
      Envp : System.Address) return C_Int;
   pragma Export (C, Gloss_Stub_Exec, "_execve");

   function Gloss_Stub_Exec
     (Path : Interfaces.C.Strings.chars_ptr;
      Argv : System.Address;
      Envp : System.Address) return C_Int
   is
      pragma Unreferenced (Path, Argv, Envp);
   begin
      Fail (ENOSYS);
      return -1;
   end Gloss_Stub_Exec;

   function Gloss_Stub_Wait (Status : access C_Int) return C_Int;
   pragma Export (C, Gloss_Stub_Wait, "_wait");

   function Gloss_Stub_Wait (Status : access C_Int) return C_Int is
   begin
      Status.all := 0;
      Fail (ENOSYS);
      return -1;
   end Gloss_Stub_Wait;

   function Gloss_Stub_Link
     (Old_Path, New_Path : Interfaces.C.Strings.chars_ptr) return C_Int;
   pragma Export (C, Gloss_Stub_Link, "_link");

   function Gloss_Stub_Link
     (Old_Path, New_Path : Interfaces.C.Strings.chars_ptr) return C_Int
   is
      pragma Unreferenced (Old_Path, New_Path);
   begin
      Fail (ENOSYS);
      return -1;
   end Gloss_Stub_Link;

   function Gloss_Fcntl (FD, Cmd, Arg : C_Int) return C_Int;
   pragma Export (C, Gloss_Fcntl, "_fcntl");

   function Gloss_Fcntl (FD, Cmd, Arg : C_Int) return C_Int is
      pragma Unreferenced (Cmd, Arg);
   begin
      if FD < C_Int (First_File_FD)
        or else (FD <= C_Int (Last_FD)
                 and then FDs (Natural (FD)).Used)
      then
         return 0;
      end if;
      Fail (EBADF);
      return -1;
   end Gloss_Fcntl;

   ----------------------------------------------------------------------
   --  Second stub tier (53b): plain POSIX names adaint.c/sysdep.c
   --  reference that this newlib leaves to libgloss. Anything the
   --  fs protocol can answer is real (rmdir/access); process and
   --  tty/symlink semantics fail ENOSYS until their milestones.

   function Gloss_Rmdir (Path : Interfaces.C.Strings.chars_ptr)
     return C_Int;
   pragma Export (C, Gloss_Rmdir, "rmdir");

   function Gloss_Rmdir (Path : Interfaces.C.Strings.chars_ptr)
     return C_Int
   is
   begin
      Ensure_Bound;
      if Files.Rmdir (Qualify (Interfaces.C.Strings.Value (Path)))
           /= Files.Status_Ok
      then
         Fail (ENOENT);
         return -1;
      end if;
      return 0;
   end Gloss_Rmdir;

   function Gloss_Access (Path : Interfaces.C.Strings.chars_ptr;
                          Mode : C_Int) return C_Int;
   pragma Export (C, Gloss_Access, "access");

   function Gloss_Access (Path : Interfaces.C.Strings.chars_ptr;
                          Mode : C_Int) return C_Int
   is
      pragma Unreferenced (Mode);  --  no permission model yet
      Sz : U64;
   begin
      Ensure_Bound;
      if Files.Stat (Qualify (Interfaces.C.Strings.Value (Path)), Sz)
           /= Files.Status_Ok
      then
         Fail (ENOENT);
         return -1;
      end if;
      return 0;
   end Gloss_Access;

   function Gloss_Getcwd (Buf : System.Address; Size : U64)
     return System.Address;
   pragma Export (C, Gloss_Getcwd, "getcwd");

   function Gloss_Getcwd (Buf : System.Address; Size : U64)
     return System.Address
   is
      --  53c: ENV:CWD-backed (m42 convention).
      S : String (1 .. 257) with Address => Buf;
   begin
      Ensure_Bound;
      declare
         Cwd : constant String := Get_CWD;
      begin
         if Buf = System.Null_Address
           or else Size < U64 (Cwd'Length + 1)
         then
            Fail (EINVAL);
            return System.Null_Address;
         end if;
         S (1 .. Cwd'Length + 1) := Cwd & Character'Val (0);
      end;
      return Buf;
   end Gloss_Getcwd;

   function Gloss_Chmod (Path : Interfaces.C.Strings.chars_ptr;
                         Mode : C_Int) return C_Int;
   pragma Export (C, Gloss_Chmod, "chmod");

   function Gloss_Chmod (Path : Interfaces.C.Strings.chars_ptr;
                         Mode : C_Int) return C_Int
   is
      pragma Unreferenced (Path, Mode);
   begin
      return 0;  --  no permission model: pretend success
   end Gloss_Chmod;

   function Gloss_Ttyname (FD : C_Int) return Interfaces.C.Strings.chars_ptr;
   pragma Export (C, Gloss_Ttyname, "ttyname");

   function Gloss_Ttyname (FD : C_Int) return Interfaces.C.Strings.chars_ptr
   is
      pragma Unreferenced (FD);
   begin
      return Interfaces.C.Strings.New_String ("console");
   end Gloss_Ttyname;

   function Gloss_Sysconf (Name : C_Int) return U64;
   pragma Export (C, Gloss_Sysconf, "sysconf");

   function Gloss_Sysconf (Name : C_Int) return U64 is
      pragma Unreferenced (Name);
   begin
      return 4096;  --  page size; the only value callers want
   end Gloss_Sysconf;

   function Gloss_Getppid return C_Int;
   pragma Export (C, Gloss_Getppid, "getppid");

   function Gloss_Getppid return C_Int is
   begin
      return 1;
   end Gloss_Getppid;

   function Gloss_Stup1 (A : C_Int) return C_Int;
   pragma Export (C, Gloss_Stup1, "dup");

   function Gloss_Stup1 (A : C_Int) return C_Int is
      pragma Unreferenced (A);
   begin
      Fail (ENOSYS);
      return -1;
   end Gloss_Stup1;

   function Gloss_Stup2 (A, B : C_Int) return C_Int;
   pragma Export (C, Gloss_Stup2, "dup2");

   function Gloss_Stup2 (A, B : C_Int) return C_Int is
      pragma Unreferenced (A, B);
   begin
      Fail (ENOSYS);
      return -1;
   end Gloss_Stup2;

   function Gloss_Execv (Path : Interfaces.C.Strings.chars_ptr;
                         Argv : System.Address) return C_Int;
   pragma Export (C, Gloss_Execv, "execv");

   function Gloss_Execv (Path : Interfaces.C.Strings.chars_ptr;
                         Argv : System.Address) return C_Int
   is
      pragma Unreferenced (Path, Argv);
   begin
      Fail (ENOSYS);
      return -1;
   end Gloss_Execv;

   function Gloss_Readlink (Path : Interfaces.C.Strings.chars_ptr;
                            Buf  : System.Address;
                            Size : U64) return C_Int;
   pragma Export (C, Gloss_Readlink, "readlink");

   function Gloss_Readlink (Path : Interfaces.C.Strings.chars_ptr;
                            Buf  : System.Address;
                            Size : U64) return C_Int
   is
      pragma Unreferenced (Path, Buf, Size);
   begin
      Fail (ENOSYS);
      return -1;
   end Gloss_Readlink;

   function Gloss_Symlink (Old_Path, New_Path : Interfaces.C.Strings.chars_ptr)
     return C_Int;
   pragma Export (C, Gloss_Symlink, "symlink");

   function Gloss_Symlink (Old_Path, New_Path : Interfaces.C.Strings.chars_ptr)
     return C_Int
   is
      pragma Unreferenced (Old_Path, New_Path);
   begin
      Fail (ENOSYS);
      return -1;
   end Gloss_Symlink;

   function Gloss_Waitpid (Pid : C_Int; Status : access C_Int;
                           Options : C_Int) return C_Int;
   pragma Export (C, Gloss_Waitpid, "waitpid");

   function Gloss_Waitpid (Pid : C_Int; Status : access C_Int;
                           Options : C_Int) return C_Int
   is
      pragma Unreferenced (Pid, Options);
   begin
      if Status /= null then
         Status.all := 0;
      end if;
      Fail (ENOSYS);
      return -1;
   end Gloss_Waitpid;

   function Gloss_Utimensat (Dir_FD : C_Int;
                             Path   : Interfaces.C.Strings.chars_ptr;
                             Times  : System.Address;
                             Flags  : C_Int) return C_Int;
   pragma Export (C, Gloss_Utimensat, "utimensat");

   function Gloss_Utimensat (Dir_FD : C_Int;
                             Path   : Interfaces.C.Strings.chars_ptr;
                             Times  : System.Address;
                             Flags  : C_Int) return C_Int
   is
      pragma Unreferenced (Dir_FD, Path, Times, Flags);
   begin
      return 0;  --  fs keeps no timestamps: pretend success
   end Gloss_Utimensat;

   function Gloss_Chdir (Path : Interfaces.C.Strings.chars_ptr)
     return C_Int;
   pragma Export (C, Gloss_Chdir, "chdir");

   function Gloss_Chdir (Path : Interfaces.C.Strings.chars_ptr)
     return C_Int
   is
      --  Same ENV:CWD write as _chdir above (Ada.Directories
      --  Set_Directory calls the plain "chdir" name).
      P : constant String :=
        Qualify (Interfaces.C.Strings.Value (Path));
   begin
      Ensure_Bound;
      if Set_CWD (P) /= Files.Status_Ok then
         Fail (ENOENT);
         return -1;
      end if;
      return 0;
   end Gloss_Chdir;

   --  libgcc rv64 hard-float does not build the soft-TF helpers,
   --  but newlib's vfprintf references __trunctfdf2 from its %Lf
   --  branch. We never format long doubles; satisfy the link here
   --  (gloss.o is always pulled via the -u in akernel_program.gpr,
   --  unlike libgnat members, which sit after the libc GROUP).
   function Trunc_TF_Stub return Long_Float;
   pragma Export (C, Trunc_TF_Stub, "__trunctfdf2");

   function Trunc_TF_Stub return Long_Float is
   begin
      return 0.0;
   end Trunc_TF_Stub;

   --  Note: NO _<op>_r reentrant spellings here — this newlib
   --  provides them inside libc (reent/readr.c etc.) as wrappers
   --  over the plain _<op> names. Defining our own collided as
   --  multiple definitions once libc.a joined the link (53b).

begin
   null;  --  body present for state; binding is lazy (below)
end Akernel_User.Gloss;
