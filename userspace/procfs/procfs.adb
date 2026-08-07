with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Console;

--  Procfs (milestone 37b): kernel introspection as a filesystem.
--  Serves the file protocol subset (stat/open/read/readdir) on its
--  service endpoint; init mounts it on the VFS via Op_Add_FS as
--  device/label "Proc". Every file is rendered on demand from
--  process_info snapshots (syscall 30) — the kernel returns binary
--  records, this server formats text. Read-only; mutating ops are
--  rejected like boot-file volumes.
--
--  Namespace (paths arrive without the "Proc:" prefix):
--    ""              directory: "tree" + one dir per live process
--    "tree"          the whole process forest, indented by spawner
--    "<pid>"         directory: "status"
--    "<pid>/status"  key-value snapshot of one process
--
--  Grant layout (manifest): 1 = console Send, 2 = service endpoint
--  Receive (procfs_server token), 3 = device_resource
--  (Kernel_Object+Manage — introspection authority).

procedure Procfs is
   subtype U64 is Interfaces.Unsigned_64;
   use type U64;

   package Syscalls renames Akernel_User.Syscalls;

   Console_Cap  : constant U64 := 1;
   Svc_EP       : constant U64 := 2;
   Resource_Cap : constant U64 := 3;

   Op_Stat     : constant U64 := 1;
   Op_Open     : constant U64 := 2;
   Op_Read     : constant U64 := 3;
   Op_Write    : constant U64 := 7;
   Op_Delete   : constant U64 := 8;
   Op_Truncate : constant U64 := 9;
   Op_Mkdir    : constant U64 := 10;
   Op_Rmdir    : constant U64 := 11;
   Op_Sync     : constant U64 := 12;
   Op_ReadDir  : constant U64 := 13;

   Status_Ok           : constant U64 := 0;
   Status_Not_Found    : constant U64 := 1;
   Status_Bad_Args     : constant U64 := 3;
   Status_Out_Of_Range : constant U64 := 4;

   --  VA windows: the process_info destination page, the client
   --  read buffer (mapped per Op_Read, deleted after), and the
   --  render scratch page.
   Info_VA    : constant U64 := 16#5400_0000#;
   Buf_Win_VA : constant U64 := 16#5440_0000#;
   Render_VA  : constant U64 := 16#5460_0000#;
   Buf_Pages  : constant U64 := 8;
   Buf_Bytes  : constant U64 := Buf_Pages * Syscalls.Page_Size;

   Info_Cap   : U64 := 0;
   Render_Cap : U64 := 0;

   function To_Address
     (Value : U64) return System.Address
   is
   begin
      return System'To_Address
        (System.Storage_Elements.Integer_Address (Value));
   end To_Address;

   function Shl (Value : U64; Amount : Natural) return U64
     renames Interfaces.Shift_Left;

   --  process_info destination page (the kernel writes the
   --  64-byte record at offset 0 through the physmap).
   type Info_Words is array (0 .. 7) of U64;
   Info : Info_Words
     with Volatile, Address => To_Address (Info_VA);

   --  Render scratch page + cursor (library level: big buffers
   --  never live on the 16 KiB stack).
   Render_Size : constant Natural := 4096;
   type Render_Chars is array (0 .. Render_Size - 1) of Character;
   Render_Page : Render_Chars
     with Volatile, Address => To_Address (Render_VA);
   Render_Len : Natural := 0;

   LF : constant Character := Character'Val (10);

   procedure Put_Char (C : Character) is
   begin
      if Render_Len < Render_Size then
         Render_Page (Render_Len) := C;
         Render_Len := Render_Len + 1;
      end if;
   end Put_Char;

   procedure Put_Str (S : String) is
   begin
      for C of S loop
         Put_Char (C);
      end loop;
   end Put_Str;

   procedure Put_Dec (Value : U64) is
      Digs   : String (1 .. 20);
      Len    : Natural := 0;
      V      : U64 := Value;
   begin
      if V = 0 then
         Put_Char ('0');
         return;
      end if;
      while V /= 0 loop
         Len := Len + 1;
         Digs (Len) := Character'Val
           (Character'Pos ('0') + Natural (V mod 10));
         V := V / 10;
      end loop;
      for I in reverse 1 .. Len loop
         Put_Char (Digs (I));
      end loop;
   end Put_Dec;

   Hex_Digits : constant String := "0123456789abcdef";

   procedure Put_Hex (Value : U64) is
   begin
      Put_Str ("0x");
      for Shift in reverse 0 .. 15 loop
         Put_Char
           (Hex_Digits
              (Natural
                 (Interfaces.Shift_Right (Value, Shift * 4)
                    and 16#F#) + 1));
      end loop;
   end Put_Hex;

   ------------------------------------------------------------------
   --  Snapshot collection
   ------------------------------------------------------------------

   --  Walk bound = the spawn-table size (userspace mirror in
   --  the syscalls package; kernel Max_Process_Slots).
   Max_Slots : constant := Syscalls.Process_Table_Slots;

   type Proc_Snap is record
      Live      : Boolean := False;
      Pid       : U64 := 0;
      Spawner   : U64 := 0;
      Lifecycle : U64 := 0;
      Thr       : U64 := 0;
      Caps      : U64 := 0;
      Flags     : U64 := 0;
      Endpoint  : U64 := 0;
      Badge     : U64 := 0;
   end record;

   Snaps      : array (0 .. Max_Slots - 1) of Proc_Snap;
   Live_Count : Natural := 0;

   function Query (Slot : U64) return Boolean is
   begin
      return Syscalls.Process_Info
        (Resource => Resource_Cap,
         Slot     => Slot,
         Buffer   => Info_Cap,
         Offset   => 0) = Syscalls.Info_Ok;
   end Query;

   procedure Snapshot is
   begin
      Live_Count := 0;
      for S in Snaps'Range loop
         if Query (U64 (S)) then
            Snaps (S) :=
              (Live      => True,
               Pid       => Info (0),
               Spawner   => Info (1),
               Lifecycle => Info (2),
               Thr       => Info (3),
               Caps      => Info (4),
               Flags     => Info (5),
               Endpoint  => Info (6),
               Badge     => Info (7));
            Live_Count := Live_Count + 1;
         else
            Snaps (S).Live := False;
         end if;
      end loop;
   end Snapshot;

   function Is_Live (Pid : U64) return Boolean is
   begin
      for S of Snaps loop
         if S.Live and then S.Pid = Pid then
            return True;
         end if;
      end loop;
      return False;
   end Is_Live;

   function Find_Pid (Pid : U64) return Natural is
   begin
      for S in Snaps'Range loop
         if Snaps (S).Live and then Snaps (S).Pid = Pid then
            return S;
         end if;
      end loop;
      return Max_Slots;  --  not found sentinel
   end Find_Pid;

   ------------------------------------------------------------------
   --  Rendering
   ------------------------------------------------------------------

   function Lifecycle_Name (State : U64) return String is
     (case State is
         when 0      => "initializing",
         when 1      => "alive",
         when 2      => "dead",
         when others => "?");

   function Thread_Name (State : U64) return String is
     (case State is
         when 0      => "ready",
         when 1      => "running",
         when 2      => "blocked-send",
         when 3      => "blocked-receive",
         when 4      => "blocked-irq",
         when 5      => "blocked-notification",
         when 6      => "dead",
         when others => "?");

   --  "tree": the forest, roots first (spawner dead or kernel),
   --  children indented two spaces per depth. Depth-capped; a
   --  full render page just stops (32 processes fit in ~2 KiB).
   procedure Render_Node (Idx : Natural; Depth : Natural) is
   begin
      if Depth > 8 then
         return;
      end if;
      for D in 1 .. Depth loop
         Put_Str ("  ");
      end loop;
      Put_Str ("pid ");
      Put_Dec (Snaps (Idx).Pid);
      Put_Char (' ');
      Put_Str (Lifecycle_Name (Snaps (Idx).Lifecycle));
      Put_Char ('/');
      Put_Str (Thread_Name (Snaps (Idx).Thr));
      Put_Str (" caps=");
      Put_Dec (Snaps (Idx).Caps);
      if Snaps (Idx).Spawner = 0 then
         Put_Str (" (kernel)");
      else
         Put_Str (" spawner ");
         Put_Dec (Snaps (Idx).Spawner);
      end if;
      Put_Char (LF);
      for S in Snaps'Range loop
         if Snaps (S).Live
           and then Snaps (S).Spawner = Snaps (Idx).Pid
         then
            Render_Node (S, Depth + 1);
         end if;
      end loop;
   end Render_Node;

   procedure Render_Tree is
   begin
      Render_Len := 0;
      Snapshot;
      for S in Snaps'Range loop
         if Snaps (S).Live
           and then (Snaps (S).Spawner = 0
                       or else not Is_Live (Snaps (S).Spawner))
         then
            Render_Node (S, 0);
         end if;
      end loop;
   end Render_Tree;

   --  "<pid>/status": one snapshot as key-value lines.
   procedure Render_Status (Idx : Natural) is
      Flags : constant U64 := Snaps (Idx).Flags;
      Any   : Boolean := False;
   begin
      Render_Len := 0;
      Put_Str ("process ");
      Put_Dec (Snaps (Idx).Pid);
      Put_Char (LF);
      Put_Str ("spawner ");
      if Snaps (Idx).Spawner = 0 then
         Put_Str ("kernel");
      else
         Put_Dec (Snaps (Idx).Spawner);
      end if;
      Put_Char (LF);
      Put_Str ("lifecycle ");
      Put_Str (Lifecycle_Name (Snaps (Idx).Lifecycle));
      Put_Char (LF);
      Put_Str ("thread ");
      Put_Str (Thread_Name (Snaps (Idx).Thr));
      Put_Char (LF);
      Put_Str ("caps ");
      Put_Dec (Snaps (Idx).Caps);
      Put_Char (LF);
      Put_Str ("flags");
      if (Flags and 1) /= 0 then
         Put_Str (" awaiting-reply");
         Any := True;
      end if;
      if (Flags and 2) /= 0 then
         Put_Str (" reply-wanted");
         Any := True;
      end if;
      if (Flags and 4) /= 0 then
         Put_Str (" boosted");
         Any := True;
      end if;
      if (Flags and 8) /= 0 then
         Put_Str (" queued");
         Any := True;
      end if;
      if not Any then
         Put_Str (" -");
      end if;
      Put_Char (LF);
      Put_Str ("endpoint ");
      Put_Hex (Snaps (Idx).Endpoint);
      Put_Char (LF);
      Put_Str ("badge ");
      Put_Hex (Snaps (Idx).Badge);
      Put_Char (LF);
   end Render_Status;

   ------------------------------------------------------------------
   --  Request plumbing
   ------------------------------------------------------------------

   procedure Reply2 (Status : U64; Value : U64) is
   begin
      Syscalls.Message.Words (0) := Status;
      Syscalls.Message.Words (1) := Value;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply /= Syscalls.IPC_Ok then
         Akernel_User.Console.Put_Line ("procfs reply failed");
         Syscalls.Process_Exit;
      end if;
   end Reply2;

   --  Unpack a NUL-padded path from message words First..First+3.
   function Path_Of (First : Natural) return String is
      Name : String (1 .. 32) := (others => Character'Val (0));
      Len  : Natural := 0;
   begin
      for P in 0 .. 31 loop
         declare
            Ch : constant Character :=
              Character'Val (Natural
                ((Syscalls.Message.Words (First + P / 8)
                    / Shl (1, (P mod 8) * 8)) and 16#FF#));
         begin
            exit when Ch = Character'Val (0);
            Len := Len + 1;
            Name (Len) := Ch;
         end;
      end loop;
      return Name (1 .. Len);
   end Path_Of;

   function To_Lower (C : Character) return Character
   is (if C in 'A' .. 'Z'
       then Character'Val (Character'Pos (C) + 32)
       else C);

   function Match (Text : String; Against : String) return Boolean is
   begin
      if Text'Length /= Against'Length then
         return False;
      end if;
      for I in Text'Range loop
         if To_Lower (Text (I))
           /= To_Lower (Against (Against'First + (I - Text'First)))
         then
            return False;
         end if;
      end loop;
      return True;
   end Match;

   --  Decimal pid component -> its live snapshot index (or the
   --  not-found sentinel).
   function Pid_Component (Text : String) return Natural is
      Value : U64 := 0;
   begin
      if Text'Length = 0 or else Text'Length > 10 then
         return Max_Slots;
      end if;
      for C of Text loop
         if C not in '0' .. '9' then
            return Max_Slots;
         end if;
         Value := Value * 10
           + U64 (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      return Find_Pid (Value);
   end Pid_Component;

   --  Resolve a path against a fresh snapshot. Kind: 0 = not
   --  found, 1 = root dir, 2 = tree file, 3 = process dir,
   --  4 = status file; Idx is the snapshot index for 3/4.
   procedure Resolve
     (Path : String;
      Kind : out Natural;
      Idx  : out Natural)
   is
      Slash : Natural := 0;
   begin
      Kind := 0;
      Idx := Max_Slots;
      Snapshot;

      if Path'Length = 0 then
         Kind := 1;
         return;
      end if;

      if Match (Path, "tree") then
         Kind := 2;
         return;
      end if;

      for I in Path'Range loop
         if Path (I) = '/' then
            Slash := I;
            exit;
         end if;
      end loop;

      if Slash = 0 then
         Idx := Pid_Component (Path);
         if Idx < Max_Slots then
            Kind := 3;
         end if;
      else
         Idx := Pid_Component (Path (Path'First .. Slash - 1));
         if Idx < Max_Slots
           and then Match (Path (Slash + 1 .. Path'Last), "status")
         then
            Kind := 4;
         end if;
      end if;
   end Resolve;

   ------------------------------------------------------------------
   --  Op_Stat / Op_Open
   ------------------------------------------------------------------

   procedure Handle_Stat_Or_Open is
      Kind : Natural;
      Idx  : Natural;
   begin
      Resolve (Path_Of (0), Kind, Idx);
      case Kind is
         when 2 =>
            Render_Tree;
            Reply2 (Status_Ok, U64 (Render_Len));
         when 4 =>
            Render_Status (Idx);
            Reply2 (Status_Ok, U64 (Render_Len));
         when 1 | 3 =>
            Reply2 (Status_Bad_Args, 0);  --  no dir stat/open
         when others =>
            Reply2 (Status_Not_Found, 0);
      end case;
   end Handle_Stat_Or_Open;

   ------------------------------------------------------------------
   --  Op_Read
   ------------------------------------------------------------------

   procedure Handle_Read is
      Offset : constant U64 := Syscalls.Message.Words (0);
      Length : constant U64 := Syscalls.Message.Words (1);
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      Count  : U64 := 0;
      Status : U64 := Status_Ok;
      Mapped : Boolean := False;
      Kind   : Natural;
      Idx    : Natural;
   begin
      if Buf = 0 or else Length = 0 then
         Status := Status_Bad_Args;
      else
         Resolve (Path_Of (2), Kind, Idx);
         case Kind is
            when 2 =>
               Render_Tree;
            when 4 =>
               Render_Status (Idx);
            when others =>
               Status := Status_Not_Found;
         end case;
      end if;

      if Status = Status_Ok then
         if Offset >= U64 (Render_Len) then
            Status := Status_Out_Of_Range;
         else
            Count := U64'Min (Length, U64 (Render_Len) - Offset);
            Count := U64'Min (Count, Buf_Bytes);

            if Syscalls.Mem_Map
                 (Address_Space => Syscalls.Address_Space_Cap,
                  Cap           => Buf,
                  VA            => Buf_Win_VA,
                  Offset        => 0,
                  Length        => Buf_Bytes,
                  Flags         => 3) = 0
            then
               Mapped := True;
               declare
                  type Byte_Array is
                    array (0 .. Count - 1) of Character;
                  Src : Byte_Array
                    with Address => To_Address
                      (Render_VA + Offset);
                  Dst : Byte_Array
                    with Address => To_Address (Buf_Win_VA);
               begin
                  Dst := Src;
               end;
            else
               Status := Status_Not_Found;
               Count := 0;
            end if;
         end if;
      end if;

      if Buf /= 0 then
         if Mapped
           and then Syscalls.Mem_Unmap
             (Address_Space => Syscalls.Address_Space_Cap,
              VA            => Buf_Win_VA,
              Length        => Buf_Bytes) /= 0
         then
            Akernel_User.Console.Put_Line
              ("procfs buffer unmap failed");
         end if;
         --  Buffer caps transferred per op are deleted per op.
         if Syscalls.Cap_Delete (Buf) /= 0 then
            Akernel_User.Console.Put_Line
              ("procfs buffer cap delete failed");
         end if;
      end if;

      Reply2 (Status, Count);
   end Handle_Read;

   ------------------------------------------------------------------
   --  Op_ReadDir (stateless, by-index)
   ------------------------------------------------------------------

   procedure Handle_Read_Dir is
      Idx    : constant U64 := Syscalls.Message.Words (4);
      Kind   : Natural;
      P_Idx  : Natural;
      Name   : String (1 .. 24) := (others => Character'Val (0));
      Name_Len : Natural := 0;
      Is_Dir : Boolean := False;
      Size   : U64 := 0;
      Seen   : U64 := 0;
   begin
      Resolve (Path_Of (0), Kind, P_Idx);

      if Kind = 1 then
         --  Root: index 0 is the tree file, then one directory
         --  per live process in slot order, named by decimal pid.
         if Idx = 0 then
            Name (1 .. 4) := "tree";
            Name_Len := 4;
            Render_Tree;
            Size := U64 (Render_Len);
         else
            for S in Snaps'Range loop
               if Snaps (S).Live then
                  if Seen = Idx - 1 then
                     declare
                        Digs   : String (1 .. 10);
                        D_Len  : Natural := 0;
                        V      : U64 := Snaps (S).Pid;
                     begin
                        if V = 0 then
                           D_Len := 1;
                           Digs (1) := '0';
                        end if;
                        while V /= 0 loop
                           D_Len := D_Len + 1;
                           Digs (D_Len) := Character'Val
                             (Character'Pos ('0') + Natural (V mod 10));
                           V := V / 10;
                        end loop;
                        for I in 1 .. D_Len loop
                           Name (I) := Digs (D_Len - I + 1);
                        end loop;
                        Name_Len := D_Len;
                     end;
                     Is_Dir := True;
                  end if;
                  Seen := Seen + 1;
               end if;
            end loop;
         end if;
      elsif Kind = 3 then
         if Idx = 0 then
            Name (1 .. 6) := "status";
            Name_Len := 6;
            Render_Status (P_Idx);
            Size := U64 (Render_Len);
         end if;
      end if;

      if Name_Len = 0 then
         Reply2 (Status_Not_Found, 0);
         return;
      end if;

      Syscalls.Message.Words (0) := Status_Ok;
      Syscalls.Message.Words (1) := Size;
      Syscalls.Message.Words (2) := (if Is_Dir then 1 else 0);
      for W in 3 .. 5 loop
         Syscalls.Message.Words (W) := 0;
      end loop;
      for P in 1 .. Name_Len loop
         Syscalls.Message.Words (3 + (P - 1) / 8) :=
           Syscalls.Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Name (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply /= Syscalls.IPC_Ok then
         Akernel_User.Console.Put_Line
           ("procfs readdir reply failed");
         Syscalls.Process_Exit;
      end if;
   end Handle_Read_Dir;

begin
   Akernel_User.Console.Set_Endpoint (Console_Cap);

   Info_Cap := Syscalls.Mem_Alloc (1);
   Render_Cap := Syscalls.Mem_Alloc (1);
   if Info_Cap = Syscalls.Syscall_Failed
     or else Render_Cap = Syscalls.Syscall_Failed
     or else Syscalls.Mem_Map
       (Address_Space => Syscalls.Address_Space_Cap,
        Cap           => Info_Cap,
        VA            => Info_VA,
        Offset        => 0,
        Length        => Syscalls.Page_Size,
        Flags         => 3) /= 0
     or else Syscalls.Mem_Map
       (Address_Space => Syscalls.Address_Space_Cap,
        Cap           => Render_Cap,
        VA            => Render_VA,
        Offset        => 0,
        Length        => Syscalls.Page_Size,
        Flags         => 3) /= 0
   then
      Akernel_User.Console.Put_Line ("procfs scratch alloc failed");
      Syscalls.Process_Exit;
   end if;

   Akernel_User.Console.Put_Line ("procfs online");

   loop
      if Syscalls.IPC_Recv (Svc_EP) /= Syscalls.IPC_Ok then
         Akernel_User.Console.Put_Line ("procfs recv failed");
         Syscalls.Process_Exit;
      end if;

      if Syscalls.Message.Label = Op_Stat
        or else Syscalls.Message.Label = Op_Open
      then
         Handle_Stat_Or_Open;
      elsif Syscalls.Message.Label = Op_Read then
         Handle_Read;
      elsif Syscalls.Message.Label = Op_ReadDir then
         Handle_Read_Dir;
      elsif Syscalls.Message.Label = Op_Sync then
         --  Nothing dirty: every read renders from a fresh
         --  snapshot. The hook exists for protocol symmetry.
         Reply2 (Status_Ok, 0);
      elsif Syscalls.Message.Label = Op_Write
        or else Syscalls.Message.Label = Op_Delete
        or else Syscalls.Message.Label = Op_Truncate
        or else Syscalls.Message.Label = Op_Mkdir
        or else Syscalls.Message.Label = Op_Rmdir
      then
         --  Read-only volume (introspection has no knobs yet).
         Reply2 (Status_Bad_Args, 0);
      else
         Reply2 (Status_Bad_Args, 0);
      end if;
   end loop;
end Procfs;
