with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Device_Tree;

package body Device_Manager is
   use Akernel_User.Syscalls;
   use type U64;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_8;
   use type Device_Tree.Status;

   subtype U32 is Interfaces.Unsigned_32;

   Max_Lines       : constant := 8;
   Max_Token       : constant := 64;
   First_Driver_Id : constant U64 := 16;

   DTB_VA   : constant U64 := 16#5600_0000#;
   Probe_VA : constant U64 := 16#5640_0000#;
   ECAM_VA  : constant U64 := 16#5680_0000#;

   --  PCI: one 4 KiB probe window (io_map caps are limited to 64
   --  pages) remapped per function; drivers never see the ECAM,
   --  they get per-region BAR caps. BARs are assigned by us (no
   --  firmware PCI init on riscv virt) into the host's MMIO32 /
   --  MMIO64 windows (DTB ranges of pci@30000000 on qemu virt).
   ECAM_Window_Len : constant U64 := 4096;
   MMIO32_Window : constant U64 := 16#4000_0000#;
   MMIO64_Window : constant U64 := 16#4_0000_0000#;

   --  First message on every spawned PCI driver's service endpoint
   --  (handle 7): the driver answers it with a status word, so the
   --  rendezvous also orders the devmgr after driver startup.
   Driver_Config_Label : constant U64 := U64'Last - 1;

   --  Stream-protocol sink registration (shared with the console
   --  server and Akernel_User.Streams; kept local to avoid the
   --  rts dependency here).
   Op_Attach_Sink_Label : constant U64 := 4;

   type Probe_Kind is (Probe_None, Probe_Virtio, Probe_PCI);

   type Driver_Line is record
      Compatible : String (1 .. Max_Token) := (others => Character'Val (0));
      Compat_Len : Natural := 0;
      Path       : String (1 .. Max_Token) := (others => Character'Val (0));
      Path_Len   : Natural := 0;
      Probe      : Probe_Kind := Probe_None;
      Class_Id   : U32 := 0;
      --  Probe_PCI: "pci,<vid4>" from the Compatible token; the
      --  class id carries the virtio device id (see Parse_DB).
      Vid        : U32 := 0;
   end record;

   Lines      : array (1 .. Max_Lines) of Driver_Line;
   Line_Count : Natural := 0;

   Console_Handle  : U64 := 0;
   Resource_Handle : U64 := 0;
   Block_EP        : U64 := 0;

   function Block_Service return U64 is (Block_EP);
   Next_Id         : U64 := First_Driver_Id;

   function Shl (Value : U64; Amount : Natural) return U64
     renames Interfaces.Shift_Left;

   ------------------------------------------------------------------
   --  System/Drivers parsing (byte API, same shape as the manifest)
   ------------------------------------------------------------------

   DB_Cap  : U64 := 0;
   DB_Size : U64 := 0;

   function DB_Byte (Offset : U64) return Character is
      Raw : constant U64 := Boot_Read_Byte (DB_Cap, Offset);
   begin
      if Raw > 255 then
         return Character'Val (0);
      end if;
      return Character'Val (Natural (Raw));
   end DB_Byte;

   function Is_Space (C : Character) return Boolean is
   begin
      return C = ' ' or else C = Character'Val (9);
   end Is_Space;

   procedure Next_Token
     (Line_End  : U64;
      Pos       : in out U64;
      Token     : out String;
      Length    : out Natural;
      Available : out Boolean)
   is
      C : Character;
   begin
      Length := 0;
      Available := False;

      while Pos < Line_End loop
         C := DB_Byte (Pos);
         exit when not Is_Space (C);
         Pos := Pos + 1;
      end loop;

      if Pos >= Line_End then
         return;
      end if;

      Available := True;
      while Pos < Line_End loop
         C := DB_Byte (Pos);
         exit when Is_Space (C);

         if Length < Token'Length then
            Length := Length + 1;
            Token (Length) := C;
         end if;

         Pos := Pos + 1;
      end loop;
   end Next_Token;

   function Token_Equals
     (Token : String; Length : Natural; Value : String) return Boolean
   is
   begin
      return Length = Value'Length
        and then Token (1 .. Length) = Value;
   end Token_Equals;

   function Parse_U32
     (Token : String; Length : Natural; Valid : out Boolean) return U32
   is
      Value : U32 := 0;
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
           + U32 (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      return Value;
   end Parse_U32;

   function Parse_Hex32
     (Token : String; First : Positive; Last : Positive;
      Valid : out Boolean) return U32
   is
      Value : U32 := 0;
      C     : Character;
      Digit : U32;
   begin
      Valid := True;
      for Index in First .. Last loop
         C := Token (Index);
         if C in '0' .. '9' then
            Digit := U32 (Character'Pos (C) - Character'Pos ('0'));
         elsif C in 'a' .. 'f' then
            Digit := U32 (Character'Pos (C) - Character'Pos ('a')) + 10;
         elsif C in 'A' .. 'F' then
            Digit := U32 (Character'Pos (C) - Character'Pos ('A')) + 10;
         else
            Valid := False;
            return 0;
         end if;
         Value := Value * 16 + Digit;
      end loop;
      return Value;
   end Parse_Hex32;

   procedure Parse_DB is
      Line_Start : U64 := 0;
      Line_End   : U64;
      Pos        : U64;
      C          : Character;
      Token      : String (1 .. Max_Token) := (others => ' ');
      Length     : Natural;
      Have       : Boolean;
      Valid      : Boolean;
   begin
      while Line_Start < DB_Size loop
         Line_End := Line_Start;
         while Line_End < DB_Size loop
            C := DB_Byte (Line_End);
            exit when C = Character'Val (10) or else C = Character'Val (13);
            Line_End := Line_End + 1;
         end loop;

         Pos := Line_Start;
         Next_Token (Line_End, Pos, Token, Length, Have);

         if Have
           and then not Token_Equals (Token, Length, "#")
           and then Token_Equals (Token, Length, "driver")
           and then Line_Count < Max_Lines
         then
            Line_Count := Line_Count + 1;
            declare
               L : Driver_Line renames Lines (Line_Count);
            begin
               Next_Token (Line_End, Pos, Token, Length, Have);
               if Have then
                  L.Compatible := (others => Character'Val (0));
                  L.Compatible (1 .. Length) := Token (1 .. Length);
                  L.Compat_Len := Length;
               end if;

               Next_Token (Line_End, Pos, Token, Length, Have);
               if Have then
                  L.Path := (others => Character'Val (0));
                  L.Path (1 .. Length) := Token (1 .. Length);
                  L.Path_Len := Length;
               end if;

               Next_Token (Line_End, Pos, Token, Length, Have);
               if Have
                 and then Token_Equals (Token, Length, "virtio")
               then
                  L.Probe := Probe_Virtio;
               elsif Have
                 and then Token_Equals (Token, Length, "pci")
               then
                  --  Compatible token is "pci,<vid4>" (hex); the
                  --  line's class id is the VIRTIO device id —
                  --  matching normalizes transitional (legacy
                  --  table, 0x1000+) and modern (0x1040+id) PCI
                  --  device ids to it.
                  if L.Compat_Len = 8
                    and then L.Compatible (1 .. 4) = "pci,"
                  then
                     L.Probe := Probe_PCI;
                     L.Vid := Parse_Hex32 (L.Compatible, 5, 8, Valid);
                     if not Valid then
                        L.Probe := Probe_None;
                        L.Vid := 0;
                     end if;
                  end if;
               end if;

               Next_Token (Line_End, Pos, Token, Length, Have);
               if Have then
                  L.Class_Id := Parse_U32 (Token, Length, Valid);
               end if;
            end;
         end if;

         Line_Start := Line_End + 1;
         while Line_Start < DB_Size loop
            C := DB_Byte (Line_Start);
            exit when C /= Character'Val (10)
              and then C /= Character'Val (13);
            Line_Start := Line_Start + 1;
         end loop;
      end loop;
   end Parse_DB;

   ------------------------------------------------------------------
   --  Probing + spawning
   ------------------------------------------------------------------

   type Reg_File is array (U64 range 0 .. 1023) of U32
     with Volatile_Components;

   Probe_Regs : Reg_File
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (Probe_VA));

   procedure Log (S : String) is
   begin
      Debug_Put_Line (S);
   end Log;

   --  Spawn the driver for one probed instance. MMIO_Cap is the
   --  io_map object already created for probing; IRQ_Source 0 means
   --  the node carries no interrupts.
   procedure Spawn_Driver
     (Line_Index : Positive;
      MMIO_Cap   : U64;
      IRQ_Source : U64)
   is
      L : Driver_Line renames Lines (Line_Index);
      Image_Cap   : constant U64 := Boot_Cap (L.Path (1 .. L.Path_Len));
      Grant_Count : U64 := 0;
      IRQ_Cap     : U64;
      Svc_EP      : U64;
      Process_Cap : U64;
      Result      : U64;
   begin
      if Image_Cap = 0 then
         Log ("devmgr: driver image unknown");
         return;
      end if;

      --  Handle 1 is the console endpoint: class 0 is the console
      --  server itself and receives on it; every other driver gets
      --  a Send side badged with its driver id (line-atomic console
      --  writes keyed by badge).
      if L.Class_Id = 0 then
         Set_Grant (Grant_Count, Console_Handle, Right_Receive, 0);
      else
         Set_Grant (Grant_Count, Console_Handle, Right_Send, Next_Id);
      end if;
      Grant_Count := Grant_Count + 1;
      Set_Grant (Grant_Count, MMIO_Cap,
                 Right_Map + Right_Read + Right_Write, 0);
      Grant_Count := Grant_Count + 1;

      if IRQ_Source /= 0 then
         IRQ_Cap := IRQ_Create (Resource_Handle, IRQ_Source);
         if IRQ_Cap = Syscall_Failed then
            Log ("devmgr: irq_create failed");
            return;
         end if;

         Set_Grant (Grant_Count, IRQ_Cap,
                    Right_Wait + Right_Ack, 0);
         Grant_Count := Grant_Count + 1;
      end if;

      --  Per-instance service endpoint: init keeps the Send side,
      --  the driver receives on handle 4 (or 3 when the node had
      --  no interrupts — all current virtio nodes do).
      Svc_EP := EP_Create;
      if Svc_EP = Syscall_Failed then
         Log ("devmgr: ep_create failed");
         return;
      end if;

      Set_Grant (Grant_Count, Svc_EP, Right_Receive, 0);
      Grant_Count := Grant_Count + 1;

      Result := Spawn (Image_Cap, Grant_Count, Process_Cap);
      if Result = Spawn_Ok and then Process_Cap /= 0 then
         Next_Id := Next_Id + 1;
         if L.Class_Id = 2 and then Block_EP = 0 then
            Block_EP := Svc_EP;
         end if;
         Log ("devmgr: spawned " & L.Path (1 .. L.Path_Len));
      else
         Log ("devmgr: driver spawn failed");
      end if;
   end Spawn_Driver;

   ------------------------------------------------------------------
   --  PCI (pci-host-ecam-generic host node): ECAM config access,
   --  slot scan, BAR assignment, virtio capability discovery,
   --  INTx swizzle per the host's interrupt-map (source = 32 +
   --  (dev + pin - 1) mod 4 on qemu virt). Spawned PCI drivers get
   --  a fixed 7-handle ABI: 1 console, 2 common-cfg, 3 notify,
   --  4 ISR, 5 device-cfg (io_map caps per virtio vendor cap
   --  region), 6 IRQ, 7 service endpoint.
   ------------------------------------------------------------------

   subtype U16 is Interfaces.Unsigned_16;
   subtype U8  is Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;

   PCI_Done  : Boolean := False;
   Cursor32  : U64 := MMIO32_Window;
   Cursor64  : U64 := MMIO64_Window;

   type Region_Info is record
      PA      : U64 := 0;
      Length  : U64 := 0;
      Present : Boolean := False;
   end record;

   --  Virtio vendor capability cfg_type values index the array.
   type Region_Array is array (1 .. 4) of Region_Info;

   type Bar_Array is array (0 .. 5) of U64;
   type Bar_Flags is array (0 .. 5) of Boolean;

   Notify_Mult : U32 := 0;

   --  Config accessors address the function currently mapped at
   --  ECAM_VA (PCI_Enumerate remaps the window per function).
   function Cfg_Read8 (Reg : U64) return U8 is
      V : U8
        with Volatile,
             Address => System.Storage_Elements.To_Address
               (System.Storage_Elements.Integer_Address
                 (ECAM_VA + Reg));
   begin
      return V;
   end Cfg_Read8;

   function Cfg_Read32 (Reg : U64) return U32 is
      V : U32
        with Volatile,
             Address => System.Storage_Elements.To_Address
               (System.Storage_Elements.Integer_Address
                 (ECAM_VA + Reg));
   begin
      return V;
   end Cfg_Read32;

   procedure Cfg_Write32 (Reg : U64; Value : U32) is
      V : U32
        with Volatile,
             Address => System.Storage_Elements.To_Address
               (System.Storage_Elements.Integer_Address
                 (ECAM_VA + Reg));
   begin
      V := Value;
   end Cfg_Write32;

   --  Assign every unassigned MMIO BAR of Dev an address (IO BARs
   --  are left alone; the drivers use the modern MMIO caps only),
   --  then enable memory space + bus mastering.
   procedure Assign_BARs (Bar_Base : in out Bar_Array) is
      Reg     : U64;
      Orig    : U32;
      Mask_Lo : U32;
      Mask_Hi : U32;
      Mask64  : U64;
      Size    : U64;
      Addr    : U64;
      Cmd     : U32;
      Index   : Natural := 0;
   begin
      while Index <= 5 loop
         Reg := 16#10# + 4 * U64 (Index);
         Orig := Cfg_Read32 (Reg);

         if Orig = 0 or else Orig = 16#FFFF_FFFF#
           or else (Orig and 1) = 1
         then
            --  Absent or IO BAR.
            Index := Index + 1;
         elsif ((Orig / 2) and 3) = 2 then
            --  64-bit MMIO BAR (consumes two slots).
            Cfg_Write32 (Reg, 16#FFFF_FFFF#);
            Cfg_Write32 (Reg + 4, 16#FFFF_FFFF#);
            Mask_Lo := Cfg_Read32 (Reg);
            Mask_Hi := Cfg_Read32 (Reg + 4);
            Mask64 := Shl (U64 (Mask_Hi), 32)
              or U64 (Mask_Lo and 16#FFFF_FFF0#);
            Size := (not Mask64) + 1;
            Addr := (Cursor64 + Size - 1) and not (Size - 1);
            Cursor64 := Addr + Size;
            Cfg_Write32 (Reg, U32 (Addr and 16#FFFF_FFFF#));
            Cfg_Write32 (Reg + 4, U32 (Addr / 16#1_0000_0000#));
            Bar_Base (Index) := Addr;
            Index := Index + 2;
         else
            --  32-bit MMIO BAR.
            Cfg_Write32 (Reg, 16#FFFF_FFFF#);
            Mask_Lo := Cfg_Read32 (Reg);
            Size := U64 ((not (Mask_Lo and 16#FFFF_FFF0#)) + 1);
            Addr := (Cursor32 + Size - 1) and not (Size - 1);
            Cursor32 := Addr + Size;
            Cfg_Write32 (Reg, U32 (Addr and 16#FFFF_FFFF#));
            Bar_Base (Index) := Addr;
            Index := Index + 1;
         end if;
      end loop;

      --  Command register: memory space enable + bus master enable
      --  (upper half of the word is the status register, preserved
      --  as read).
      Cmd := Cfg_Read32 (16#04#);
      Cfg_Write32 (16#04#,
                   (Cmd and 16#FFFF_0000#) or ((Cmd and 16#FFFF#) or 16#0006#));
   end Assign_BARs;

   --  Walk the PCI capability list of the mapped function and
   --  collect the virtio vendor-capability regions (common/notify/
   --  ISR/device-cfg).
   procedure Find_Virtio_Regions
     (Bar_Base : Bar_Array;
      Bar_Seen : Bar_Flags;
      Regions  : out Region_Array;
      Found    : out Boolean)
   is
      Ptr      : U8 := Cfg_Read8 (16#34#);
      Cap_Id   : U8;
      Cfg_Type : U8;
      Bar      : Natural;
      Len      : U32;
      Guard    : Natural := 0;
   begin
      Found := False;
      Regions := (others => (PA => 0, Length => 0, Present => False));
      Notify_Mult := 0;

      while Ptr /= 0 and then Guard < 48 loop
         Guard := Guard + 1;
         Cap_Id := Cfg_Read8 (U64 (Ptr));

         if Cap_Id = 16#09# then  --  vendor-specific
            Cfg_Type := Cfg_Read8 (U64 (Ptr) + 3);
            if Cfg_Type in 1 .. 4 then
               Bar := Natural (Cfg_Read8 (U64 (Ptr) + 4));
               if Bar <= 5 and then Bar_Seen (Bar) then
                  Len := Cfg_Read32 (U64 (Ptr) + 12);
                  Regions (Natural (Cfg_Type)) :=
                    (PA      => Bar_Base (Bar)
                       + U64 (Cfg_Read32 (U64 (Ptr) + 8)),
                     Length  => U64 (Len),
                     Present => True);
                  if Cfg_Type = 2 then
                     Notify_Mult := Cfg_Read32 (U64 (Ptr) + 16);
                  end if;
               end if;
            end if;
         end if;

         Ptr := Cfg_Read8 (U64 (Ptr) + 1);
      end loop;

      Found := Regions (1).Present and then Regions (2).Present
        and then Regions (3).Present and then Regions (4).Present
        and then Notify_Mult /= 0;
   end Find_Virtio_Regions;

   --  Spawn a PCI driver with the fixed 7-handle ABI, then push the
   --  driver config message (notify multiplier, IRQ source, PCI
   --  device id) as the first traffic on its service endpoint.
   procedure Spawn_PCI_Driver
     (Line_Index : Positive;
      Dev        : U64;
      Regions    : Region_Array;
      IRQ_Source : U64)
   is
      L : Driver_Line renames Lines (Line_Index);
      Image_Cap   : constant U64 := Boot_Cap (L.Path (1 .. L.Path_Len));
      Grant_Count : U64 := 0;
      Region_Cap  : U64;
      Map_Len     : U64;
      IRQ_Cap     : U64;
      Svc_EP      : U64;
      Process_Cap : U64;
      Result      : U64;
   begin
      if Image_Cap = 0 then
         Log ("devmgr: driver image unknown");
         return;
      end if;

      if L.Class_Id = 0 then
         Set_Grant (Grant_Count, Console_Handle, Right_Receive, 0);
      else
         Set_Grant (Grant_Count, Console_Handle, Right_Send, Next_Id);
      end if;
      Grant_Count := Grant_Count + 1;

      --  Handles 2..5: common-cfg, notify, ISR, device-cfg regions.
      --  Each cap is attributed to the PCI requester id so the
      --  IOMMU authorization hook can bind the driver's DMA to
      --  this device.
      for R in 1 .. 4 loop
         Map_Len := (Regions (R).Length + 4095) / 4096 * 4096;
         if Map_Len = 0 then
            Map_Len := 4096;
         end if;

         Region_Cap := IO_Map
           (Resource_Handle, Regions (R).PA, Map_Len,
            Device_Id => Dev * 8);
         if Region_Cap = Syscall_Failed then
            Log ("devmgr: pci region io_map failed");
            return;
         end if;

         Set_Grant (Grant_Count, Region_Cap,
                    Right_Map + Right_Read + Right_Write, 0);
         Grant_Count := Grant_Count + 1;
      end loop;

      if IRQ_Source /= 0 then
         IRQ_Cap := IRQ_Create (Resource_Handle, IRQ_Source);
         if IRQ_Cap = Syscall_Failed then
            Log ("devmgr: irq_create failed");
            return;
         end if;

         Set_Grant (Grant_Count, IRQ_Cap, Right_Wait + Right_Ack, 0);
         Grant_Count := Grant_Count + 1;
      end if;

      Svc_EP := EP_Create;
      if Svc_EP = Syscall_Failed then
         Log ("devmgr: ep_create failed");
         return;
      end if;

      Set_Grant (Grant_Count, Svc_EP, Right_Receive, 0);
      Grant_Count := Grant_Count + 1;

      Result := Spawn (Image_Cap, Grant_Count, Process_Cap);
      if Result /= Spawn_Ok or else Process_Cap = 0 then
         Log ("devmgr: driver spawn failed");
         return;
      end if;

      Next_Id := Next_Id + 1;
      if L.Class_Id = 2 and then Block_EP = 0 then
         Block_EP := Svc_EP;
      end if;
      Log ("devmgr: spawned " & L.Path (1 .. L.Path_Len));

      --  Driver config message: the driver replies with status 0.
      Message.Label := Driver_Config_Label;
      Message.Words := (others => 0);
      Message.Words (0) := U64 (Notify_Mult);
      Message.Words (1) := IRQ_Source;
      Message.Words (2) := Dev * 8;  --  PCI device id (bus 0)
      Message.Caps := (others => 0);
      if IPC_Call (Svc_EP) /= IPC_Ok or else Message.Words (0) /= 0 then
         Log ("devmgr: driver config push failed");
      end if;

      --  GPU (class 16): register the driver endpoint as a console
      --  output sink so the console server mirrors its line-atomic
      --  stream onto the display. The minted Send cap is
      --  transferred in cap slot 0; devmgr's copy is deleted (the
      --  console holds its own duplicate).
      if L.Class_Id = 16 then
         declare
            Sink : constant U64 :=
              Cap_Mint (Svc_EP, Right_Send + Right_Transfer, 0);
         begin
            if Sink = Syscall_Failed then
               Log ("devmgr: gpu sink mint failed");
            else
               Message.Label := Op_Attach_Sink_Label;
               Message.Words := (others => 0);
               Message.Caps := (others => 0);
               Message.Caps (0) := Sink;
               if IPC_Call (Console_Handle) /= IPC_Ok
                 or else Message.Words (0) /= 0
               then
                  Log ("devmgr: gpu sink attach failed");
               end if;
               Result := Cap_Delete (Sink);
            end if;
         end;
      end if;
   end Spawn_PCI_Driver;

   --  BARs and discovered regions for one matched function (its
   --  config page is the one currently mapped at ECAM_VA).
   procedure Setup_PCI_Device (Line_Index : Positive; Dev : U64) is
      Bar_Base   : Bar_Array := (others => 0);
      Bar_Seen   : Bar_Flags := (others => False);
      Orig       : U32;
      Regions    : Region_Array;
      Found      : Boolean;
      Pin        : U8;
      IRQ_Source : U64 := 0;
   begin
      --  Snapshot which BARs exist before assignment (Bar_Seen),
      --  then assign addresses.
      for Index in 0 .. 5 loop
         Orig := Cfg_Read32 (16#10# + 4 * U64 (Index));
         Bar_Seen (Index) := Orig /= 0
           and then Orig /= 16#FFFF_FFFF#
           and then (Orig and 1) = 0;
      end loop;

      Assign_BARs (Bar_Base);

      Find_Virtio_Regions (Bar_Base, Bar_Seen, Regions, Found);
      if not Found then
         Log ("devmgr: pci virtio regions missing");
         return;
      end if;

      for R in 1 .. 4 loop
         if Regions (R).PA mod 4096 /= 0 then
            Log ("devmgr: pci region not page aligned");
            return;
         end if;
      end loop;

      --  INTx: pin 1..4 -> PLIC source 32 + (dev + pin - 1) mod 4
      --  (host interrupt-map swizzle).
      Pin := Cfg_Read8 (16#3D#);
      if Pin in 1 .. 4 then
         IRQ_Source := 32 + (Dev + U64 (Pin) - 1) mod 4;
      end if;

      Spawn_PCI_Driver (Line_Index, Dev, Regions, IRQ_Source);
   end Setup_PCI_Device;

   --  Normalize a PCI device id to the virtio device id: modern
   --  ids are 0x1040+id; transitional ids follow the legacy
   --  vendor-did table (NOT 0x1000+id — 0x1004 is legacy SCSI).
   --  Returns 0 for non-virtio ids.
   function Virtio_Id_Of (Did : U32) return U32 is
   begin
      if Did >= 16#1040# and then Did <= 16#107F# then
         return Did - 16#1040#;
      end if;

      case Did is
         when 16#1000# => return 1;   --  net
         when 16#1001# => return 2;   --  block
         when 16#1002# => return 5;   --  balloon
         when 16#1003# => return 3;   --  console
         when 16#1004# => return 8;   --  scsi host
         when 16#1005# => return 4;   --  entropy source
         when 16#1009# => return 9;   --  9p
         when others   => return 0;
      end case;
   end Virtio_Id_Of;

   --  Scan bus 0 functions 0 and dispatch matches to the pci
   --  lines. Each function's 4 KiB config page is io_map'd,
   --  probed, then unmapped + cap_delete'd — io_map caps cap out
   --  at 64 pages, so no whole-bus ECAM window.
   procedure PCI_Enumerate (Host_Base : U64) is
      Probe_Cap : U64;
      Result    : U64;
      W0        : U32;
      Vid       : U32;
      Did       : U32;
      Mapped    : Boolean;
   begin
      for Dev in U64 range 0 .. 31 loop
         Mapped := False;
         Probe_Cap := IO_Map
           (Resource_Handle, Host_Base + Dev * 16#8000#,
            ECAM_Window_Len);

         if Probe_Cap /= Syscall_Failed then
            Result := Map_MMIO
              (Address_Space => Address_Space_Cap,
               Cap           => Probe_Cap,
               VA            => ECAM_VA,
               Offset        => 0,
               Length        => ECAM_Window_Len,
               Flags         => 3);
            Mapped := Result = 0;
         end if;

         if Dev = 0 and then not Mapped then
            Log ("devmgr: ecam probe window failed");
         end if;

         if Mapped then
            W0 := Cfg_Read32 (0);
            Vid := W0 and 16#FFFF#;
            Did := W0 / 16#1_0000#;
   
            if Vid /= 16#FFFF# and then Vid /= 0 then
               for I in 1 .. Line_Count loop
                  declare
                     L : Driver_Line renames Lines (I);
                  begin
                     if L.Probe = Probe_PCI
                       and then L.Vid = Vid
                       and then Virtio_Id_Of (Did) = L.Class_Id
                       and then L.Class_Id /= 0
                     then
                        Setup_PCI_Device (I, Dev);
                     end if;
                  end;
               end loop;
            end if;

            if Mem_Unmap (Address_Space_Cap, ECAM_VA, ECAM_Window_Len)
              /= 0
            then
               Log ("devmgr: ecam unmap failed");
            end if;
            end if;

         if Probe_Cap /= Syscall_Failed
           and then Cap_Delete (Probe_Cap) /= 0
         then
            Log ("devmgr: ecam probe cap delete failed");
         end if;
      end loop;
   end PCI_Enumerate;

   --  Map the node's registers into init, run the line's probe, and
   --  on match spawn the driver. MMIO caps are per-instance.
   procedure Handle_Node (Info : Device_Tree.Node_Info) is
      MMIO_Cap : U64;
      Map_Len  : U64;
      Result   : U64;
      Is_PCI_Host : Boolean := False;
   begin
      if Info.Base = 0 then
         return;
      end if;

      --  The PCI host node matches no driver line directly; it
      --  triggers a bus scan that matches the pci,<vid>:<did>
      --  lines against discovered functions.
      for C in 1 .. Info.Compatible_Count loop
         if Info.Compatibles (C).Length = 21
           and then Info.Compatibles (C).Text (1 .. 21) =
             "pci-host-ecam-generic"
         then
            Is_PCI_Host := True;
            exit;
         end if;
      end loop;

      if Is_PCI_Host then
         if not PCI_Done then
            PCI_Done := True;
            PCI_Enumerate (Info.Base);
         end if;
         return;
      end if;

      for I in 1 .. Line_Count loop
         declare
            L : Driver_Line renames Lines (I);
            Matches : Boolean := False;
         begin
            for C in 1 .. Info.Compatible_Count loop
               if Info.Compatibles (C).Length = L.Compat_Len
                 and then Info.Compatibles (C).Text (1 .. L.Compat_Len) =
                   L.Compatible (1 .. L.Compat_Len)
               then
                  Matches := True;
                  exit;
               end if;
            end loop;

            if Matches then
               Map_Len := (Info.Size + 4095) / 4096 * 4096;
               if Map_Len = 0 then
                  Map_Len := 4096;
               end if;

               MMIO_Cap := IO_Map (Resource_Handle, Info.Base, Map_Len);
               if MMIO_Cap = Syscall_Failed then
                  Log ("devmgr: io_map failed");
                  return;
               end if;

               case L.Probe is
                  when Probe_None =>
                     Spawn_Driver (I, MMIO_Cap, Info.IRQ);

                  when Probe_Virtio =>
                     Result := Map_MMIO
                       (Address_Space => Address_Space_Cap,
                        Cap           => MMIO_Cap,
                        VA            => Probe_VA,
                        Offset        => 0,
                        Length        => 4096,
                        Flags         => 3);
                     if Result /= 0 then
                        Log ("devmgr: probe map failed");
                        return;
                     end if;

                     declare
                        Device_Id : constant U32 := Probe_Regs (2);
                     begin
                        Result := Mem_Unmap
                          (Address_Space_Cap, Probe_VA, 4096);

                        if Device_Id = L.Class_Id then
                           Spawn_Driver (I, MMIO_Cap, Info.IRQ);
                        end if;
                     end;

                  when Probe_PCI =>
                     --  PCI lines only match discovered bus
                     --  functions (PCI_Enumerate), never nodes.
                     null;
               end case;
            end if;
         end;
      end loop;
   end Handle_Node;

   ------------------------------------------------------------------

   procedure Run (Console_EP : U64) is
      DTB_Cap    : U64;
      DTB_Size   : U64;
      Lead_In    : U64;
      Result     : U64;
      DTB_Status : Device_Tree.Status;
   begin
      Console_Handle := Console_EP;
      Resource_Handle := Boot_Cap ("device_resource");
      DTB_Cap := Boot_Cap ("dtb");
      DB_Cap := Boot_Cap ("System/Drivers");

      if Resource_Handle = 0 or else DTB_Cap = 0 or else DB_Cap = 0 then
         Log ("devmgr: missing device_resource/dtb/System/Drivers");
         return;
      end if;

      DB_Size := Boot_File_Size (DB_Cap);
      Parse_DB;

      if Line_Count = 0 then
         Log ("devmgr: empty driver database");
         return;
      end if;

      DTB_Size := Boot_File_Size (DTB_Cap);

      --  First page to learn the lead-in, then the true page span
      --  (mem_map lengths must be page-aligned).
      Result := Mem_Map_File
        (Address_Space => Address_Space_Cap,
         Cap           => DTB_Cap,
         VA            => DTB_VA,
         Offset        => 0,
         Length        => 4096,
         Lead_In       => Lead_In);
      if Result = 0 then
         declare
            Pages : constant U64 :=
              (Lead_In + DTB_Size + 4095) / 4096;
         begin
            if Pages > 1 then
               Result := Mem_Map_File
                 (Address_Space => Address_Space_Cap,
                  Cap           => DTB_Cap,
                  VA            => DTB_VA + 4096,
                  Offset        => 4096,
                  Length        => (Pages - 1) * 4096,
                  Lead_In       => Lead_In);
            end if;
         end;
      end if;

      if Result /= 0 then
         Log ("devmgr: dtb map failed");
         return;
      end if;

      Device_Tree.Walk
        (Base    => DTB_VA + Lead_In,
         On_Node => Handle_Node'Access,
         Result  => DTB_Status);

      if DTB_Status /= Device_Tree.Ok then
         if DTB_Status = Device_Tree.Bad_Magic then
            Log ("devmgr: dtb walk bad magic");
         else
            Log ("devmgr: dtb walk unsupported format");
         end if;
      end if;
   end Run;
end Device_Manager;
