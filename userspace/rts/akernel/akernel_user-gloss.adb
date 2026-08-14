with System;
with System.Storage_Elements;  use System.Storage_Elements;
with Interfaces.C;
with Interfaces.C.Strings;
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
      P       : constant String :=
        Interfaces.C.Strings.Value (Path);
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
         if St /= Files.Status_Ok then
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

   procedure Fill_Stat (S : Stat_Access; Size : U64; Is_TTY : Boolean) is
   begin
      S.all := (others => <>);
      S.Mode   := U32
        ((if Is_TTY then S_IFCHR else S_IFREG) + S_IRWXU);
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
      P  : constant String := Interfaces.C.Strings.Value (Path);
      Sz : U64;
   begin
      Ensure_Bound;
      if Files.Stat (P, Sz) /= Files.Status_Ok then
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
      if Files.Delete (Interfaces.C.Strings.Value (Path))
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
      if Files.Mkdir (Interfaces.C.Strings.Value (Path))
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
           (Interfaces.C.Strings.Value (Old_Path),
            Interfaces.C.Strings.Value (New_Path)) /= Files.Status_Ok
      then
         Fail (EPERM);
         return -1;
      end if;
      return 0;
   end Gloss_Rename;

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

   function Gloss_Gettimeofday (TV, TZ : System.Address) return C_Int;
   pragma Export (C, Gloss_Gettimeofday, "_gettimeofday");

   function Gloss_Gettimeofday (TV, TZ : System.Address) return C_Int is
      pragma Unreferenced (TZ);
      type U64_Pair is array (1 .. 2) of U64;
      TVW : U64_Pair with Address => TV;
   begin
      --  No wall clock yet (the RTC/Calendar milestone): report
      --  epoch so callers see a stable zero rather than an error.
      TVW := (0, 0);
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
      pragma Unreferenced (Path);
   begin
      Fail (ENOSYS);
      return -1;
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
      if Files.Rmdir (Interfaces.C.Strings.Value (Path))
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
      if Files.Stat (Interfaces.C.Strings.Value (Path), Sz)
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
      --  53c upgrades this to ENV:CWD; "/" is the honest root.
      S : String (1 .. 2) with Address => Buf;
   begin
      if Buf = System.Null_Address or else Size < 2 then
         Fail (EINVAL);
         return System.Null_Address;
      end if;
      S := '/' & Character'Val (0);
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
      pragma Unreferenced (Path);
   begin
      Fail (ENOSYS);  --  53c: ENV:CWD
      return -1;
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
