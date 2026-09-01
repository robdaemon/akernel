with Interfaces;
with Akernel_User.Syscalls;
with Akernel_User.Files;
with Device_Manager;

--  Init composes its namespace from the kernel-provided bootinfo
--  page and composes each child's namespace from manifest grant
--  tokens: any token naming a bootinfo entry grants that cap to
--  the child with the kernel-assigned rights; the non-bootinfo
--  tokens are ipc_test (a dynamically minted, badged endpoint) and
--  console (the console endpoint Send side; the Receive side goes to
--  the serial driver through the device manager). The manifest is
--  boot-launch data only; the kernel never sees a name.

procedure Init is
   use type Akernel_User.Syscalls.U64;

   Max_Token_Length : constant := 64;
   subtype Token_String is String (1 .. Max_Token_Length);

   Manifest_Cap : Akernel_User.Syscalls.U64 := 0;

   Manifest_Size : Akernel_User.Syscalls.U64;
   Spawned_Count : Akernel_User.Syscalls.U64 := 0;

   --  Endpoint minted at boot and granted (badged) to the fuzzer via
   --  the ipc_test manifest token: exercises the session-manager
   --  badge pattern.
   IPC_Test_EP    : Akernel_User.Syscalls.U64 := 0;
   IPC_Test_Badge : constant Akernel_User.Syscalls.U64 := 16#EC40#;

   --  Console endpoint minted at boot: Receive side granted to the
   --  console server (Drivers/Serial), Send side to every program
   --  with the console token. Clients print through
   --  Akernel_User.Console over this endpoint.
   Console_EP : Akernel_User.Syscalls.U64 := 0;

   --  File-server endpoint minted at boot: Receive side granted
   --  (fs_server token) to System/Fileserver, Send side (fs token)
   --  to clients. After spawning the file server init pushes the
   --  boot-file name table as Op_Set_Name messages, each
   --  messages (docs/IPC.md file protocol).
   FS_EP : Akernel_User.Syscalls.U64 := 0;

   --  FAT32 driver endpoint minted at boot: Receive side granted
   --  (fat32_server token) to System/Fat32, Send side pushed to
   --  the file server as Op_Add_FS (device BD0) after the driver
   --  spawns, so the VFS forwards BD0: paths to it. The driver's
   --  blk token grants it the virtio-blk service endpoint (Send)
   --  kept by the device manager.
   FAT32_EP : Akernel_User.Syscalls.U64 := 0;

   --  BeFS driver endpoint (milestone 82c): Receive side granted
   --  (bfs_server token) to System/Bfs, Send side pushed to the
   --  file server as Op_Add_FS (device BD1, label Befs) after the
   --  driver spawns. The driver's part1 token grants it the
   --  badged Send cap for GPT partition 2.
   BFS_EP : Akernel_User.Syscalls.U64 := 0;

   --  Partition service endpoint minted at boot: Receive side
   --  granted (part_server token) to System/Partmgr; Send sides
   --  granted badged 16#1000#+N by the partN tokens so clients
   --  select the partition by badge. Partmgr probes GPT on the
   --  blk device and forwards block-protocol ops with sector
   --  offset translation (zero-copy cap forwarding).
   PARTMGR_EP : Akernel_User.Syscalls.U64 := 0;

   --  Procfs endpoint minted at boot: Receive side granted
   --  (procfs_server token) to System/Procfs, Send side pushed
   --  to the file server as Op_Add_FS (device/label Proc) after
   --  the server spawns, so the VFS forwards Proc: paths to it.
   --  Procfs also takes the device_resource token: process_info
   --  introspection authority.
   PROCFS_EP : Akernel_User.Syscalls.U64 := 0;

   --  Library manager endpoint (milestone 65).  The Receive side is
   --  granted to System/Libman via the libman_server token; the Send
   --  side is granted to every program via the libman token.
   LIBMAN_EP : Akernel_User.Syscalls.U64 := 0;

   --  Network stack endpoint (milestone 71): Receive side granted
   --  (net_server token) to System/Netserv, Send side (net token)
   --  to network clients. Netserv talks the frame protocol to the
   --  class-1 driver through the netdev token (the device manager's
   --  Net_Service Send side); init mounts its Net: volume on the
   --  VFS via Op_Add_FS after spawn.
   NETSRV_EP : Akernel_User.Syscalls.U64 := 0;

   --  True once the manifest granted the part_server token, i.e. a
   --  partition manager will serve the partition endpoint.
   Partmgr_Seen : Boolean := False;

   --  Volume directive state (manifest: "volume RD0 Initrd ci"):
   --  sent to the file server as Op_Mount right after spawn,
   --  before the name table.
   Vol_Set    : Boolean := False;
   Vol_Device : String (1 .. 16) := (others => Character'Val (0));
   Vol_Dev_Len : Natural := 0;
   Vol_Label  : String (1 .. 16) := (others => Character'Val (0));
   Vol_Lab_Len : Natural := 0;
   Vol_CI     : Boolean := False;

   function Shl
     (Value  : Akernel_User.Syscalls.U64;
      Amount : Natural) return Akernel_User.Syscalls.U64
     renames Interfaces.Shift_Left;

   function Is_Space (C : Character) return Boolean is
   begin
      return C = ' ' or else C = Character'Val (9);
   end Is_Space;

   function Token_Equals
     (Token  : Token_String;
      Length : Natural;
      Value  : String) return Boolean
   is
   begin
      if Length /= Value'Length then
         return False;
      end if;

      for Index in Value'Range loop
         if Token (Index - Value'First + 1) /= Value (Index) then
            return False;
         end if;
      end loop;

      return True;
   end Token_Equals;

   function Parse_U64
     (Token  : Token_String;
      Length : Natural;
      Valid  : out Boolean) return Akernel_User.Syscalls.U64
   is
      Value : Akernel_User.Syscalls.U64 := 0;
      C     : Character;
   begin
      Valid := Length > 0;
      for Index in 1 .. Length loop
         C := Token (Index);
         if C < '0' or else C > '9' then
            Valid := False;
            return 0;
         end if;

         Value := Value * 10
           + Akernel_User.Syscalls.U64
             (Character'Pos (C) - Character'Pos ('0'));
      end loop;

      return Value;
   end Parse_U64;

   procedure Next_Token
     (Line_End  : Akernel_User.Syscalls.U64;
      Pos       : in out Akernel_User.Syscalls.U64;
      Token     : out Token_String;
      Length    : out Natural;
      Available : out Boolean)
   is
      Raw : Akernel_User.Syscalls.U64;
      C   : Character;
   begin
      Token := (others => Character'Val (0));
      Length := 0;
      Available := False;

      while Pos < Line_End loop
         Raw := Akernel_User.Syscalls.Boot_Read_Byte (Manifest_Cap, Pos);
         exit when Raw > 255;
         C := Character'Val (Natural (Raw));
         exit when not Is_Space (C);
         Pos := Pos + 1;
      end loop;

      if Pos >= Line_End then
         return;
      end if;

      Available := True;
      while Pos < Line_End loop
         Raw := Akernel_User.Syscalls.Boot_Read_Byte (Manifest_Cap, Pos);
         exit when Raw > 255;
         C := Character'Val (Natural (Raw));
         exit when Is_Space (C);

         if Length < Max_Token_Length then
            Length := Length + 1;
            Token (Length) := C;
         end if;

         Pos := Pos + 1;
      end loop;
   end Next_Token;

   --  Send Op_Mount with the manifest's volume directive.
   procedure Push_FS_Mount is
      use Akernel_User.Syscalls;
   begin
      Message.Label := 4;  --  Files.Op_Mount
      Message.Words := (others => 0);
      Message.Words (0) := U64 (Vol_Dev_Len);
      Message.Words (1) := U64 (Vol_Lab_Len);
      Message.Words (2) := (if Vol_CI then 1 else 0);
      for P in 1 .. Vol_Dev_Len loop
         Message.Words (3 + (P - 1) / 8) :=
           Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Vol_Device (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      for P in 1 .. Vol_Lab_Len loop
         Message.Words (3 + (Vol_Dev_Len + P - 1) / 8) :=
           Message.Words (3 + (Vol_Dev_Len + P - 1) / 8)
             or Shl (U64 (Character'Pos (Vol_Label (P))),
                     ((Vol_Dev_Len + P - 1) mod 8) * 8);
      end loop;
      Message.Caps := (others => 0);
      if IPC_Call (FS_EP) /= IPC_Ok then
         Debug_Put_Line ("fs mount push failed");
      end if;
   end Push_FS_Mount;

   --  Send Op_Add_Block with the given device/label and a block
   --  service endpoint (Send side, transferred in cap slot 0) so
   --  the file server mounts a block-backed volume.
   procedure Push_Block_Mount_As
     (Dev   : String;
      Lab   : String;
      EP    : Akernel_User.Syscalls.U64)
   is
      use Akernel_User.Syscalls;
      Chars : constant String := Dev & Lab;
   begin
      Message.Label := 5;  --  Files.Op_Add_Block
      Message.Words := (others => 0);
      Message.Words (0) := U64 (Dev'Length);
      Message.Words (1) := U64 (Lab'Length);
      Message.Words (2) := 1;  --  case-insensitive
      for P in 1 .. Chars'Length loop
         Message.Words (3 + (P - 1) / 8) :=
           Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Chars (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      Message.Caps := (0 => EP, others => 0);
      if IPC_Call (FS_EP) /= IPC_Ok then
         Debug_Put_Line ("block mount push failed");
      end if;
   end Push_Block_Mount_As;

   --  Send Op_Add_Block (device "WD0", label "Disk") with the blk
   --  (raw whole-device volume is WD0; BD0 is the FAT32 partition
   --  filesystem, milestone 29)
   --  driver's service endpoint.
   procedure Push_Block_Mount (Blk_EP : Akernel_User.Syscalls.U64) is
   begin
      Push_Block_Mount_As ("WD0", "Disk", Blk_EP);
   end Push_Block_Mount;

   --  Device names are <prefix><unit> with the unit an UNPADDED
   --  decimal, 0 .. 99 (PD0 .. PD9, PD10 .. PD99 — variable
   --  length, never zero-padded). The fileserver accepts device
   --  and label names up to 16 chars each and everything
   --  downstream splits at ':', so no fixed width anywhere.
   function Unit_Image (N : Natural) return String is
   begin
      if N < 10 then
         return (1 => Character'Val (Character'Pos ('0') + N));
      else
         return Character'Val (Character'Pos ('0') + N / 10)
              & Character'Val (Character'Pos ('0') + N mod 10);
      end if;
   end Unit_Image;

   --  Enumerate populated partition slots via the part_query op
   --  and mount each as a raw volume (device "PDN", label
   --  "PartN", N unpadded) on the file server, handing over a
   --  partN-badged Send cap minted from the partition service
   --  endpoint. Init
   --  deletes its own copy of each minted cap after the push;
   --  the file server keeps the volume's.
   procedure Push_Part_Mounts is
      use Akernel_User.Syscalls;
      Badge_Base : constant U64 := 16#1000#;
      Query_Cap  : U64;
      Part_Cap   : U64;
      Count      : U64;
   begin
      Query_Cap := Cap_Mint (PARTMGR_EP, Right_Send, Badge_Base);
      if Query_Cap = Syscall_Failed then
         Debug_Put_Line ("part query mint failed");
         return;
      end if;

      Message.Label := 3;  --  part_query
      Message.Words := (others => 0);
      Message.Caps := (others => 0);
      if IPC_Call (Query_Cap) /= IPC_Ok
        or else Message.Words (0) /= 0
      then
         Debug_Put_Line ("part query failed");
         if Cap_Delete (Query_Cap) /= 0 then
            Debug_Put_Line ("part query cap delete failed");
         end if;
         return;
      end if;
      Count := Message.Words (3);

      --  Probe fills slots 0 .. Count-1 in order.
      --  Caps handed to the file server need Transfer as well as
      --  Send: the kernel's message cap transfer requires the
      --  sender's cap to carry the Transfer right. Unit numbers
      --  are unpadded decimals; partmgr caps at Max_Parts (8)
      --  today, the naming itself supports 0 .. 99.
      for N in 0 .. 99 loop
         exit when U64 (N) >= Count;
         Part_Cap := Cap_Mint (PARTMGR_EP, Right_Send + Right_Transfer,
                               Badge_Base + U64 (N));
         if Part_Cap /= Syscall_Failed then
            Push_Block_Mount_As
              ("PD" & Unit_Image (N), "Part" & Unit_Image (N),
               Part_Cap);
            if Cap_Delete (Part_Cap) /= 0 then
               Debug_Put_Line ("part cap delete failed");
            end if;
         end if;
      end loop;

      if Cap_Delete (Query_Cap) /= 0 then
         Debug_Put_Line ("part query cap delete failed");
      end if;
   end Push_Part_Mounts;

   --  Send Op_Add_FS (device "BD0", label "Sys") with the
   --  FAT32 driver's service endpoint (Send side, transferred in
   --  cap slot 0) so the VFS mounts the forwarded volume.
   procedure Push_Fat32_Mount is
      use Akernel_User.Syscalls;
      Dev   : constant String := "BD0";
      Lab   : constant String := "Sys";
      Chars : constant String := Dev & Lab;
   begin
      Message.Label := 6;  --  Files.Op_Add_FS
      Message.Words := (others => 0);
      Message.Words (0) := U64 (Dev'Length);
      Message.Words (1) := U64 (Lab'Length);
      Message.Words (2) := 1;  --  case-insensitive
      for P in 1 .. Chars'Length loop
         Message.Words (3 + (P - 1) / 8) :=
           Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Chars (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      Message.Caps := (0 => FAT32_EP, others => 0);
      if IPC_Call (FS_EP) /= IPC_Ok then
         Debug_Put_Line ("fat32 mount push failed");
      end if;
   end Push_Fat32_Mount;

   --  Send Op_Add_FS (device "BD1", label "Befs") with the BeFS
   --  driver's service endpoint (milestone 82c). Case-sensitive:
   --  BeFS names are. Read-only mount for now.
   procedure Push_Bfs_Mount is
      use Akernel_User.Syscalls;
      Dev   : constant String := "BD1";
      Lab   : constant String := "Befs";
      Chars : constant String := Dev & Lab;
   begin
      Message.Label := 6;  --  Files.Op_Add_FS
      Message.Words := (others => 0);
      Message.Words (0) := U64 (Dev'Length);
      Message.Words (1) := U64 (Lab'Length);
      Message.Words (2) := 0;  --  case-sensitive
      for P in 1 .. Chars'Length loop
         Message.Words (3 + (P - 1) / 8) :=
           Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Chars (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      Message.Caps := (0 => BFS_EP, others => 0);
      if IPC_Call (FS_EP) /= IPC_Ok then
         Debug_Put_Line ("bfs mount push failed");
      end if;
   end Push_Bfs_Mount;

   --  Send Op_Add_FS (device "Proc", label "Proc") with the
   --  procfs server's service endpoint (Send side, transferred
   --  in cap slot 0) so the VFS mounts the introspection volume.
   procedure Push_Procfs_Mount is
      use Akernel_User.Syscalls;
      Dev   : constant String := "Proc";
      Lab   : constant String := "Proc";
      Chars : constant String := Dev & Lab;
   begin
      Message.Label := 6;  --  Files.Op_Add_FS
      Message.Words := (others => 0);
      Message.Words (0) := U64 (Dev'Length);
      Message.Words (1) := U64 (Lab'Length);
      Message.Words (2) := 1;  --  case-insensitive
      for P in 1 .. Chars'Length loop
         Message.Words (3 + (P - 1) / 8) :=
           Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Chars (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      Message.Caps := (0 => PROCFS_EP, others => 0);
      if IPC_Call (FS_EP) /= IPC_Ok then
         Debug_Put_Line ("procfs mount push failed");
      end if;
   end Push_Procfs_Mount;

   --  Send Op_Add_FS (device "9P0", label "Host") with the
   --  virtio-9p driver's service endpoint (Send side, transferred
   --  in cap slot 0) so the VFS mounts the host-shared volume
   --  (m79). Only called when the devmgr spawned the driver — the
   --  device is runtime opt-in via qemu args. Deadlock-safe unlike
   --  the removed netserv push: the 9p server makes no blocking fs
   --  calls during bring-up (or ever).
   procedure Push_Host_Mount (Svc : Akernel_User.Syscalls.U64) is
      use Akernel_User.Syscalls;
      Dev   : constant String := "9P0";
      Lab   : constant String := "Host";
      Chars : constant String := Dev & Lab;
   begin
      Message.Label := 6;  --  Files.Op_Add_FS
      Message.Words := (others => 0);
      Message.Words (0) := U64 (Dev'Length);
      Message.Words (1) := U64 (Lab'Length);
      Message.Words (2) := 1;  --  case-insensitive volume prefix
      for P in 1 .. Chars'Length loop
         Message.Words (3 + (P - 1) / 8) :=
           Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Chars (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      Message.Caps := (0 => Svc, others => 0);
      if IPC_Call (FS_EP) /= IPC_Ok then
         Debug_Put_Line ("host share mount push failed");
      end if;
   end Push_Host_Mount;

   --  Send Op_Add_FS (device "Net", label "Net") with the
   --  netserv server's service endpoint (Send side, transferred
   --  in cap slot 0) so the VFS mounts the network volume.
   --  REMOVED (m72a): netserv self-registers at the END of its
   --  bring-up. An init-time push let the fs synchronously forward
   --  Net: ops to a netserv still blocked on its own fs env reads
   --  — a circular fs<->netserv deadlock under SMP timing.

    --  Push the file server's boot-file table as Op_Set_Name
   --  messages, one per boot file, then a zero-handle
   --  terminator. Since milestone 38b each message TRANSFERS a
   --  minted copy of the boot-file cap in slot 0 (deleted here
   --  after the call) — the caps used to ride the spawn grant
   --  list, but that list caps at 32 entries and 81+ files blew
   --  past it (spawn failed, "fileserver online" never printed).
   procedure Push_FS_Names is
      use Akernel_User.Syscalls;
      J      : U64 := 0;
      Len    : Natural;
      Minted : U64;
   begin
      for I in 0 .. Natural (Bootinfo.Count) - 1 loop
         if Bootinfo.Entries (I).Kind = Kind_Boot_File then
            Minted := Cap_Mint
              (Bootinfo.Entries (I).Handle,
               Bootinfo.Entries (I).Rights_Mask, 0);
            if Minted = Syscall_Failed then
               Debug_Put_Line ("fs name mint failed");
               return;
            end if;

            Len := Natural (Bootinfo.Entries (I).Name_Length);
            Message.Label := 0;  --  Files.Op_Set_Name
            Message.Words := (others => 0);
            Message.Words (0) := J + 1;
            Message.Words (1) := U64 (Len);
            for P in 1 .. Len loop
               Message.Words (2 + (P - 1) / 8) :=
                 Message.Words (2 + (P - 1) / 8)
                   or Shl
                     (U64 (Character'Pos (Bootinfo.Entries (I).Name (P))),
                      ((P - 1) mod 8) * 8);
            end loop;
            Message.Caps := (0 => Minted, others => 0);
            if IPC_Call (FS_EP) /= IPC_Ok then
               Debug_Put_Line ("fs name push failed");
               return;
            end if;
            if Cap_Delete (Minted) /= 0 then
               Debug_Put_Line ("fs name mint delete failed");
            end if;
            J := J + 1;
         end if;
      end loop;

      Message.Label := 0;  --  Files.Op_Set_Name
      Message.Words := (others => 0);
      Message.Caps := (others => 0);
      if IPC_Call (FS_EP) /= IPC_Ok then
         Debug_Put_Line ("fs name push failed");
      end if;
   end Push_FS_Names;

   procedure Parse_Program_Line
     (Line_Start : Akernel_User.Syscalls.U64;
      Line_End   : Akernel_User.Syscalls.U64)
   is
      Pos         : Akernel_User.Syscalls.U64 := Line_Start;
      Token       : Token_String;
      Length      : Natural;
      Have_Token  : Boolean;
      Valid_Id    : Boolean;
      Program_Id  : Akernel_User.Syscalls.U64;
      Grant_Count : Akernel_User.Syscalls.U64 := 0;
      Image_Cap   : Akernel_User.Syscalls.U64;
      Process_Cap : Akernel_User.Syscalls.U64;
      Result      : Akernel_User.Syscalls.U64;
       Is_FS       : Boolean := False;
       Is_Fat32    : Boolean := False;
       Is_Bfs      : Boolean := False;
       Is_Procfs   : Boolean := False;
       Is_Netserv  : Boolean := False;
       Wants_Names : Boolean := False;

      procedure Grant
        (Source_Cap  : Akernel_User.Syscalls.U64;
         Rights_Mask : Akernel_User.Syscalls.U64;
         Badge       : Akernel_User.Syscalls.U64)
      is
      begin
         if Source_Cap /= 0 then
            Akernel_User.Syscalls.Set_Grant
              (Index       => Grant_Count,
               Source_Cap  => Source_Cap,
               Rights_Mask => Rights_Mask,
               Badge       => Badge);
            Grant_Count := Grant_Count + 1;
         end if;
      end Grant;
   begin
      Next_Token (Line_End, Pos, Token, Length, Have_Token);
      if not Have_Token or else Token (1) = '#' then
         return;
      end if;

      --  Volume directive: "volume <device> <label> [ci|cs]" —
      --  sent to the file server as Op_Mount after spawn.
      if Token_Equals (Token, Length, "volume") then
         Vol_Set := False;
         Vol_CI := False;

         Next_Token (Line_End, Pos, Token, Length, Have_Token);
         if not Have_Token or else Length > 16 then
            return;
         end if;
         Vol_Device := (others => Character'Val (0));
         Vol_Device (1 .. Length) := Token (1 .. Length);
         Vol_Dev_Len := Length;

         Next_Token (Line_End, Pos, Token, Length, Have_Token);
         if not Have_Token or else Length > 16 then
            return;
         end if;
         Vol_Label := (others => Character'Val (0));
         Vol_Label (1 .. Length) := Token (1 .. Length);
         Vol_Lab_Len := Length;

         Next_Token (Line_End, Pos, Token, Length, Have_Token);
         if Have_Token then
            Vol_CI := Token_Equals (Token, Length, "ci");
         end if;

         Vol_Set := True;
         return;
      end if;

      if not Token_Equals (Token, Length, "program") then
         return;
      end if;

      Next_Token (Line_End, Pos, Token, Length, Have_Token);
      if not Have_Token then
         return;
      end if;

      Program_Id := Parse_U64 (Token, Length, Valid_Id);
      if not Valid_Id then
         return;
      end if;

      --  The path token is a bootinfo entry name: resolve it to the
      --  image cap the kernel handed init for that initrd file.
      Next_Token (Line_End, Pos, Token, Length, Have_Token);
      if not Have_Token then
         return;
      end if;

      Image_Cap := Akernel_User.Syscalls.Boot_Cap (Token (1 .. Length));
      if Image_Cap = 0 then
         Akernel_User.Syscalls.Debug_Put_Line ("program image unknown");
         return;
      end if;

      loop
         Next_Token (Line_End, Pos, Token, Length, Have_Token);
         exit when not Have_Token;

         --  Grant tokens are names in init's namespace: a bootinfo
         --  entry name grants that cap with the kernel-assigned
         --  rights; ipc_test grants the badged test endpoint;
         --  console grants the console endpoint Send side, badged
         --  with the program id so the console server can
         --  line-buffer per client (line-atomic writes).
         if Token_Equals (Token, Length, "ipc_test") then
            Grant (IPC_Test_EP,
                   Akernel_User.Syscalls.Right_Send
                     + Akernel_User.Syscalls.Right_Receive
                     + Akernel_User.Syscalls.Right_Transfer
                     + Akernel_User.Syscalls.Right_Manage,
                   IPC_Test_Badge);
         elsif Token_Equals (Token, Length, "console") then
            Grant (Console_EP, Akernel_User.Syscalls.Right_Send, Program_Id);
         elsif Token_Equals (Token, Length, "fs") then
            Grant (FS_EP, Akernel_User.Syscalls.Right_Send, 0);
         elsif Token_Equals (Token, Length, "blk") then
            --  The virtio-blk service endpoint (Send), kept by the
            --  device manager; fs drivers talk block protocol to it.
            Grant (Device_Manager.Block_Service,
                   Akernel_User.Syscalls.Right_Send, 0);
         elsif Token_Equals (Token, Length, "fat32_server") then
            Is_Fat32 := True;
            Grant (FAT32_EP, Akernel_User.Syscalls.Right_Receive, 0);
         elsif Token_Equals (Token, Length, "bfs_server") then
            Is_Bfs := True;
            Grant (BFS_EP, Akernel_User.Syscalls.Right_Receive, 0);
         elsif Token_Equals (Token, Length, "part_server") then
            Partmgr_Seen := True;
            Grant (PARTMGR_EP, Akernel_User.Syscalls.Right_Receive, 0);
          elsif Token_Equals (Token, Length, "procfs_server") then
             Is_Procfs := True;
             Grant (PROCFS_EP, Akernel_User.Syscalls.Right_Receive, 0);
          elsif Token_Equals (Token, Length, "netdev") then
             --  The virtio-net frame service endpoint (Send), kept
             --  by the device manager; netserv speaks the frame
             --  protocol (Op_Info/Op_Tx/Op_Set_Rx) to it.
             Grant (Device_Manager.Net_Service,
                    Akernel_User.Syscalls.Right_Send, 0);
          elsif Token_Equals (Token, Length, "net_server") then
             Is_Netserv := True;
             Grant (NETSRV_EP, Akernel_User.Syscalls.Right_Receive, 0);
          elsif Token_Equals (Token, Length, "net_register") then
             --  Netserv self-registers its Net: volume at the end
             --  of bring-up (the fs<->netserv deadlock fix, m72a);
             --  that Op_Add_FS call must carry a Send+Transfer cap
             --  on its own endpoint, which its Receive-only server
             --  handle cannot mint — the creator grants it here.
             Grant (NETSRV_EP,
                    Akernel_User.Syscalls.Right_Send
                      + Akernel_User.Syscalls.Right_Transfer, 0);
          elsif Token_Equals (Token, Length, "net") then
             --  Network client: Send side of the netserv endpoint.
             Grant (NETSRV_EP, Akernel_User.Syscalls.Right_Send, 0);
         elsif Token_Equals (Token, Length, "elevated_svc") then
            --  The elevation service (milestone 45): Send side of
            --  the init-owned Elevated endpoint. Servers that run
            --  elevated children (the fuzz harness) re-grant it at
            --  the uniform ABI handle 5.
            Grant (Device_Manager.Elevated_EP,
                   Akernel_User.Syscalls.Right_Send, 0);
         elsif Token_Equals (Token, Length, "libman") then
            --  Shared library manager endpoint (milestone 65):
            --  Send side granted to every program. m75: +
            --  Transfer — Libman_Available probes by minting, and
            --  cap_mint requires the source Transfer right.
            Grant (LIBMAN_EP, Akernel_User.Syscalls.Right_Send
                   + Akernel_User.Syscalls.Right_Transfer, 0);
         elsif Token_Equals (Token, Length, "libman_server") then
            --  Library manager server: Receive side.
            Grant (LIBMAN_EP, Akernel_User.Syscalls.Right_Receive, 0);
         elsif Length = 5
           and then Token (1 .. 4) = "part"
           and then Token (5) in '0' .. '7'
         then
            --  partN: badged Send on the partition service; the
            --  badge selects the GPT slot inside partmgr.
            Grant (PARTMGR_EP, Akernel_User.Syscalls.Right_Send,
                   16#1000# +
                     Akernel_User.Syscalls.U64
                       (Character'Pos (Token (5))
                          - Character'Pos ('0')));
         elsif Token_Equals (Token, Length, "fs_server") then
            Is_FS := True;
            Grant (FS_EP, Akernel_User.Syscalls.Right_Receive, 0);
         elsif Token_Equals (Token, Length, "boot_files") then
            --  Boot-file caps are no longer spawn-granted (the
            --  grant list caps at 32); Push_FS_Names transfers a
            --  minted copy with each Op_Set_Name after spawn.
            Wants_Names := True;
         else
            Grant (Akernel_User.Syscalls.Boot_Cap (Token (1 .. Length)),
                   Akernel_User.Syscalls.Boot_Cap_Rights
                     (Token (1 .. Length)),
                   0);
         end if;
      end loop;

      Result := Akernel_User.Syscalls.Spawn
        (Image_Cap, Grant_Count, Process_Cap);

      if Result = Akernel_User.Syscalls.Spawn_Ok and then Process_Cap /= 0 then
         Spawned_Count := Spawned_Count + 1;
         if Program_Id = 2 then
            Akernel_User.Syscalls.Debug_Put_Line ("fileserver spawned");
         elsif Program_Id = 3 then
            Akernel_User.Syscalls.Debug_Put_Line ("fuzz spawned");
         else
            Akernel_User.Syscalls.Debug_Put_Line ("program spawned");
         end if;

         if Is_FS then
            if Vol_Set then
               Push_FS_Mount;
            end if;
         end if;

         if Wants_Names then
            Push_FS_Names;
            Akernel_User.Syscalls.Debug_Put_Line ("fs name table pushed");
         end if;

         if Is_Fat32 then
            Push_Fat32_Mount;
         end if;

         if Is_Bfs then
            Push_Bfs_Mount;
         end if;

          if Is_Procfs then
             Push_Procfs_Mount;
          end if;

          --  netserv's Net: volume is registered by netserv itself
          --  once its bring-up completes (see the removed
          --  Push_Netserv_Mount note above).
      else
         Akernel_User.Syscalls.Debug_Put_Line ("program spawn failed");
      end if;
   end Parse_Program_Line;

   procedure Parse_Manifest is
      Line_Start : Akernel_User.Syscalls.U64 := 0;
      Line_End   : Akernel_User.Syscalls.U64;
      Raw        : Akernel_User.Syscalls.U64;
      C          : Character;
   begin
      while Line_Start < Manifest_Size loop
         Line_End := Line_Start;
         while Line_End < Manifest_Size loop
            Raw := Akernel_User.Syscalls.Boot_Read_Byte
              (Manifest_Cap, Line_End);
            exit when Raw > 255;
            C := Character'Val (Natural (Raw));
            exit when C = Character'Val (10) or else C = Character'Val (13);
            Line_End := Line_End + 1;
         end loop;

         Parse_Program_Line (Line_Start, Line_End);

         Line_Start := Line_End + 1;
         while Line_Start < Manifest_Size loop
            Raw := Akernel_User.Syscalls.Boot_Read_Byte
              (Manifest_Cap, Line_Start);
            exit when Raw > 255;
            C := Character'Val (Natural (Raw));
            exit when C /= Character'Val (10) and then C /= Character'Val (13);
            Line_Start := Line_Start + 1;
         end loop;
      end loop;
   end Parse_Manifest;
begin
   Akernel_User.Syscalls.Debug_Put_Line ("init online from Ada");

   Manifest_Cap := Akernel_User.Syscalls.Boot_Cap ("System/Manifest");

   if Manifest_Cap = 0 then
      Akernel_User.Syscalls.Debug_Put_Line
        ("init fatal: bootinfo has no manifest cap");
      loop
         Akernel_User.Syscalls.Yield;
      end loop;
   end if;

   Manifest_Size := Akernel_User.Syscalls.Boot_File_Size (Manifest_Cap);
   if Manifest_Size = Akernel_User.Syscalls.Syscall_Failed then
      Akernel_User.Syscalls.Debug_Put_Line
        ("init fatal: boot manifest unavailable");
      loop
         Akernel_User.Syscalls.Yield;
      end loop;
   end if;

   Akernel_User.Syscalls.Debug_Put_Line ("boot manifest visible");
   Akernel_User.Syscalls.Debug_Put_Line ("launching manifest programs");

   IPC_Test_EP := Akernel_User.Syscalls.EP_Create;
   Console_EP := Akernel_User.Syscalls.EP_Create;
   FS_EP := Akernel_User.Syscalls.EP_Create;
   if Akernel_User.Syscalls.EP_Set_Stamp_Identity (FS_EP, True) /= 0 then
      Akernel_User.Syscalls.Debug_Put_Line
        ("init: FS endpoint identity stamp failed");
   end if;
   FAT32_EP := Akernel_User.Syscalls.EP_Create;
   BFS_EP := Akernel_User.Syscalls.EP_Create;
   PARTMGR_EP := Akernel_User.Syscalls.EP_Create;
    PROCFS_EP := Akernel_User.Syscalls.EP_Create;
    LIBMAN_EP := Akernel_User.Syscalls.EP_Create;
    NETSRV_EP := Akernel_User.Syscalls.EP_Create;
   Device_Manager.Net_Client_EP := NETSRV_EP;
   Device_Manager.Elevated_EP := Akernel_User.Syscalls.EP_Create;

   Device_Manager.Libman_EP := LIBMAN_EP;

   --  Device-driven drivers before the static manifest programs:
   --  the console server (Drivers/Serial, class 0) must be serving
   --  the console endpoint before any manifest program prints, or
   --  the fs name push below deadlocks against the file server's
   --  first console write.
   Device_Manager.Run (Console_EP);

   Parse_Manifest;

   --  The file server exists now; mount the block-backed volume if
   --  the devmgr spawned a class-2 (block) driver.
   if Device_Manager.Block_Service /= 0 then
      Push_Block_Mount (Device_Manager.Block_Service);
   end if;

   --  Host-shared volume (m79): only when QEMU was launched with a
   --  virtio-9p device and the devmgr spawned its driver; absent
   --  device = no mount, no error.
   if Device_Manager.Np_Service /= 0 then
      Push_Host_Mount (Device_Manager.Np_Service);
   end if;

   --  Per-partition raw volumes (PD0:disk ...) if the manifest ran
   --  a partition manager; blocks until partmgr has probed and
   --  serves (rendezvous orders this naturally).
   if Partmgr_Seen then
      Push_Part_Mounts;
   end if;

   --  Display stack launches from the Sys filesystem now that
   --  the FS chain is online (milestone 29): bind the fs client
   --  and let the devmgr run Sys:System/Startup.
   Akernel_User.Files.Bind (FS_EP);
   Device_Manager.Start_Elevated;
   Device_Manager.Start_Display;

   Akernel_User.Syscalls.Yield;
   Akernel_User.Syscalls.Debug_Put_Line ("init resumed");

   if Spawned_Count = 0 then
      Akernel_User.Syscalls.Debug_Put_Line
        ("init fatal: no manifest programs spawned");
   end if;

   loop
      Akernel_User.Syscalls.Yield;
   end loop;
end Init;
