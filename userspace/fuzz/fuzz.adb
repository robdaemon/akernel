with Interfaces;
with System;
with System.Storage_Elements;
with Ada.Unchecked_Deallocation;
with Akernel_User.Syscalls;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.IPC;
with Akernel_User.Streams;

--  Syscall argument fuzzer.  Exercises every syscall with edge-case and
--  pseudo-random argument values and verifies the kernel stays alive and
--  keeps returning clean status codes.  Runs as a manifest-spawned user
--  process granted the ipc_test endpoint (handle 1, badge 0xEC40), the
--  console endpoint Send cap (handle 2) and the Tests/Echo
--  Boot_File_Object image cap (handle 3).  Test output goes through
--  the console server (Akernel_User.Console over the endpoint stream);
--  the random phase still hits the raw debug_putchar syscall as a
--  fuzz target.
--
--  NOTE: spawn consumes Boot_File_Object image caps (spawn ABI v2).
--  The fuzzer deliberately never forms a valid image cap in the
--  random phase (a0 forced to 0) so it cannot recursively spawn.

procedure Fuzz is
   subtype U64 is Interfaces.Unsigned_64;
   use type U64;

   --  A0..A5 default to 0: named association at call sites states
   --  only the arguments a syscall actually takes.
   function Raw_Ecall
     (Number : U64;
      A0     : U64 := 0;
      A1     : U64 := 0;
      A2     : U64 := 0;
      A3     : U64 := 0;
      A4     : U64 := 0;
      A5     : U64 := 0) return U64
     with Import, Convention => C, External_Name => "fuzz_ecall";

   Last_A1 : U64
     with Import, Convention => C, External_Name => "fuzz_last_a1",
          Volatile;

   --  Static, not stack: the fuzz main frame is already near the
   --  16KiB user stack — a 1KiB local array here silently
   --  corrupted unrelated earlier checks (stack spills into the
   --  heap mappings below).
   Pids : array
     (0 .. Akernel_User.Syscalls.Process_Table_Slots - 1)
     of U64 := (others => 0);

   Sys_Yield          : constant U64 := 0;
   Sys_Debug_Putchar  : constant U64 := 1;
   Sys_Map_MMIO       : constant U64 := 2;
   Sys_IRQ_Wait       : constant U64 := 3;
   Sys_IRQ_Ack        : constant U64 := 4;
   Sys_Boot_File_Size : constant U64 := 6;
   Sys_Boot_Read_Byte : constant U64 := 7;
   Sys_Spawn          : constant U64 := 8;
   Sys_Exit           : constant U64 := 9;
   Sys_Reap           : constant U64 := 10;
   Sys_EP_Create      : constant U64 := 11;
   Sys_IPC_Call       : constant U64 := 12;
   Sys_IPC_Recv       : constant U64 := 13;
   Sys_IPC_Reply      : constant U64 := 14;
   Sys_Mem_Alloc      : constant U64 := 15;
   Sys_Mem_Map        : constant U64 := 16;
   Sys_Mem_Unmap      : constant U64 := 17;
   Sys_Cap_Delete     : constant U64 := 26;
   Sys_CPU_Count      : constant U64 := 27;
   Sys_Process_Info   : constant U64 := 30;

   Highest_Known      : constant U64 := 30;

   Failed : constant U64 := U64'Last;

   --  xorshift64 PRNG, deterministic seed.
   State : U64 := 16#9E37_79B9_7F4A_7C15#;

   function Next_Random return U64 is
      X : U64 := State;
   begin
      X := X xor Interfaces.Shift_Left (X, 13);
      X := X xor Interfaces.Shift_Right (X, 7);
      X := X xor Interfaces.Shift_Left (X, 17);
      State := X;
      return X;
   end Next_Random;

   procedure Put (S : String) is
   begin
      Akernel_User.Console.Put (S);
   end Put;

   procedure Put_Line (S : String) is
   begin
      Akernel_User.Console.Put_Line (S);
   end Put_Line;

   Hex_Digits : constant String := "0123456789abcdef";

   procedure Put_Hex (Value : U64) is
      S : String (1 .. 18);
   begin
      S (1) := '0';
      S (2) := 'x';
      for Shift in reverse 0 .. 15 loop
         declare
            Nibble : constant U64 :=
              Interfaces.Shift_Right (Value, Shift * 4) and 16#F#;
         begin
            S (3 + (15 - Shift)) := Hex_Digits (Natural (Nibble) + 1);
         end;
      end loop;
      Put (S);
   end Put_Hex;

   --  Edge-case argument pool.
   Edge_Pool : constant array (1 .. 14) of U64 :=
     (0,
      1,
      2,
      16#FF#,               --  cap handle bound / byte bound
      16#100#,              --  first invalid cap handle
      16#FFF#,              --  page - 1
      16#1000#,             --  page
      16#7FFF_FFFF#,        --  low canonical bound
      16#8000_0000#,
      16#FFFF_FFFF#,
      16#1_0000_0000#,
      16#7FFF_FFFF_FFFF_FFFF#,
      16#8000_0000_0000_0000#,
      16#FFFF_FFFF_FFFF_FFFF#);

   function Arg_Value return U64 is
      R : constant U64 := Next_Random;
   begin
      if (R and 3) = 0 then
         return Edge_Pool (Natural (Interfaces.Shift_Right (R, 8)
                                    and 16#F#) mod Edge_Pool'Length + 1);
      else
         return Next_Random;
      end if;
   end Arg_Value;

   Total_Calls   : U64 := 0;
   Unknown_Count : U64 := 0;
   Failures      : U64 := 0;

   procedure Check (Condition : Boolean; Label_Text : String) is
   begin
      if Condition then
         Put ("PASS ");
      else
         Put ("FAIL ");
         Failures := Failures + 1;
      end if;
      Put_Line (Label_Text);
   end Check;

   --  Volumes appear asynchronously: init pushes mounts while the
   --  suite is already running, and wakeup-boosted clients can
   --  outrace the push.  Poll the volume's stat with yields until
   --  it resolves (bounded; failure means the mount never came).
   function Await_Volume (Name : String) return Boolean is
      Size   : U64;
      Status : U64;
   begin
      for Try in 1 .. 100_000 loop
         Status := Akernel_User.Files.Stat (Name, Size);
         if Status = Akernel_User.Files.Status_Ok then
            return True;
         end if;
         Akernel_User.Syscalls.Yield;
      end loop;
      return False;
   end Await_Volume;

   Status   : U64;
   Number   : U64;
   A0, A1, A2, A3, A4, A5 : U64;

   --  End-to-end IPC state.
   EP, EP2       : U64;
   Echo_Process  : U64;
   Reaped        : Boolean;
   Ignore        : U64;

   --  Granted caps: ipc_test endpoint at handle 1, console Send cap
   --  at handle 2, Tests/Echo image cap at handle 3.
   Console_EP : constant U64 := 2;
   Echo_Image : constant U64 := 3;

   package Console_RPC is new Akernel_User.IPC
     (Akernel_User.Streams.Stream_Request,
      Akernel_User.Streams.Stream_Response);

   Console_Request  : Akernel_User.Streams.Stream_Request;
   Console_Response : Akernel_User.Streams.Stream_Response;
   Reply_Label      : U64;
   Mem_Cap          : U64;

   Iterations : constant U64 := 4096;
begin
   Akernel_User.Console.Set_Endpoint (Console_EP);
   Put_Line ("fuzz online");

   --  Directed cases first.

   --  Unknown syscall numbers must return Failed.
   Status := Raw_Ecall (Number => 200);
   Check (Status = Failed, "unknown syscall 200 rejected");
   Status := Raw_Ecall
     (Number => 255, A0 => 1, A1 => 2, A2 => 3,
      A3 => 4, A4 => 5, A5 => 6);
   Check (Status = Failed, "unknown syscall 255 rejected");
   Status := Raw_Ecall (Number => U64'Last);
   Check (Status = Failed, "unknown syscall max rejected");

   --  cpu_count introspection: at least the boot hart is online.
   Status := Raw_Ecall (Number => Sys_CPU_Count);
   Check (Status >= 1 and then Status <= 64, "cpu_count reports online harts");

   --  ep_create returns fresh distinct endpoint cap handles.
   Status := Raw_Ecall (Number => Sys_EP_Create);
   Check (Status /= Failed and then Status < 256, "ep_create returns handle");
   A0 := Raw_Ecall (Number => Sys_EP_Create);
   Check (A0 /= Failed and then A0 /= Status, "ep_create distinct handles");

   --  IPC syscall argument validation (non-blocking cases only).
   Status := Raw_Ecall (Number => Sys_IPC_Call, A0 => 16#100#);
   Check (Status = 1, "ipc_call invalid cap rejected");
   Status := Raw_Ecall (Number => Sys_IPC_Recv, A0 => U64'Last);
   Check (Status = 1, "ipc_recv invalid cap rejected");
   Status := Raw_Ecall (Number => Sys_IPC_Reply, A0 => 254);
   Check (Status = 1, "ipc_reply without reply cap rejected");
   Status := Raw_Ecall (Number => Sys_IPC_Reply, A0 => 200);
   Check (Status = 1, "ipc_reply wrong handle rejected");

   --  cap_delete: closes the caller's own cap-table slot.
   Status := Raw_Ecall (Number => Sys_Cap_Delete, A0 => 16#100#);
   Check (Status = Failed, "cap_delete invalid handle rejected");
   A1 := Raw_Ecall (Number => Sys_EP_Create);
   Status := Raw_Ecall (Number => Sys_Cap_Delete, A0 => A1);
   Check (Status = 0, "cap_delete closes endpoint cap");
   Status := Raw_Ecall (Number => Sys_IPC_Recv, A0 => A1);
   Check (Status = 1, "deleted cap rejected");
   Status := Raw_Ecall (Number => Sys_Cap_Delete, A0 => A1);
   Check (Status = Failed, "cap_delete twice rejected");

   --  Console stream RPC: a write op must round-trip through the
   --  console server and report the byte count consumed.
   Console_Request := (Count => 1, Data => (others => 0));
   Console_Request.Data (1) := Character'Pos ('.');
   Status := Console_RPC.Call
     (Console_EP, Akernel_User.Streams.Op_Write, Console_Request,
      Console_RPC.No_Caps, Reply_Label, Console_Response);
   Check (Status = 0 and then Console_Response.Count = 1,
          "console write rpc round-trips");
   --  A read op on the output-only console yields EOF (count 0).
   Console_Request := (Count => 4, Data => (others => 0));
   Status := Console_RPC.Call
     (Console_EP, Akernel_User.Streams.Op_Read, Console_Request,
      Console_RPC.No_Caps, Reply_Label, Console_Response);
   Check (Status = 0 and then Console_Response.Count = 0,
          "console read reports eof");

   --  Memory objects: alloc/map/touch/unmap of borrowed frames.
   --  The object stays allocated until this process exits, which
   --  also exercises the refcounted frame teardown path.
   declare
      Mem_VA : constant U64 := 16#5000_0000#;
      AS     : constant U64 := Akernel_User.Syscalls.Address_Space_Cap;

      type Page_Words is array (0 .. 511) of U64;
      Mapped : Page_Words
        with Volatile, Address =>
          System'To_Address
            (System.Storage_Elements.Integer_Address (Mem_VA));
   begin
      Mem_Cap := Raw_Ecall (Number => Sys_Mem_Alloc, A0 => 1);
      Check (Mem_Cap /= U64'Last, "mem_alloc returns handle");
      Check (Raw_Ecall (Number => Sys_Mem_Alloc, A0 => 0) = U64'Last,
             "mem_alloc zero pages rejected");
      Check (Raw_Ecall (Number => Sys_Mem_Alloc, A0 => 65) = U64'Last,
             "mem_alloc over max pages rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Map, A0 => AS, A1 => 200,
                A2 => Mem_VA, A3 => 0, A4 => 4096, A5 => 3) = 1,
             "mem_map invalid cap rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Map, A0 => AS, A1 => Mem_Cap,
                A2 => Mem_VA + 1, A3 => 0, A4 => 4096, A5 => 3) = 1,
             "mem_map unaligned va rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Map, A0 => AS, A1 => Mem_Cap,
                A2 => Mem_VA, A3 => 4096, A4 => 4096, A5 => 3) = 1,
             "mem_map beyond object rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Map, A0 => AS, A1 => Mem_Cap,
                A2 => Mem_VA, A3 => 0, A4 => 4096, A5 => 2) = 1,
             "mem_map write-only rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Map, A0 => AS, A1 => Mem_Cap,
                A2 => Mem_VA, A3 => 0, A4 => 4096, A5 => 3) = 0,
             "mem_map rw page maps");
      Mapped (0) := 16#DEAD_BEEF#;
      Check (Mapped (0) = 16#DEAD_BEEF# and then Mapped (511) = 0,
             "memory object page writable and zeroed");
      Check (Raw_Ecall
               (Number => Sys_Mem_Unmap, A0 => AS,
                A1 => Mem_VA, A2 => 4096) = 0,
             "mem_unmap drops mapping");
      Check (Raw_Ecall
               (Number => Sys_Mem_Unmap, A0 => AS,
                A1 => Mem_VA, A2 => 4096) = 1,
             "mem_unmap twice rejected");
      Check (Raw_Ecall
               (Number => Sys_Mem_Unmap, A0 => AS,
                A1 => Akernel_User.Syscalls.IPC_Buffer_VA,
                A2 => 4096) = 1,
             "mem_unmap refuses owned pages");

      --  mem_object_pa (syscall 25): DMA drivers read frame PAs.
      --  Mem_Cap names a live 1-page object with Manage here.
      declare
         PA : constant U64 :=
           Akernel_User.Syscalls.Mem_Object_PA (Mem_Cap, 0);
      begin
         Check (PA /= 0 and then PA mod 4096 = 0,
                "mem_object_pa returns aligned frame PA");
         Check (Akernel_User.Syscalls.Mem_Object_PA (Mem_Cap, 1) = 0,
                "mem_object_pa out of range rejected");
         Check (Akernel_User.Syscalls.Mem_Object_PA (16#FEED_BEEF#, 0) = 0,
                "mem_object_pa invalid cap rejected");
      end;

      --  io_map / irq_create (syscalls 23/24): fuzz holds no
      --  device_resource cap, so creation is refused outright.
      Check (Akernel_User.Syscalls.IO_Map
             (16#FEED_BEEF#, 16#1000_0000#, 4096) =
               Akernel_User.Syscalls.Syscall_Failed,
             "io_map without resource cap rejected");
      Check (Akernel_User.Syscalls.IRQ_Create (16#FEED_BEEF#, 10) =
               Akernel_User.Syscalls.Syscall_Failed,
             "irq_create without resource cap rejected");
   end;

   --  RTS heap (System.Memory over memory objects): allocate /
   --  write / free / churn across chunk growth.
   declare
      type Byte_Array is array (Natural range <>) of U64;
      type Array_Access is access Byte_Array;
      procedure Free is new Ada.Unchecked_Deallocation
        (Byte_Array, Array_Access);

      Ptrs  : array (1 .. 16) of Array_Access := (others => null);
      Big   : Array_Access;
      Ok    : Boolean := True;
   begin
      Ptrs (1) := new Byte_Array (0 .. 7);
      Ptrs (1).all := (others => 16#ABCD#);
      Check (Ptrs (1) (0) = 16#ABCD# and then Ptrs (1) (7) = 16#ABCD#,
             "heap new/write/read works");

      --  Churn: alloc 15 more, free every other, alloc again.
      for I in 2 .. 16 loop
         Ptrs (I) := new Byte_Array (0 .. 63);
         Ptrs (I) (0) := U64 (I);
      end loop;
      for I in 1 .. 8 loop
         Free (Ptrs (I * 2 - 1));
      end loop;
      for I in 1 .. 8 loop
         Ptrs (I * 2 - 1) := new Byte_Array (0 .. 31);
         Ptrs (I * 2 - 1) (0) := U64 (100 + I);
      end loop;
      for I in 2 .. 16 loop
         if I mod 2 = 0 then
            Ok := Ok and then Ptrs (I) (0) = U64 (I);
         end if;
      end loop;
      Check (Ok, "heap churn preserves even slots");
      for I in 1 .. 16 loop
         Free (Ptrs (I));
      end loop;

      --  Chunk growth: 400 KiB spans two 256 KiB memory objects.
      Big := new Byte_Array (0 .. 51_199);
      Big (0) := 1;
      Big (51_199) := 2;
      Check (Big (0) = 1 and then Big (51_199) = 2,
             "heap grows across memory objects");
      Free (Big);

      --  Near-limit fill: 1.25 MiB forces five of the eight
      --  256 KiB chunks to be mapped.
      Big := new Byte_Array (0 .. 163_839);
      Big (0) := 3;
      Big (163_839) := 4;
      Check (Big (0) = 3 and then Big (163_839) = 4,
             "heap fills near chunk limit");
      Free (Big);
   end;

   --  File protocol: fileserver serves initrd files by name over
   --  the fs endpoint; reads move through a client-owned memory
   --  object the server maps into its own address space.
   declare
      FS_EP         : constant U64 := 4;  --  manifest grant order
      Manifest_Cap  : constant U64 := 5;
      use type Interfaces.Unsigned_8;
      Buf           : array (0 .. 63) of Interfaces.Unsigned_8;
      Big_Buf       : array (0 .. 511) of Interfaces.Unsigned_8;
      Size          : U64 := 0;
      Count         : U64 := 0;
      Status        : U64;
      Tries         : Natural := 0;
      Match         : Boolean;
   begin
      Akernel_User.Files.Bind (FS_EP);

      --  The server needs its name table from init first; retry
      --  while it reports not-ready.
      loop
         Status := Akernel_User.Files.Stat ("System/Manifest", Size);
         exit when Status /= Akernel_User.Files.Status_Not_Ready
           or else Tries >= 10_000;
         Tries := Tries + 1;
         Akernel_User.Syscalls.Yield;
      end loop;

      Check (Status = Akernel_User.Files.Status_Ok
             and then Size =
               Akernel_User.Syscalls.Boot_File_Size (Manifest_Cap),
             "fs stat matches boot file size");

      Status := Akernel_User.Files.Stat ("no/such/file", Size);
      Check (Status = Akernel_User.Files.Status_Not_Found,
             "fs stat unknown name rejected");

      Status := Akernel_User.Files.Open ("System/Manifest", Size);
      Check (Status = Akernel_User.Files.Status_Ok,
             "fs open manifest ok");

      Status := Akernel_User.Files.Read
        ("System/Manifest", 0, Buf'Address, 64, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 64;
      for I in Buf'Range loop
         Match := Match
           and then U64 (Buf (I)) =
             Akernel_User.Syscalls.Boot_Read_Byte
               (Manifest_Cap, U64 (I));
      end loop;
      Check (Match, "fs read bytes match boot byte API");

      Status := Akernel_User.Files.Read
        ("System/Manifest", Size - 16, Buf'Address, 64, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 16,
             "fs read clamps at EOF");

      Status := Akernel_User.Files.Read
        ("System/Manifest", Size, Buf'Address, 64, Count);
      Check (Status = Akernel_User.Files.Status_Out_Of_Range,
             "fs read past EOF rejected");

      --  Volumes: device name and label both resolve; volume
      --  prefixes are case-insensitive, paths follow the volume's
      --  case flag (RD0 mounts ci).
      Status := Akernel_User.Files.Stat ("Initrd:System/Manifest", Size);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Size =
               Akernel_User.Syscalls.Boot_File_Size (Manifest_Cap),
             "fs stat via volume label");

      Status := Akernel_User.Files.Stat ("rd0:system/manifest", Size);
      Check (Status = Akernel_User.Files.Status_Ok,
             "fs names case-insensitive on RD0");

      Status := Akernel_User.Files.Stat ("DH0:System/Manifest", Size);
      Check (Status = Akernel_User.Files.Status_Not_Found,
             "fs unknown volume rejected");

      --  Block volume (WD0, virtio-blk behind Op_Add_Block): the
      --  raw device resolves as "disk" and reads come through the
      --  file server -> block driver RPC chain. The image is a
      --  64 MiB GPT-partitioned disk (partition 1 = FAT32).
      --  The mount is pushed asynchronously by init; wait for it.
      Check (Await_Volume ("WD0:disk"), "blk volume appears");
      Status := Akernel_User.Files.Stat ("WD0:disk", Size);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Size = 131072 * 512,
             "blk volume stat ok");

      Status := Akernel_User.Files.Stat ("Disk:disk", Size);
      Check (Status = Akernel_User.Files.Status_Ok,
             "blk volume label resolves");

      Status := Akernel_User.Files.Open ("WD0:disk", Size);
      Check (Status = Akernel_User.Files.Status_Ok,
             "blk volume open ok");

      --  GPT header at LBA 1: "EFI PART" signature.
      Status := Akernel_User.Files.Read
        ("WD0:disk", 512, Buf'Address, 8, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 8;
      declare
         Sig : constant String := "EFI PART";
      begin
         for I in 0 .. 7 loop
            Match := Match
              and then Buf (I) =
                Interfaces.Unsigned_8 (Character'Pos (Sig (I + 1)));
         end loop;
      end;
      Check (Match, "blk volume read signature ok");

      --  Unaligned offset exercises the file server's partial-
      --  sector copy path.
      Status := Akernel_User.Files.Read
        ("WD0:disk", 513, Buf'Address, 7, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 7;
      declare
         Sig : constant String := "FI PART";
      begin
         for I in 0 .. 6 loop
            Match := Match
              and then Buf (I) =
                Interfaces.Unsigned_8 (Character'Pos (Sig (I + 1)));
         end loop;
      end;
      Check (Match, "blk volume unaligned read ok");

      --  Partition query op (part0 token = handle 6, badge
      --  16#1000#): slot 0 is the FAT32 partition at LBA 2048,
      --  122880 sectors; the image has exactly one partition.
      declare
         Part_EP : constant U64 := 6;  --  manifest grant order
      begin
         Check (Await_Volume ("PD0:disk"), "part volume appears");
         Akernel_User.Syscalls.Message.Label := 3;  --  part_query
         Akernel_User.Syscalls.Message.Words := (others => 0);
         Akernel_User.Syscalls.Message.Caps := (others => 0);
         Status := Akernel_User.Syscalls.IPC_Call (Part_EP);
         Check (Status = Akernel_User.Syscalls.IPC_Ok
                and then Akernel_User.Syscalls.Message.Words (0) = 0
                and then Akernel_User.Syscalls.Message.Words (1) = 2048
                and then Akernel_User.Syscalls.Message.Words (2) = 122880
                and then Akernel_User.Syscalls.Message.Words (3) = 1,
                "part query slot 0 ok");

         Akernel_User.Syscalls.Message.Label := 3;
         Akernel_User.Syscalls.Message.Words := (others => 0);
         Akernel_User.Syscalls.Message.Words (0) := 1;
         Akernel_User.Syscalls.Message.Caps := (others => 0);
         Status := Akernel_User.Syscalls.IPC_Call (Part_EP);
         Check (Status = Akernel_User.Syscalls.IPC_Ok
                and then Akernel_User.Syscalls.Message.Words (0) = 1
                and then Akernel_User.Syscalls.Message.Words (3) = 1,
                "part query empty slot rejected");
      end;

      --  Per-partition raw volume (PD0, mounted by init from the
      --  query results): the partition resolves as "disk" through
      --  the file server -> partmgr -> blk chain.
      Status := Akernel_User.Files.Stat ("PD0:disk", Size);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Size = 122880 * 512,
             "part volume stat ok");

      Status := Akernel_User.Files.Stat ("Part0:disk", Size);
      Check (Status = Akernel_User.Files.Status_Ok,
             "part volume label resolves");

      --  FAT32 BPB at the partition start: 0xEB jump, OEM
      --  "mkfs.fat" (8 chars at offset 3).
      Status := Akernel_User.Files.Read
        ("PD0:disk", 0, Buf'Address, 12, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 12
        and then Buf (0) = 16#EB#;
      declare
         Sig : constant String := "mkfs.fat";
      begin
         for I in 0 .. 7 loop
            Match := Match
              and then Buf (3 + I) =
                Interfaces.Unsigned_8 (Character'Pos (Sig (I + 1)));
         end loop;
      end;
      Check (Match, "part volume read bpb ok");

      --  Sync fans out to the fs-driver volumes; write-through
      --  today, so a no-op passthrough that must report ok.
      Check (Akernel_User.Files.Sync = Akernel_User.Files.Status_Ok,
             "fs sync accepted");

      --  FAT32 volume (BD0, System/Fat32 behind the VFS): real
      --  files resolve and read through the file server -> fs
      --  driver -> block driver RPC chain.
      Check (Await_Volume ("BD0:README.TXT"), "fat32 volume appears");
      Status := Akernel_User.Files.Stat ("BD0:README.TXT", Size);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Size = 37,
             "fat stat readme size");

      Status := Akernel_User.Files.Stat ("Sys:README.TXT", Size);
      Check (Status = Akernel_User.Files.Status_Ok,
             "fat volume label resolves");

      Status := Akernel_User.Files.Read
        ("BD0:README.TXT", 0, Buf'Address, 64, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 37;
      declare
         Text : constant String := "Hello from the akernel FAT32 volume.";
      begin
         for I in 0 .. 35 loop
            Match := Match
              and then Buf (I) =
                Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
         Match := Match and then Buf (36) = 10;
      end;
      Check (Match, "fat readme content ok");

      --  BIG.BIN: byte i = (i*7+3) mod 256, 64 KiB — spans 128
      --  clusters on a 1-sector/cluster image, exercising FAT
      --  chain walks in the fs driver.
      Status := Akernel_User.Files.Stat ("BD0:BIG.BIN", Size);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Size = 65536,
             "fat stat big.bin size");

      Status := Akernel_User.Files.Read
        ("BD0:BIG.BIN", 0, Big_Buf'Address, 512, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 512;
      for J in 0 .. 511 loop
         Match := Match
           and then Big_Buf (J) =
             Interfaces.Unsigned_8 ((J * 7 + 3) mod 256);
      end loop;
      Check (Match, "fat big.bin head ok");

      Status := Akernel_User.Files.Read
        ("BD0:BIG.BIN", 65000, Big_Buf'Address, 512, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 512;
      for J in 0 .. 511 loop
         Match := Match
           and then Big_Buf (J) =
             Interfaces.Unsigned_8 (((65000 + J) * 7 + 3) mod 256);
      end loop;
      Check (Match, "fat big.bin tail ok");

      --  Cluster-crossing unaligned read (clusters are 1 sector).
      Status := Akernel_User.Files.Read
        ("BD0:BIG.BIN", 4091, Buf'Address, 8, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 8;
      for J in 0 .. 7 loop
         Match := Match
           and then Buf (J) =
             Interfaces.Unsigned_8 (((4091 + J) * 7 + 3) mod 256);
      end loop;
      Check (Match, "fat unaligned read ok");

      Status := Akernel_User.Files.Stat ("bd0:big.bin", Size);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Size = 65536,
             "fat names case-insensitive");

      Status := Akernel_User.Files.Stat ("BD0:NOSUCH.BIN", Size);
      Check (Status = Akernel_User.Files.Status_Not_Found,
             "fat unknown file rejected");

      --  Subdirectory traversal and LFN entries (host-created in
      --  the image: mmd SUBDIR, mcopy with a long name).
      Status := Akernel_User.Files.Stat ("BD0:SUBDIR/HELLO.TXT", Size);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Size = 14,
             "fat subdir stat ok");

      Status := Akernel_User.Files.Read
        ("BD0:subdir/hello.txt", 0, Buf'Address, 64, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 14;
      declare
         Text : constant String := "Subdir hello!";
      begin
         for I in 0 .. 12 loop
            Match := Match
              and then Buf (I) =
                Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
         Match := Match and then Buf (13) = 10;
      end;
      Check (Match, "fat subdir read ok");

      Status := Akernel_User.Files.Stat ("BD0:LongFileName.txt", Size);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Size = 23,
             "fat lfn stat ok");

      Status := Akernel_User.Files.Read
        ("bd0:longfilename.txt", 0, Buf'Address, 64, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 23;
      declare
         Text : constant String := "A long file name body.";
      begin
         for I in 0 .. 21 loop
            Match := Match
              and then Buf (I) =
                Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
         Match := Match and then Buf (22) = 10;
      end;
      Check (Match, "fat lfn read ok");

      --  Write path: create + overwrite (idempotent — same bytes
      --  and offsets every boot, so a reused image still passes).
      declare
         Text : constant String := "AKWRITE!+MORE!";
      begin
         for I in 0 .. 13 loop
            Buf (I) :=
              Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;

      Status := Akernel_User.Files.Write
        ("BD0:NEWFILE.TXT", 0, Buf'Address, 14, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 14,
             "fat write create ok");

      Status := Akernel_User.Files.Stat ("BD0:NEWFILE.TXT", Size);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Size = 14,
             "fat write stat ok");

      for I in 0 .. 13 loop
         Buf (I) := 0;
      end loop;
      Status := Akernel_User.Files.Read
        ("BD0:NEWFILE.TXT", 0, Buf'Address, 64, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 14;
      declare
         Text : constant String := "AKWRITE!+MORE!";
      begin
         for I in 0 .. 13 loop
            Match := Match
              and then Buf (I) =
                Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Check (Match, "fat write readback ok");

      --  Create inside a subdirectory.
      Status := Akernel_User.Files.Write
        ("BD0:SUBDIR/NEW.TXT", 0, Buf'Address, 0, Count);
      Check (Status = Akernel_User.Files.Status_Bad_Args,
             "fat write zero-length rejected");

      declare
         Text : constant String := "AKSUBDIR";
      begin
         for I in 0 .. 7 loop
            Buf (I) :=
              Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Status := Akernel_User.Files.Write
        ("BD0:SUBDIR/NEW.TXT", 0, Buf'Address, 8, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 8,
             "fat write subdir ok");

      --  Full-cluster write on create (512 bytes = one cluster on
      --  a 1-sector/cluster image): first-cluster allocation path.
      for J in 0 .. 511 loop
         Big_Buf (J) := Interfaces.Unsigned_8 ((J * 5 + 1) mod 256);
      end loop;
      Status := Akernel_User.Files.Write
        ("BD0:NEW2.TXT", 0, Big_Buf'Address, 512, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 512,
             "fat write big ok");

      --  Extending write at the current end (size grows 8 bytes
      --  per boot; checks stay relative so reruns pass).
      Status := Akernel_User.Files.Stat ("BD0:EXT.TXT", Size);
      declare
         Prior : U64 := 0;
      begin
         if Status = Akernel_User.Files.Status_Ok then
            Prior := Size;
         end if;
         declare
            Text : constant String := "AKEXTEND";
         begin
            for I in 0 .. 7 loop
               Buf (I) :=
                 Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
            end loop;
         end;
         Status := Akernel_User.Files.Write
           ("BD0:EXT.TXT", Prior, Buf'Address, 8, Count);
         Check (Status = Akernel_User.Files.Status_Ok
                and then Count = 8,
                "fat write extend ok");
         Status := Akernel_User.Files.Stat ("BD0:EXT.TXT", Size);
         Check (Status = Akernel_User.Files.Status_Ok
                and then Size = Prior + 8,
                "fat write extend stat ok");
      end;

      --  Sparse writes rejected; bad parent rejected.
      Status := Akernel_User.Files.Write
        ("BD0:NEWFILE.TXT", 100, Buf'Address, 4, Count);
      Check (Status = Akernel_User.Files.Status_Out_Of_Range,
             "fat write sparse rejected");

      Status := Akernel_User.Files.Write
        ("BD0:NODIR/F.TXT", 0, Buf'Address, 4, Count);
      Check (Status = Akernel_User.Files.Status_Not_Found,
             "fat write bad parent rejected");

      --  Raw disk write through the VFS bounce path: sector 1000
      --  sits in the gap between the GPT entry array and partition
      --  1 (read-modify-write of a partial range).
      declare
         Text : constant String := "AKRAWIO!";
      begin
         for I in 0 .. 7 loop
            Buf (I) :=
              Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Status := Akernel_User.Files.Write
        ("WD0:disk", 1000 * 512 + 100, Buf'Address, 8, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 8,
             "blk volume write ok");

      for I in 0 .. 7 loop
         Buf (I) := 0;
      end loop;
      Status := Akernel_User.Files.Read
        ("WD0:disk", 1000 * 512 + 100, Buf'Address, 8, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 8;
      declare
         Text : constant String := "AKRAWIO!";
      begin
         for I in 0 .. 7 loop
            Match := Match
              and then Buf (I) =
                Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Check (Match, "blk volume write readback ok");

      --  20c: delete / truncate / mkdir / rmdir / LFN creation.
      --  Idempotent across reused images: the prelude drops any
      --  leftover MKTEST state from a prior boot.
      Status := Akernel_User.Files.Delete ("BD0:MKTEST/INNER.TXT");
      Status := Akernel_User.Files.Rmdir ("BD0:MKTEST");

      Status := Akernel_User.Files.Mkdir ("BD0:MKTEST");
      Check (Status = Akernel_User.Files.Status_Ok,
             "fat mkdir ok");

      Status := Akernel_User.Files.Mkdir ("BD0:MKTEST");
      Check (Status = Akernel_User.Files.Status_Bad_Args,
             "fat mkdir exists rejected");

      Status := Akernel_User.Files.Stat ("BD0:MKTEST", Size);
      Check (Status = Akernel_User.Files.Status_Bad_Args,
             "fat dir stat rejected");

      Status := Akernel_User.Files.Mkdir ("BD0:NODIR/SUB");
      Check (Status = Akernel_User.Files.Status_Not_Found,
             "fat mkdir bad parent rejected");

      declare
         Text : constant String := "AKINNER!";
      begin
         for I in 0 .. 7 loop
            Buf (I) :=
              Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Status := Akernel_User.Files.Write
        ("BD0:MKTEST/INNER.TXT", 0, Buf'Address, 8, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 8,
             "fat mkdir file write ok");

      for I in 0 .. 7 loop
         Buf (I) := 0;
      end loop;
      Status := Akernel_User.Files.Read
        ("BD0:MKTEST/INNER.TXT", 0, Buf'Address, 64, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 8;
      declare
         Text : constant String := "AKINNER!";
      begin
         for I in 0 .. 7 loop
            Match := Match
              and then Buf (I) =
                Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Check (Match, "fat mkdir file read ok");

      Status := Akernel_User.Files.Rmdir ("BD0:MKTEST");
      Check (Status = Akernel_User.Files.Status_Bad_Args,
             "fat rmdir non-empty rejected");

      Status := Akernel_User.Files.Delete ("BD0:MKTEST/INNER.TXT");
      Check (Status = Akernel_User.Files.Status_Ok,
             "fat delete inner ok");

      Status := Akernel_User.Files.Rmdir ("BD0:MKTEST");
      Check (Status = Akernel_User.Files.Status_Ok,
             "fat rmdir ok");

      Status := Akernel_User.Files.Stat ("BD0:MKTEST", Size);
      Check (Status = Akernel_User.Files.Status_Not_Found,
             "fat rmdir gone");

      --  Delete: create, delete, gone; directories rejected.
      declare
         Text : constant String := "AKDELME!";
      begin
         for I in 0 .. 7 loop
            Buf (I) :=
              Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Status := Akernel_User.Files.Write
        ("BD0:DELME.TXT", 0, Buf'Address, 8, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 8,
             "fat delete setup write ok");

      Status := Akernel_User.Files.Delete ("BD0:DELME.TXT");
      Check (Status = Akernel_User.Files.Status_Ok,
             "fat file delete ok");

      Status := Akernel_User.Files.Stat ("BD0:DELME.TXT", Size);
      Check (Status = Akernel_User.Files.Status_Not_Found,
             "fat deleted stat rejected");

      Status := Akernel_User.Files.Delete ("BD0:DELME.TXT");
      Check (Status = Akernel_User.Files.Status_Not_Found,
             "fat delete twice rejected");

      Status := Akernel_User.Files.Delete ("BD0:SUBDIR");
      Check (Status = Akernel_User.Files.Status_Bad_Args,
             "fat delete dir rejected");

      --  Truncate: chain freed, size zeroed, file writable again.
      declare
         Text : constant String := "AKTRUNC!";
      begin
         for I in 0 .. 7 loop
            Buf (I) :=
              Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Status := Akernel_User.Files.Write
        ("BD0:TRUNC.TXT", 0, Buf'Address, 8, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 8,
             "fat truncate setup write ok");

      Status := Akernel_User.Files.Truncate ("BD0:TRUNC.TXT");
      Check (Status = Akernel_User.Files.Status_Ok,
             "fat truncate ok");

      Status := Akernel_User.Files.Stat ("BD0:TRUNC.TXT", Size);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Size = 0,
             "fat truncate zeroes size");

      Status := Akernel_User.Files.Write
        ("BD0:TRUNC.TXT", 0, Buf'Address, 8, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 8,
             "fat truncate rewrite ok");

      for I in 0 .. 7 loop
         Buf (I) := 0;
      end loop;
      Status := Akernel_User.Files.Read
        ("BD0:TRUNC.TXT", 0, Buf'Address, 64, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 8;
      declare
         Text : constant String := "AKTRUNC!";
      begin
         for I in 0 .. 7 loop
            Match := Match
              and then Buf (I) =
                Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Check (Match, "fat truncate readback ok");

      --  LFN creation: a component too long for 8.3 gets a
      --  numeric-tail alias plus LFN entries; reads resolve
      --  through the long name (case-insensitively).
      declare
         Text : constant String := "AKLFN-CREATE OK!";
      begin
         for I in 0 .. 15 loop
            Buf (I) :=
              Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Status := Akernel_User.Files.Write
        ("BD0:CreatedLongName.dat", 0, Buf'Address, 16, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 16,
             "fat lfn create write ok");

      Status := Akernel_User.Files.Stat
        ("bd0:createdlongname.dat", Size);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Size = 16,
             "fat lfn create stat ok");

      for I in 0 .. 15 loop
         Buf (I) := 0;
      end loop;
      Status := Akernel_User.Files.Read
        ("BD0:CreatedLongName.dat", 0, Buf'Address, 64, Count);
      Match := Status = Akernel_User.Files.Status_Ok
        and then Count = 16;
      declare
         Text : constant String := "AKLFN-CREATE OK!";
      begin
         for I in 0 .. 15 loop
            Match := Match
              and then Buf (I) =
                Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Check (Match, "fat lfn create read ok");

      --  Deleting an LFN file marks the whole LFN run 0xE5.
      declare
         Text : constant String := "AKDELLFN";
      begin
         for I in 0 .. 7 loop
            Buf (I) :=
              Interfaces.Unsigned_8 (Character'Pos (Text (I + 1)));
         end loop;
      end;
      Status := Akernel_User.Files.Write
        ("BD0:DeleteLongName.dat", 0, Buf'Address, 8, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 8,
             "fat lfn delete setup write ok");

      Status := Akernel_User.Files.Delete ("BD0:DeleteLongName.dat");
      Check (Status = Akernel_User.Files.Status_Ok,
             "fat lfn delete ok");

      Status := Akernel_User.Files.Stat ("BD0:DeleteLongName.dat", Size);
      Check (Status = Akernel_User.Files.Status_Not_Found,
             "fat lfn delete gone");

      --  38b: 64-file create/walk/count/delete proof on BD0 --
      --  FAT32 volumes are disk-bound; no VFS or driver table
      --  may silently fill (64 crosses every historic 32/63
      --  boundary; 300 was designed but each mutating FAT op
      --  costs ~0.4 s under write-through sync -- the cost
      --  scales with FAT size -- so 900 ops blow the suite
      --  budget; re-raise once the deferred write-back cache
      --  lands). Cleanup walks and deletes only leftovers, so
      --  a clean run pays nothing.
      declare
         WName     : String (1 .. 14) := "BD0:STRESS/F00";
         DName     : String (1 .. 24);
         DLen      : Natural;
         DDir      : Boolean;
         DSize     : U64;
         Create_Ok : Boolean := True;
         Delete_Ok : Boolean := True;
         Seen      : Natural;
         St2       : U64;
         C2        : U64;
      begin
         St2 := Akernel_User.Files.Mkdir ("BD0:STRESS");

         --  Leftover sweep (interrupted earlier run): delete any
         --  F* file the walk turns up, by its ACTUAL name
         --  (residue shapes from older test revisions differ).
         --  Always index 0: deleting renumbers the rest; the
         --  loop bound keeps a failed delete from spinning.
         declare
            Full : String (1 .. 40);
            FLen : Natural;
         begin
            for Index in 0 .. 400 loop
               St2 := Akernel_User.Files.Read_Dir
                 ("BD0:STRESS", 0, DName, DLen, DDir, DSize);
               exit when St2 /= Akernel_User.Files.Status_Ok;
               if DLen > 0 and then DName (1) = 'F'
                 and then not DDir
               then
                  Full := (others => Character'Val (0));
                  Full (1 .. 11) := "BD0:STRESS/";
                  Full (12 .. 11 + DLen) := DName (1 .. DLen);
                  FLen := 11 + DLen;
                  St2 := Akernel_User.Files.Delete (Full (1 .. FLen));
               end if;
            end loop;
         end;

         for N in 0 .. 63 loop
            WName (13) := Character'Val (48 + N / 10);
            WName (14) := Character'Val (48 + N mod 10);
            St2 := Akernel_User.Files.Write
              (WName, 0, Buf'Address, 4, C2);
            if St2 /= Akernel_User.Files.Status_Ok or else C2 /= 4 then
               Create_Ok := False;
            end if;
         end loop;
         Check (Create_Ok, "fat stress 64 creates ok");

         Seen := 0;
         for Index in 0 .. 100 loop
            St2 := Akernel_User.Files.Read_Dir
              ("BD0:STRESS", U64 (Index), DName, DLen, DDir, DSize);
            exit when St2 /= Akernel_User.Files.Status_Ok;
            Seen := Seen + 1;
         end loop;
         Check (Seen = 64, "fat stress walk counts 64");

         for N in 0 .. 63 loop
            WName (13) := Character'Val (48 + N / 10);
            WName (14) := Character'Val (48 + N mod 10);
            if Akernel_User.Files.Delete (WName) /= Akernel_User.Files.Status_Ok
            then
               Delete_Ok := False;
            end if;
         end loop;
         Check (Delete_Ok, "fat stress 64 deletes ok");

         Seen := 0;
         for Index in 0 .. 10 loop
            St2 := Akernel_User.Files.Read_Dir
              ("BD0:STRESS", U64 (Index), DName, DLen, DDir, DSize);
            exit when St2 /= Akernel_User.Files.Status_Ok;
            Seen := Seen + 1;
         end loop;
         Check (Seen = 0, "fat stress dir empty after deletes");
      end;

      --  38b: 64 generated tiny boot files (Makefile recipe)
      --  push every table past the old limits at once: kernel
      --  boot_files 24 -> 81 in use, init/fileserver cap tables,
      --  the 512-slot name table.
      declare
         GName  : String (1 .. 13) := "Tests/Gen/f00";
         GSize  : U64;
         GCount : U64;
         GStat  : U64;
         All_Ok : Boolean := True;
         RBuf   : array (0 .. 11) of Interfaces.Unsigned_8;
         RMatch : Boolean := True;
      begin
         for N in 0 .. 63 loop
            GName (12) := Character'Val (48 + N / 10);
            GName (13) := Character'Val (48 + N mod 10);
            GStat := Akernel_User.Files.Stat (GName, GSize);
            if GStat /= Akernel_User.Files.Status_Ok
              or else GSize /= 12
            then
               All_Ok := False;
            end if;
         end loop;
         Check (All_Ok, "gen 64 boot files stat ok");

         GStat := Akernel_User.Files.Open ("Tests/Gen/f42", GSize);
         Check (GStat = Akernel_User.Files.Status_Ok
                and then GSize = 12, "gen file f42 opens");
         GStat := Akernel_User.Files.Read
           ("Tests/Gen/f42", 0, RBuf'Address, 12, GCount);
         declare
            Expect : constant String :=
              "GENFILE f42" & Character'Val (10);
         begin
            for B in 0 .. 11 loop
               if RBuf (B) /= Interfaces.Unsigned_8
                 (Character'Pos (Expect (B + 1)))
               then
                  RMatch := False;
               end if;
            end loop;
         end;
         Check (GStat = Akernel_User.Files.Status_Ok
                and then GCount = 12 and then RMatch,
                "gen file f42 content reads");
      end;

      --  Spawn v2: stage an ELF into a memory object via the file
      --  server, spawn from the object cap (no boot-file cap
      --  involved), reap the exited child.
      declare
         use System.Storage_Elements;

         Stage_VA : constant U64 := 16#5400_0000#;
         Pages    : U64;
         Mem_Cap  : U64;
         Proc_Cap : U64 := 0;
         Off      : U64;
         Chunk    : U64;
         Staged   : Boolean := True;
      begin
         Status := Akernel_User.Files.Stat ("Tests/Memstage", Size);
         Check (Status = Akernel_User.Files.Status_Ok and then Size > 0,
                "memstage size via fs");

         Pages := (Size + 4095) / 4096;
         Mem_Cap := Akernel_User.Syscalls.Mem_Alloc (Pages);
         Check (Mem_Cap /= Akernel_User.Syscalls.Syscall_Failed,
                "memstage staging object allocated");

         Check (Akernel_User.Syscalls.Mem_Map
                  (Address_Space =>
                     Akernel_User.Syscalls.Address_Space_Cap,
                   Cap           => Mem_Cap,
                   VA            => Stage_VA,
                   Offset        => 0,
                   Length        => Pages * 4096,
                   Flags         => 3) = 0,
                "memstage staging object mapped");

         Status := Akernel_User.Files.Open ("Tests/Memstage", Size);
         Check (Status = Akernel_User.Files.Status_Ok,
                "memstage open ok");

         Off := 0;
         while Off < Size loop
            Chunk := U64'Min (Size - Off, 32768);
            Status := Akernel_User.Files.Read
              ("Tests/Memstage", Off,
               System'To_Address (Integer_Address (Stage_VA + Off)),
               Chunk, Count);
            Staged := Staged
              and then Status = Akernel_User.Files.Status_Ok
              and then Count = Chunk;
            Off := Off + Chunk;
         end loop;
         Check (Staged, "memstage ELF staged into memory object");

         Akernel_User.Syscalls.Set_Grant
           (Index       => 0,
            Source_Cap  => 2,  --  fuzz console cap -> child handle 1
            Rights_Mask => Akernel_User.Syscalls.Right_Send,
            Badge       => 0);
         Status := Akernel_User.Syscalls.Spawn
           (Image_Cap   => Mem_Cap,
            Grant_Count => 1,
            Process_Cap => Proc_Cap);
         Check (Status = 0 and then Proc_Cap /= 0,
                "spawn from memory object ok");

         --  Reap is non-blocking and the child runs in parallel on
         --  another hart, so poll (bounded) until it has exited.
         declare
            Reaped   : Boolean := False;
            Attempts : Natural := 0;
         begin
            while not Reaped and then Attempts < 100_000 loop
               Reaped   := Akernel_User.Syscalls.Reap_Process (Proc_Cap) = 0;
               Attempts := Attempts + 1;
               if not Reaped then
                  Akernel_User.Syscalls.Yield;
               end if;
            end loop;
            Check (Reaped, "memstage reaped after exit");
         end;
      end;
   end;

   --  Boot byte API probes: valid image cap, huge offset, invalid
   --  handle, wrong-kind cap (handle 1 is the granted endpoint).
   Status := Raw_Ecall (Number => Sys_Boot_File_Size, A0 => Echo_Image);
   Check (Status /= Failed, "image cap size query works");
   Status := Raw_Ecall
     (Number => Sys_Boot_Read_Byte, A0 => Echo_Image, A1 => U64'Last);
   Check (Status = 256 or else Status = Failed, "huge read offset safe");
   Status := Raw_Ecall (Number => Sys_Boot_File_Size, A0 => U64'Last);
   Check (Status = Failed, "invalid boot cap rejected");
   Status := Raw_Ecall (Number => Sys_Boot_File_Size, A0 => 1);
   Check (Status = Failed, "boot byte api wrong-kind cap rejected");

   --  Invalid cap handles on cap-taking syscalls.
   Status := Raw_Ecall (Number => Sys_IRQ_Wait, A0 => 16#100#);
   Check (Status /= 0, "irq_wait invalid cap rejected");
   Status := Raw_Ecall (Number => Sys_IRQ_Ack, A0 => U64'Last);
   Check (Status /= 0, "irq_ack invalid cap rejected");
   Status := Raw_Ecall (Number => Sys_Reap, A0 => 16#FEED_BEEF#);
   Check (Status /= 0, "reap invalid cap rejected");
   Status := Raw_Ecall
     (Number => Sys_Map_MMIO, A0 => 255, A1 => U64'Last,
      A4 => 16#1000#, A5 => 3);
   Check (Status /= 0, "map_mmio invalid mmio cap rejected");
   Status := Raw_Ecall
     (Number => Sys_Map_MMIO, A0 => 16#100#, A1 => 1,
      A4 => 16#1000#, A5 => 3);
   Check (Status /= 0, "map_mmio invalid as cap rejected");

   --  Spawn with invalid image caps (spawn ABI v2: a0 = image cap).
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => 0);
   Check (Status /= 0, "spawn null image cap rejected");
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => U64'Last);
   Check (Status /= 0, "spawn huge image cap rejected");
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => 1);
   Check (Status /= 0, "spawn wrong-kind image cap rejected");

   ----------------------------------------------------------------
   --  End-to-end IPC: spawn the echo server with a granted
   --  endpoint, ping-pong three rounds (badge, round-trip, one-shot
   --  reply cap, cap transfer), then reap the exited child.
   ----------------------------------------------------------------

   --  Endpoint granted by init at handle 1 with badge 0xEC40
   --  (session-manager badge pattern); messages sent through it
   --  arrive at echo stamped with that badge.
   EP := 1;

   --  Grant-list validation: unopened source handle.
   Akernel_User.Syscalls.Set_Grant (0, 250, 0, 0);
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => Echo_Image, A1 => 1);
   Check (Status = 4, "spawn grant of unopened cap rejected");

   --  Rights escalation: endpoints carry no Read right.
   Akernel_User.Syscalls.Set_Grant
     (0, EP, Akernel_User.Syscalls.Right_Read, 0);
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => Echo_Image, A1 => 1);
   Check (Status = 4, "spawn grant rights escalation rejected");

   --  Rights mask bits outside the valid set.
   Akernel_User.Syscalls.Set_Grant (0, EP, 16#400#, 0);
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => Echo_Image, A1 => 1);
   Check (Status = 4, "spawn grant unknown rights bits rejected");

   --  Grant count above the ABI limit.
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => Echo_Image, A1 => 33);
   Check (Status = 4, "spawn grant count over limit rejected");

   --  Valid grant: endpoint with Send+Receive (badged cap stays
   --  with the fuzzer; echo's own badge is irrelevant) plus the
   --  console Send cap so echo can print.
   Akernel_User.Syscalls.Set_Grant
     (0, EP,
      Akernel_User.Syscalls.Right_Send + Akernel_User.Syscalls.Right_Receive,
      0);
   Akernel_User.Syscalls.Set_Grant
     (1, Console_EP, Akernel_User.Syscalls.Right_Send, 0);
   Status := Raw_Ecall (Number => Sys_Spawn, A0 => Echo_Image, A1 => 2);
   --  fuzz_last_a1 is rewritten by every ecall: capture the process
   --  cap before Check (or anything else) makes another syscall.
   Echo_Process := Last_A1;
   Check (Status = 0 and then Echo_Process /= 0,
          "echo spawned with granted endpoint");

   --  process_info (syscall 30): slot snapshots + spawner links.
   --  The device_resource cap is manifest-granted at handle 7
   --  (last token on the fuzz program line); echo (spawned above,
   --  still running) must appear in the table with its spawner id
   --  naming this process, and must be the ONLY live child (the
   --  memstage child was reaped before this point).
   declare
      Resource_Cap : constant U64 := 7;  --  manifest grant order
      Info_VA      : constant U64 := 16#5020_0000#;
      type Info_Page is array (0 .. 511) of U64;
      Page : Info_Page
        with Volatile, Address =>
          System'To_Address
            (System.Storage_Elements.Integer_Address (Info_VA));
      Info_Cap    : U64;
      Self_Pid    : U64;
      Self_Spawn  : U64;
      Live_Slots  : Natural := 0;
      Child_Count : Natural := 0;
      States_Ok   : Boolean := True;
      Unique_Ok   : Boolean := True;
      Found_Self  : Boolean := False;
   begin
      Info_Cap := Raw_Ecall (Number => Sys_Mem_Alloc, A0 => 1);
      Check (Info_Cap /= U64'Last, "process_info buffer allocated");
      Check (Raw_Ecall
               (Number => Sys_Mem_Map,
                A0 => Akernel_User.Syscalls.Address_Space_Cap,
                A1 => Info_Cap, A2 => Info_VA,
                A3 => 0, A4 => 4096, A5 => 3) = 0,
             "process_info buffer mapped");

      --  Authority, buffer, offset and range validation.
      Check (Raw_Ecall (Number => Sys_Process_Info, A0 => 16#FEED_BEEF#,
                        A1 => 0, A2 => Info_Cap) = U64'Last,
             "process_info bad authority rejected");
      Check (Raw_Ecall (Number => Sys_Process_Info, A0 => Console_EP,
                        A1 => 0, A2 => Info_Cap) = U64'Last,
             "process_info wrong-kind authority rejected");
      Check (Raw_Ecall (Number => Sys_Process_Info, A0 => Resource_Cap,
                        A1 => 0, A2 => Console_EP) = U64'Last,
             "process_info wrong-kind buffer rejected");
      Check (Raw_Ecall (Number => Sys_Process_Info, A0 => Resource_Cap,
                        A1 => 0, A2 => Info_Cap, A3 => 4) = U64'Last,
             "process_info unaligned offset rejected");
      Check (Raw_Ecall (Number => Sys_Process_Info, A0 => Resource_Cap,
                        A1 => 0, A2 => Info_Cap, A3 => 4064) = U64'Last,
             "process_info overflowing offset rejected");
      Check (Raw_Ecall (Number => Sys_Process_Info, A0 => Resource_Cap,
                        A1 => 32, A2 => Info_Cap) = 1,
             "process_info out-of-range slot ends enumeration");

      --  Self snapshot: alive, distinct nonzero spawner (init,
      --  kernel-started, itself outside the spawn table).
      Check (Raw_Ecall (Number => Sys_Process_Info, A0 => Resource_Cap,
                        A1 => U64'Last, A2 => Info_Cap) = 0,
             "process_info self snapshot ok");
      Self_Pid   := Page (0);
      Self_Spawn := Page (1);
      Check (Self_Pid /= 0 and then Page (2) = 1
             and then Self_Spawn /= 0 and then Self_Spawn /= Self_Pid,
             "process_info self alive with distinct spawner");

      --  Table walk: states in range, pids unique, self present,
      --  exactly one live child linked back to this process.
      for Slot in 0 .. Akernel_User.Syscalls.Process_Table_Slots - 1 loop
         if Raw_Ecall (Number => Sys_Process_Info, A0 => Resource_Cap,
                       A1 => U64 (Slot), A2 => Info_Cap) = 0
         then
            if Page (2) > 2 or else Page (3) > 6 then
               States_Ok := False;
            end if;
            for J in 0 .. Live_Slots - 1 loop
               if Pids (J) = Page (0) then
                  Unique_Ok := False;
               end if;
            end loop;
            Pids (Live_Slots) := Page (0);
            Live_Slots := Live_Slots + 1;
            if Page (0) = Self_Pid then
               Found_Self := True;
            end if;
            if Page (1) = Self_Pid then
               Child_Count := Child_Count + 1;
            end if;
         end if;
      end loop;
      Check (Live_Slots >= 5, "process_info enumerates the boot set");
      Check (States_Ok, "process_info states in enum range");
      Check (Unique_Ok, "process_info pids unique");
      Check (Found_Self, "process_info self appears in table walk");
      Check (Child_Count = 1, "process_info links child spawner");
   end;

   --  38a/38b cap stress: the paged cap table allocates a page
   --  per 128 handles. Minting 300 one-page memory objects must
   --  cross handles 128 and 256 (pages 1 and 2); closing them
   --  frees the pages again and the table keeps working.
   declare
      Stress_Caps : array (1 .. 300) of U64 := (others => U64'Last);
      Mint_Ok     : Boolean := True;
      Close_Ok    : Boolean := True;
      Max_H       : U64 := 0;
      Reuse       : U64;
   begin
      for I in Stress_Caps'Range loop
         Stress_Caps (I) := Akernel_User.Syscalls.Mem_Alloc (1);
         if Stress_Caps (I) = Akernel_User.Syscalls.Syscall_Failed then
            Mint_Ok := False;
         elsif Stress_Caps (I) > Max_H then
            Max_H := Stress_Caps (I);
         end if;
      end loop;
      Check (Mint_Ok, "cap stress minted 300");
      Check (Max_H >= 256, "cap stress crossed second page");

      for I in Stress_Caps'Range loop
         if Stress_Caps (I) /= Akernel_User.Syscalls.Syscall_Failed
           and then Akernel_User.Syscalls.Cap_Delete (Stress_Caps (I)) /= 0
         then
            Close_Ok := False;
         end if;
      end loop;
      Check (Close_Ok, "cap stress closed 300");

      Reuse := Akernel_User.Syscalls.Mem_Alloc (1);
      Check (Reuse /= Akernel_User.Syscalls.Syscall_Failed
             and then Akernel_User.Syscalls.Cap_Delete (Reuse) = 0,
             "cap stress table reusable after close");
   end;

   --  Proc: volume (milestone 37b): the procfs server renders
   --  process_info snapshots as files over the fs protocol. It
   --  spawns after the fuzzer (manifest order), so poll the
   --  mount like any late volume. All reads race the live
   --  process set, so checks assert shapes, not exact contents.
   declare
      use type Interfaces.Unsigned_8;
      Size        : U64 := 0;
      Count       : U64 := 0;
      St          : U64;
      Name        : String (1 .. 24) := (others => Character'Val (0));
      Name_Len    : Natural;
      Is_Dir      : Boolean;
      Entries     : Natural := 0;
      Dir_Entries : Natural := 0;
      Tree_Seen   : Boolean := False;
      Digits_Ok   : Boolean;
      First_Len   : Natural := 0;
      First_Dir   : String (1 .. 24) := (others => Character'Val (0));
      Path        : String (1 .. 40);
      Path_Len    : Natural;
      Rbuf        : array (0 .. 4095) of Interfaces.Unsigned_8;

      function Contains (S : String) return Boolean is
      begin
         if Count < U64 (S'Length) then
            return False;
         end if;
         for I in 0 .. Natural (Count) - S'Length loop
            declare
               Hit : Boolean := True;
            begin
               for J in 0 .. S'Length - 1 loop
                  if Character'Val (Natural (Rbuf (I + J)))
                    /= S (S'First + J)
                  then
                     Hit := False;
                     exit;
                  end if;
               end loop;
               if Hit then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Contains;
   begin
      Check (Await_Volume ("Proc:tree"), "proc volume mounted");

      St := Akernel_User.Files.Stat ("Proc:tree", Size);
      Check (St = Akernel_User.Files.Status_Ok and then Size > 0,
             "proc tree stat ok");

      --  Tree content: pid lines with spawner links.
      St := Akernel_User.Files.Open ("Proc:tree", Size);
      Check (St = Akernel_User.Files.Status_Ok, "proc tree opens");
      St := Akernel_User.Files.Read
        ("Proc:tree", 0, Rbuf'Address, U64 (Rbuf'Length), Count);
      Check (St = Akernel_User.Files.Status_Ok and then Count > 0,
             "proc tree reads");
      Check (Contains ("pid "), "proc tree lists pids");
      Check (Contains ("spawner "), "proc tree links spawners");

      --  Root listing: the tree file plus one directory per live
      --  process, named by decimal pid.
      for Index in 0 .. 40 loop
         St := Akernel_User.Files.Read_Dir
           ("Proc:", U64 (Index), Name, Name_Len, Is_Dir, Size);
         exit when St /= Akernel_User.Files.Status_Ok;
         Entries := Entries + 1;
         if Is_Dir then
            Dir_Entries := Dir_Entries + 1;
            Digits_Ok := Name_Len > 0;
            for C in 1 .. Name_Len loop
               if Name (C) not in '0' .. '9' then
                  Digits_Ok := False;
               end if;
            end loop;
            Check (Digits_Ok, "proc dir named by pid");
            if First_Len = 0 then
               First_Len := Name_Len;
               First_Dir (1 .. Name_Len) := Name (1 .. Name_Len);
            end if;
         elsif Name_Len = 4 and then Name (1 .. 4) = "tree" then
            Tree_Seen := True;
         end if;
      end loop;
      Check (Tree_Seen, "proc root lists tree");
      Check (Dir_Entries >= 5, "proc root lists processes");

      --  Per-process directory: the status file renders one
      --  snapshot as key-value lines.
      Check (First_Len > 0, "proc has a process dir");
      if First_Len > 0 then
         Path := (others => Character'Val (0));
         Path (1 .. 5) := "Proc:";
         Path (6 .. 5 + First_Len) := First_Dir (1 .. First_Len);
         Path_Len := 5 + First_Len;

         St := Akernel_User.Files.Read_Dir
           (Path (1 .. Path_Len), 0, Name, Name_Len, Is_Dir, Size);
         Check (St = Akernel_User.Files.Status_Ok
                and then not Is_Dir
                and then Name_Len = 6
                and then Name (1 .. 6) = "status",
                "proc process dir lists status");

         Path (6 + First_Len) := '/';
         Path (7 + First_Len .. 12 + First_Len) := "status";
         Path_Len := Path_Len + 7;

         St := Akernel_User.Files.Open (Path (1 .. Path_Len), Size);
         Check (St = Akernel_User.Files.Status_Ok
                and then Size > 0, "proc status opens");
         St := Akernel_User.Files.Read
           (Path (1 .. Path_Len), 0, Rbuf'Address,
            U64 (Rbuf'Length), Count);
         Check (St = Akernel_User.Files.Status_Ok
                and then Count > 0, "proc status reads");
         Check (Contains ("process "), "proc status names process");
         Check (Contains ("spawner "), "proc status names spawner");
      end if;

      --  Read-only volume: mutating ops and unknown paths.
      Check (Akernel_User.Files.Delete ("Proc:tree") =
               Akernel_User.Files.Status_Bad_Args,
             "proc delete rejected read-only");
      Check (Akernel_User.Files.Mkdir ("Proc:x") =
               Akernel_User.Files.Status_Bad_Args,
             "proc mkdir rejected read-only");
      Check (Akernel_User.Files.Stat ("Proc:bogus", Size) =
               Akernel_User.Files.Status_Not_Found,
             "proc unknown path not found");
      Check (Akernel_User.Files.Read_Dir
               ("Proc:bogus", 0, Name, Name_Len, Is_Dir, Size) =
               Akernel_User.Files.Status_Not_Found,
             "proc unknown dir not found");
   end;

   --  Round 1: badge + round-trip + first double-reply marker.
   --  NB: the reply is copied out of the IPC buffer before any
   --  Check, because Check prints through the console stream, which
   --  itself round-trips through this thread's message buffer.
   Akernel_User.Syscalls.Message.Label := 16#AB#;
   Akernel_User.Syscalls.Message.Words := (1, 2, 3, 4, 5, 6);
   Akernel_User.Syscalls.Message.Caps := (others => 0);
   Status := Raw_Ecall (Number => Sys_IPC_Call, A0 => EP);
   declare
      R_Label : constant U64 := Akernel_User.Syscalls.Message.Label;
      R_Words : constant Akernel_User.Syscalls.IPC_Word_Array :=
        Akernel_User.Syscalls.Message.Words;
   begin
      Check (Status = 0, "echo call round 1 returned ok");
      Check (R_Label = 16#AB#, "echo round 1 label round-trips");
      Check (R_Words (0) = 16#EC40#, "echo round 1 badge delivered");
      Check (R_Words (1) = 1 and then R_Words (4) = 4,
             "echo round 1 words round-trip");
      Check (R_Words (5) = 0, "echo round 1 first-reply marker");
   end;

   --  Round 2: word 5 must carry the failed double-reply code (1).
   Akernel_User.Syscalls.Message.Label := 16#CD#;
   Akernel_User.Syscalls.Message.Words := (6, 5, 4, 3, 2, 1);
   Akernel_User.Syscalls.Message.Caps := (others => 0);
   Status := Raw_Ecall (Number => Sys_IPC_Call, A0 => EP);
   declare
      R_Words : constant Akernel_User.Syscalls.IPC_Word_Array :=
        Akernel_User.Syscalls.Message.Words;
   begin
      Check (Status = 0, "echo call round 2 returned ok");
      Check (R_Words (0) = 16#EC40# and then R_Words (1) = 6,
             "echo round 2 payload");
      Check (R_Words (5) = 1,
             "echo double reply rejected (one-shot cap)");
   end;

   --  Round 3: cap transfer. EP2's handle is rewritten into echo's
   --  table (first free handle there = 3: endpoint at 1, console at
   --  2); echo reports it.
   EP2 := Raw_Ecall (Number => Sys_EP_Create);
   Check (EP2 < 256 and then EP2 /= EP, "second endpoint created");
   Akernel_User.Syscalls.Message.Label := 16#EF#;
   Akernel_User.Syscalls.Message.Words := (others => 0);
   Akernel_User.Syscalls.Message.Caps := (EP2, 0, 0, 0);
   Status := Raw_Ecall (Number => Sys_IPC_Call, A0 => EP);
   declare
      R_Words : constant Akernel_User.Syscalls.IPC_Word_Array :=
        Akernel_User.Syscalls.Message.Words;
   begin
      Check (Status = 0, "echo call round 3 returned ok");
      Check (R_Words (0) = 16#EC40#, "echo round 3 badge delivered");
      Check (R_Words (1) = 3,
             "cap transferred and rewritten to echo handle 3");
   end;

   --  Echo exits after three rounds; reap it once it has exited.
   Reaped := False;
   for Try in 1 .. 128 loop
      Status := Raw_Ecall (Number => Sys_Reap, A0 => Echo_Process);
      if Status = 0 then
         Reaped := True;
         exit;
      end if;
      Ignore := Raw_Ecall (Number => Sys_Yield);
   end loop;
   Check (Reaped, "echo reaped after exit");

   --  Endpoint teardown (milestone 34): a receiver process's death
   --  must fail the callers parked on its endpoint instead of
   --  leaving them blocked forever (the orphaned-shell burn).
   --  Choreography: two callers queue on a fresh service endpoint,
   --  the receiver then takes the head caller and exits WITHOUT
   --  replying -> the caller awaiting the reply wakes with
   --  Reply_Gone (4), the queued caller with Endpoint_Gone (3),
   --  and a fresh caller spawned after the death fails immediately
   --  with Endpoint_Gone (3). Each caller reports its wake code in
   --  word 0 over a result endpoint, badged 1/2/3 per caller.
   declare
      use System.Storage_Elements;
      use type Akernel_User.Syscalls.U64;

      TD_Stage_VA : constant U64 := 16#5480_0000#;
      TD_Args_VA  : constant U64 := 16#5500_0000#;

      Svc_EP      : U64;
      Res_EP      : U64;
      TD_Size     : U64;
      TD_Mem      : U64;
      Args_R_Mem  : U64;
      Args_C_Mem  : U64;
      Send_EP     : U64;
      Proc        : U64;
      Procs       : array (1 .. 4) of U64 := (others => 0);
      TD_Off      : U64;
      TD_Chunk    : U64;
      TD_Count    : U64;
      TD_Staged   : Boolean := True;

      Args_R : String (1 .. 2)
        with Volatile, Address => System'To_Address
          (Integer_Address (TD_Args_VA));
      Args_C : String (1 .. 2)
        with Volatile, Address => System'To_Address
          (Integer_Address (TD_Args_VA + 4096));

      Results : array (1 .. 3) of U64 := (others => 99);
   begin
      Svc_EP := Raw_Ecall (Number => Sys_EP_Create);
      Res_EP := Raw_Ecall (Number => Sys_EP_Create);
      Check (Svc_EP < 256 and then Res_EP < 256
             and then Svc_EP /= Res_EP,
             "teardown endpoints created");

      --  Stage Tests/Teardown (memstage pattern).
      Status := Akernel_User.Files.Stat ("Tests/Teardown", TD_Size);
      Check (Status = Akernel_User.Files.Status_Ok and then TD_Size > 0,
             "teardown size via fs");

      TD_Mem := Akernel_User.Syscalls.Mem_Alloc ((TD_Size + 4095) / 4096);
      Check (TD_Mem /= Akernel_User.Syscalls.Syscall_Failed,
             "teardown staging object allocated");
      Check (Akernel_User.Syscalls.Mem_Map
               (Address_Space =>
                  Akernel_User.Syscalls.Address_Space_Cap,
                Cap           => TD_Mem,
                VA            => TD_Stage_VA,
                Offset        => 0,
                Length        => ((TD_Size + 4095) / 4096) * 4096,
                Flags         => 3) = 0,
             "teardown staging object mapped");

      Status := Akernel_User.Files.Open ("Tests/Teardown", TD_Size);
      Check (Status = Akernel_User.Files.Status_Ok,
             "teardown open ok");
      TD_Off := 0;
      while TD_Off < TD_Size loop
         TD_Chunk := U64'Min (TD_Size - TD_Off, 32768);
         Status := Akernel_User.Files.Read
           ("Tests/Teardown", TD_Off,
            System'To_Address (Integer_Address (TD_Stage_VA + TD_Off)),
            TD_Chunk, TD_Count);
         TD_Staged := TD_Staged
           and then Status = Akernel_User.Files.Status_Ok
           and then TD_Count = TD_Chunk;
         TD_Off := TD_Off + TD_Chunk;
      end loop;
      Check (TD_Staged, "teardown ELF staged into memory object");

      --  Argument pages: role letter + NUL at grant index 3
      --  (handle 4, Syscalls.Args_Handle).
      Args_R_Mem := Akernel_User.Syscalls.Mem_Alloc (1);
      Args_C_Mem := Akernel_User.Syscalls.Mem_Alloc (1);
      Check (Args_R_Mem /= Akernel_User.Syscalls.Syscall_Failed
             and then Args_C_Mem /= Akernel_User.Syscalls.Syscall_Failed,
             "teardown args objects allocated");
      Check (Akernel_User.Syscalls.Mem_Map
               (Akernel_User.Syscalls.Address_Space_Cap,
                Args_R_Mem, TD_Args_VA, 0, 4096, 3) = 0
             and then Akernel_User.Syscalls.Mem_Map
               (Akernel_User.Syscalls.Address_Space_Cap,
                Args_C_Mem, TD_Args_VA + 4096, 0, 4096, 3) = 0,
             "teardown args objects mapped");
      Args_R := ('R', Character'Val (0));
      Args_C := ('C', Character'Val (0));

      --  Callers 1+2 first so they queue with no receiver.
      for I in 1 .. 2 loop
         Akernel_User.Syscalls.Set_Grant
           (0, Svc_EP, Akernel_User.Syscalls.Right_Send, 0);
         Akernel_User.Syscalls.Set_Grant
           (1, Res_EP, Akernel_User.Syscalls.Right_Send, U64 (I));
         Akernel_User.Syscalls.Set_Grant
           (2, Svc_EP, Akernel_User.Syscalls.Right_Send, 0);
         Akernel_User.Syscalls.Set_Grant
           (3, Args_C_Mem,
            Akernel_User.Syscalls.Right_Map +
              Akernel_User.Syscalls.Right_Read, 0);
         Status := Akernel_User.Syscalls.Spawn (TD_Mem, 4, Proc);
         Procs (I) := Proc;
         if Status /= 0 then
            Put ("caller spawn status "); Put_Hex (Status); Put_Line ("");
         end if;
         Check (Status = 0 and then Proc /= 0,
                "teardown caller spawned");
      end loop;

      --  Receiver: receives the head caller, exits without replying.
      Akernel_User.Syscalls.Set_Grant
        (0, Svc_EP,
         Akernel_User.Syscalls.Right_Send +
           Akernel_User.Syscalls.Right_Receive, 0);
      Akernel_User.Syscalls.Set_Grant
        (1, Svc_EP, Akernel_User.Syscalls.Right_Send, 0);
      Akernel_User.Syscalls.Set_Grant
        (2, Svc_EP, Akernel_User.Syscalls.Right_Send, 0);
      Akernel_User.Syscalls.Set_Grant
        (3, Args_R_Mem,
         Akernel_User.Syscalls.Right_Map +
           Akernel_User.Syscalls.Right_Read, 0);
      Status := Akernel_User.Syscalls.Spawn (TD_Mem, 4, Proc);
      Procs (3) := Proc;
      if Status /= 0 then
         Put ("receiver spawn status "); Put_Hex (Status); Put_Line ("");
      end if;
      Check (Status = 0 and then Proc /= 0, "teardown receiver spawned");

      --  Let the receiver run and die before the fresh caller
      --  (a handful of slices is enough; each yield can donate a
      --  full timeslice to the Spin hog, so keep the count low).
      for I in 1 .. 512 loop
         Ignore := Raw_Ecall (Number => Sys_Yield);
      end loop;

      --  Caller 3: fresh call on the failed endpoint.
      Akernel_User.Syscalls.Set_Grant
        (0, Svc_EP, Akernel_User.Syscalls.Right_Send, 0);
      Akernel_User.Syscalls.Set_Grant
        (1, Res_EP, Akernel_User.Syscalls.Right_Send, 3);
      Akernel_User.Syscalls.Set_Grant
        (2, Svc_EP, Akernel_User.Syscalls.Right_Send, 0);
      Akernel_User.Syscalls.Set_Grant
        (3, Args_C_Mem,
         Akernel_User.Syscalls.Right_Map +
           Akernel_User.Syscalls.Right_Read, 0);
      Status := Akernel_User.Syscalls.Spawn (TD_Mem, 4, Proc);
      Procs (4) := Proc;
      if Status /= 0 then
         Put ("late spawn status "); Put_Hex (Status); Put_Line ("");
      end if;
      Check (Status = 0 and then Proc /= 0,
             "teardown late caller spawned");

      --  Collect the three wake-code reports (badge = caller
      --  index). Each report is a Call: reply so the reporting
      --  child can complete and exit (the last child otherwise
      --  parks awaiting a reply that never comes).
      for I in 1 .. 3 loop
         Status := Raw_Ecall (Number => Sys_IPC_Recv, A0 => Res_EP);
         declare
            R_Badge : constant U64 := Akernel_User.Syscalls.Message.Badge;
            R_Code  : constant U64 :=
              Akernel_User.Syscalls.Message.Words (0);
         begin
            Akernel_User.Syscalls.Message.Label := 16#7D1#;
            Akernel_User.Syscalls.Message.Words := (others => 0);
            Akernel_User.Syscalls.Message.Caps := (others => 0);
            Ignore := Raw_Ecall (Number => Sys_IPC_Reply, A0 => 254);
            Check (Status = 0, "teardown wake report delivered");
            Put ("  report badge "); Put_Hex (R_Badge);
            Put (" code "); Put_Hex (R_Code); Put_Line ("");
            if R_Badge in 1 .. 3 then
               Results (Integer (R_Badge)) := R_Code;
            end if;
         end;
      end loop;
      Check (Results (1) = 4,
             "awaiting caller woke Reply_Gone on receiver exit");
      Check (Results (2) = 3,
             "queued caller woke Endpoint_Gone on receiver exit");
      Check (Results (3) = 3,
             "fresh call on failed endpoint fails immediately");

      --  Reap all four children.
      Reaped := True;
      for I in 1 .. 4 loop
         if Procs (I) /= 0 then
            declare
               One_Reaped : Boolean := False;
            begin
               for Try in 1 .. 128 loop
                  Status := Raw_Ecall
                    (Number => Sys_Reap, A0 => Procs (I));
                  if Status = 0 then
                     One_Reaped := True;
                     exit;
                  end if;
                  Ignore := Raw_Ecall (Number => Sys_Yield);
               end loop;
               if not One_Reaped then
                  Put ("  reap child "); Put_Hex (U64 (I));
                  Put (" status "); Put_Hex (Status); Put_Line ("");
               end if;
               Reaped := Reaped and then One_Reaped;
            end;
         end if;
      end loop;
      Check (Reaped, "teardown children reaped");

      --  Plain send (milestone 35): the rendezvous ends at
      --  delivery. The sender wakes with Ok as soon as a Receive
      --  takes its message (no reply cap is minted, so a Reply
      --  attempt fails), and a send on the now-failed teardown
      --  endpoint is rejected immediately with Endpoint_Gone.
      Send_EP := Raw_Ecall (Number => Sys_EP_Create);
      Check (Send_EP < 256 and then Send_EP /= Res_EP
             and then Send_EP /= Svc_EP,
             "send endpoint created");

      --  Sender 1: fresh endpoint, queues behind no receiver.
      Args_C := ('S', Character'Val (0));
      Akernel_User.Syscalls.Set_Grant
        (0, Send_EP, Akernel_User.Syscalls.Right_Send, 0);
      Akernel_User.Syscalls.Set_Grant
        (1, Res_EP, Akernel_User.Syscalls.Right_Send, 4);
      Akernel_User.Syscalls.Set_Grant
        (2, Svc_EP, Akernel_User.Syscalls.Right_Send, 0);
      Akernel_User.Syscalls.Set_Grant
        (3, Args_C_Mem,
         Akernel_User.Syscalls.Right_Map +
           Akernel_User.Syscalls.Right_Read, 0);
      Status := Akernel_User.Syscalls.Spawn (TD_Mem, 4, Proc);
      Procs (1) := Proc;
      Check (Status = 0 and then Proc /= 0, "send peer spawned");

      --  Take the sent message: words and badge must survive the
      --  queueing, and no reply cap may be minted for a send.
      Status := Raw_Ecall (Number => Sys_IPC_Recv, A0 => Send_EP);
      declare
         S_Words : constant U64 := Akernel_User.Syscalls.Message.Words (0);
         S_Badge : constant U64 := Akernel_User.Syscalls.Message.Badge;
      begin
         Akernel_User.Syscalls.Message.Label := 16#7D1#;
         Akernel_User.Syscalls.Message.Words := (others => 0);
         Akernel_User.Syscalls.Message.Caps := (others => 0);
         Check (Status = 0 and then S_Words = 16#5EAD_5EAD#
                and then S_Badge = 0,
                "plain send delivered words and badge");
         Status := Raw_Ecall (Number => Sys_IPC_Reply, A0 => 254);
         Check (Status = 1, "reply after plain send rejected");
      end;

      --  Sender 1's report: Send returned Ok at delivery.
      Status := Raw_Ecall (Number => Sys_IPC_Recv, A0 => Res_EP);
      declare
         R_Badge : constant U64 := Akernel_User.Syscalls.Message.Badge;
         R_Code  : constant U64 :=
           Akernel_User.Syscalls.Message.Words (0);
      begin
         Akernel_User.Syscalls.Message.Label := 16#7D1#;
         Akernel_User.Syscalls.Message.Words := (others => 0);
         Akernel_User.Syscalls.Message.Caps := (others => 0);
         Ignore := Raw_Ecall (Number => Sys_IPC_Reply, A0 => 254);
         Check (Status = 0 and then R_Badge = 4 and then R_Code = 0,
                "plain send woke with Ok on delivery");
      end;

      --  Sender 2: the teardown endpoint is failed by now, so the
      --  send must fail immediately instead of queueing.
      Akernel_User.Syscalls.Set_Grant
        (0, Svc_EP, Akernel_User.Syscalls.Right_Send, 0);
      Akernel_User.Syscalls.Set_Grant
        (1, Res_EP, Akernel_User.Syscalls.Right_Send, 5);
      Akernel_User.Syscalls.Set_Grant
        (2, Svc_EP, Akernel_User.Syscalls.Right_Send, 0);
      Akernel_User.Syscalls.Set_Grant
        (3, Args_C_Mem,
         Akernel_User.Syscalls.Right_Map +
           Akernel_User.Syscalls.Right_Read, 0);
      Status := Akernel_User.Syscalls.Spawn (TD_Mem, 4, Proc);
      Procs (2) := Proc;
      Check (Status = 0 and then Proc /= 0,
             "send peer spawned on failed endpoint");

      Status := Raw_Ecall (Number => Sys_IPC_Recv, A0 => Res_EP);
      declare
         R_Badge : constant U64 := Akernel_User.Syscalls.Message.Badge;
         R_Code  : constant U64 :=
           Akernel_User.Syscalls.Message.Words (0);
      begin
         Akernel_User.Syscalls.Message.Label := 16#7D1#;
         Akernel_User.Syscalls.Message.Words := (others => 0);
         Akernel_User.Syscalls.Message.Caps := (others => 0);
         Ignore := Raw_Ecall (Number => Sys_IPC_Reply, A0 => 254);
         Check (Status = 0 and then R_Badge = 5 and then R_Code = 3,
                "plain send on failed endpoint rejected");
      end;

      --  Reap the two senders.
      Reaped := True;
      for I in 1 .. 2 loop
         if Procs (I) /= 0 then
            declare
               One_Reaped : Boolean := False;
            begin
               for Try in 1 .. 128 loop
                  Status := Raw_Ecall
                    (Number => Sys_Reap, A0 => Procs (I));
                  if Status = 0 then
                     One_Reaped := True;
                     exit;
                  end if;
                  Ignore := Raw_Ecall (Number => Sys_Yield);
               end loop;
               Reaped := Reaped and then One_Reaped;
            end;
         end if;
      end loop;
      Check (Reaped, "send peers reaped");
   end;

   --  Assigns (milestone 36): session path aliases resolved by
   --  the VFS when volume lookup fails. Mounting the system
   --  volume seeds C: -> Sys:C and ENV: -> Sys:Prefs/Env.
   declare
      use type Akernel_User.Syscalls.U64;
      A_Text : String (1 .. 40);
      A_Len  : Natural;
      S1     : U64;
      S2     : U64;
      Found_C   : Boolean := False;
      Found_ENV : Boolean := False;
      Idx    : U64 := 0;
      Count  : U64;
      Txt    : aliased String := "fz36";
   begin
      Check (Akernel_User.Files.Stat ("C:Dir", S1) =
               Akernel_User.Files.Status_Ok,
             "boot assign C: resolves");
      Check (Akernel_User.Files.Stat ("Sys:C/Dir", S2) =
               Akernel_User.Files.Status_Ok and then S1 = S2,
             "assign target matches direct path");

      --  ENV: lands on Sys:Prefs/Env: create the dirs (already
      --  present on reused images — status ignored), write
      --  through the alias, verify at the direct path, delete
      --  through the alias.
      Ignore := Akernel_User.Files.Mkdir ("Sys:Prefs");
      Ignore := Akernel_User.Files.Mkdir ("Sys:Prefs/Env");
      Status := Akernel_User.Files.Write
        ("ENV:FZTST", 0, Txt'Address, 4, Count);
      Check (Status = Akernel_User.Files.Status_Ok
             and then Count = 4,
             "boot assign ENV: write through alias");
      Check (Akernel_User.Files.Stat ("Sys:Prefs/Env/FZTST", S1) =
               Akernel_User.Files.Status_Ok and then S1 = 4,
             "assign write lands on target path");
      Check (Akernel_User.Files.Delete ("ENV:FZTST") =
               Akernel_User.Files.Status_Ok,
             "assign delete through alias");
      Check (Akernel_User.Files.Stat ("Sys:Prefs/Env/FZTST", S1) =
               Akernel_User.Files.Status_Not_Found,
             "assign delete verified at target path");

      loop
         Status := Akernel_User.Files.Assign_List (Idx, A_Text, A_Len);
         exit when Status /= Akernel_User.Files.Status_Ok;
         if A_Len = 8 and then A_Text (1 .. 8) = "C: Sys:C" then
            Found_C := True;
         end if;
         if A_Len >= 4 and then A_Text (1 .. 4) = "ENV:" then
            Found_ENV := True;
         end if;
         Idx := Idx + 1;
      end loop;
      Check (Found_C and then Found_ENV, "boot assigns listed");

      Check (Akernel_User.Files.Assign_Set ("FZ", "Sys:C") =
               Akernel_User.Files.Status_Ok,
             "assign set");
      Check (Akernel_User.Files.Stat ("FZ:Dir", S1) =
               Akernel_User.Files.Status_Ok and then S1 = S2,
             "assign resolves after set (implied separator)");
      Check (Akernel_User.Files.Assign_Set ("FZ", "") =
               Akernel_User.Files.Status_Ok,
             "assign removed");
      Check (Akernel_User.Files.Stat ("FZ:Dir", S1) =
               Akernel_User.Files.Status_Not_Found,
             "removed assign stops resolving");
   end;

   --  Notification objects: pending bits, OR-accumulation, the
   --  thread-bound fast path delivering a synthetic message through
   --  IPC_Recv, and irq_bind cap validation.
   declare
      N1   : U64;
      N2   : U64 := 0;
   begin
      N1 := Akernel_User.Syscalls.Ntfn_Create;
      Check (N1 /= Akernel_User.Syscalls.Syscall_Failed,
             "ntfn create returns handle");

      N2 := Akernel_User.Syscalls.Ntfn_Create;
      Check (N2 /= Akernel_User.Syscalls.Syscall_Failed
             and then N2 /= N1,
             "ntfn create distinct handles");

      Check (Akernel_User.Syscalls.Ntfn_Wait (16#FEED_BEEF#) =
               Akernel_User.Syscalls.Syscall_Failed,
             "ntfn wait invalid cap rejected");
      Check (Akernel_User.Syscalls.Ntfn_Signal (16#FEED_BEEF#, 1) /= 0,
             "ntfn signal invalid cap rejected");
      Check (Akernel_User.Syscalls.Ntfn_Bind_Thread (16#FEED_BEEF#) /= 0,
             "ntfn bind invalid cap rejected");

      Check (Akernel_User.Syscalls.Ntfn_Signal (N1, 5) = 0,
             "ntfn signal ok");
      Check (Akernel_User.Syscalls.Ntfn_Wait (N1) = 5,
             "ntfn wait returns pending bits");

      Check (Akernel_User.Syscalls.Ntfn_Signal (N1, 2) = 0
             and then Akernel_User.Syscalls.Ntfn_Signal (N1, 8) = 0,
             "ntfn signals ok");
      Check (Akernel_User.Syscalls.Ntfn_Wait (N1) = 10,
             "ntfn bits OR-accumulate");

      --  Bound-thread delivery: a signal lands as a synthetic
      --  message on the next IPC_Recv (fast path: bits pending
      --  before the endpoint wait).
      Check (Akernel_User.Syscalls.Ntfn_Bind_Thread (N2) = 0,
             "ntfn bind thread ok");
      Check (Akernel_User.Syscalls.Ntfn_Bind_Thread (N1) /= 0,
             "ntfn second bind rejected");
      Check (Akernel_User.Syscalls.Ntfn_Signal (N2, 16#AB#) = 0,
             "ntfn signal bound ok");
      Status := Raw_Ecall (Number => Sys_IPC_Recv, A0 => 1);
      Check (Status = 0
             and then Akernel_User.Syscalls.Message.Label =
               Akernel_User.Syscalls.Notification_Label
             and then Akernel_User.Syscalls.Message.Words (0) = 16#AB#,
             "recv delivers bound notification");

      Check (Akernel_User.Syscalls.IRQ_Bind_Ntfn (16#FEED_BEEF#, N1, 1) /= 0,
             "irq bind invalid irq cap rejected");
      Check (Akernel_User.Syscalls.IRQ_Bind_Ntfn (1, N1, 1) /= 0,
             "irq bind wrong-kind cap rejected");
   end;

   --  Random phase: every syscall except exit (9) and the blocking
   --  set.  Spawn's image
   --  cap forced to 0 so no spawn can succeed.  debug_putchar bytes
   --  constrained to printable to keep the log readable.
   while Total_Calls < Iterations loop
      Number := Next_Random mod 31;
      if (Next_Random and 16#F#) = 0 then
         Number := Next_Random;  --  occasionally a huge syscall number
      end if;

      --  Skip exit (9), the blocking IPC trio (12-14), ntfn_wait
      --  (19), cap_delete (26), cap_mint (28) and ipc_send (29):
      --  a random call/recv/wait/send with no peer or no pending
      --  bits would block this thread forever, a random delete
      --  could close this process's granted caps (console, fs) out
      --  from under the test flow, and a random mint could only
      --  fill cap-table slots.  process_info (30) stays in: it
      --  validates arguments before any write and never blocks.
      --  Directed IPC coverage is a separate milestone.
      if Number /= Sys_Exit
        and then Number /= Sys_IPC_Call
        and then Number /= Sys_IPC_Recv
        and then Number /= Sys_IPC_Reply
        and then Number /= 19
        and then Number /= Sys_Cap_Delete
        and then Number /= 28
        and then Number /= 29
      then
         A0 := Arg_Value;
         A1 := Arg_Value;
         A2 := Arg_Value;
         A3 := Arg_Value;
         A4 := Arg_Value;
         A5 := Arg_Value;

         if Number = Sys_Debug_Putchar then
            A0 := 16#20# + (A0 mod 16#5F#);
         elsif Number = Sys_Spawn then
            A0 := 0;
         end if;

         Status := Raw_Ecall
           (Number => Number, A0 => A0, A1 => A1, A2 => A2,
            A3 => A3, A4 => A4, A5 => A5);
         Total_Calls := Total_Calls + 1;
         if Number > Highest_Known and then Status = Failed then
            Unknown_Count := Unknown_Count + 1;
         end if;

         if (Total_Calls mod 1024) = 0 then
            Put ("fuzz ");
            Put_Hex (Total_Calls);
            Put_Line ("");
         end if;
      end if;
   end loop;

   --  Kernel still answers correctly after the random phase.
   Status := Raw_Ecall (Number => Sys_Boot_File_Size, A0 => Echo_Image);
   Check (Status /= Failed, "kernel alive after random phase");

   Put ("fuzz complete: calls=");
   Put_Hex (Total_Calls);
   Put (" unknowns=");
   Put_Hex (Unknown_Count);
   Put (" failures=");
   Put_Hex (Failures);
   Put_Line ("");

   --  Exit path is the final test: this thread must die cleanly and the
   --  system (init, serial driver, timer) must keep running.
   Put_Line ("fuzz exit test");
   Status := Raw_Ecall (Number => Sys_Exit);

   --  Reaching here means exit returned, which it never should.
   Put_Line ("FAIL exit returned");
end Fuzz;
