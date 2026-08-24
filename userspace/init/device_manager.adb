with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Files;
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
   Bureau_Svc      : U64 := 0;  --  Bureau window service (Send)
   --  Seat (milestone 28 slice 4): class-18 (virtio-input)
   --  service endpoints, recorded at spawn; after Bureau +
   --  terminal are up, devmgr pushes Bureau's endpoint to each
   --  (Seat_Config_Label, cap slot 0). Focus is Bureau-internal
   --  since window protocol v2 (clients hand their input
   --  endpoint over at Surface_Create).
   Seat_Config_Label : constant U64 := U64'Last - 2;
   Input_Svc     : array (0 .. 3) of U64 := (others => 0);
   Input_Count   : Natural := 0;
   --  Class-16 (GPU) display endpoint, recorded at spawn; the
   --  display stack (Bureau + terminal) launches from the Sys
   --  filesystem in Start_Display once init has the FS chain
   --  online (milestone 29).
   GPU_Svc : U64 := 0;
   --  Scratch VA for staging FS files into memory objects.
   Stage_VA : constant U64 := 16#5C00_0000#;
   --  Sys:System/Startup contents (library-level: init's stack is
   --  only 4 pages — do NOT put kilobyte buffers on it).
   Startup_Buf : String (1 .. 2048) := (others => Character'Val (0));

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
        and then Token (Token'First .. Token'First + Length - 1) = Value;
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

   --  MSI-X capability constants.
   MSIX_Cap_Id    : constant U8 := 16#11#;
   MSIX_Enable    : constant U16 := 16#8000#;
   MSIX_Function_Mask : constant U16 := 16#4000#;
   MSIX_Table_Mask    : constant U16 := 16#07FF#;

   --  Temporary VA for programming the MSI-X table in init; unmapped
   --  as soon as the device has been configured.
   MSIX_Table_VA : constant U64 := 16#5C00_0000#;

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
   --  then enable memory space + bus mastering.  Bar_Seen records
   --  which slots are real BARs after size probing.
   procedure Assign_BARs
     (Bar_Base : in out Bar_Array;
      Bar_Seen : out Bar_Flags) is
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

         --  IO BARs are left alone; the probe should not touch them.
         if (Orig and 1) = 1 then
            Bar_Seen (Index) := False;
            Index := Index + 1;
         else
            --  Probe by writing all-1s; a returned mask of 0 means the
            --  slot is absent (including the high word of a 64-bit BAR
            --  whose low word we have already processed).
            Cfg_Write32 (Reg, 16#FFFF_FFFF#);
            Mask_Lo := Cfg_Read32 (Reg);

            if Mask_Lo = 0 then
               Bar_Seen (Index) := False;
               Index := Index + 1;
            elsif ((Mask_Lo / 2) and 3) = 2 then
               --  64-bit MMIO BAR (consumes two slots).
               Cfg_Write32 (Reg + 4, 16#FFFF_FFFF#);
               Mask_Hi := Cfg_Read32 (Reg + 4);
               Mask64 := Shl (U64 (Mask_Hi), 32)
                 or U64 (Mask_Lo and 16#FFFF_FFF0#);
               Size := (not Mask64) + 1;
               Addr := (Cursor64 + Size - 1) and not (Size - 1);
               Cursor64 := Addr + Size;
               Cfg_Write32 (Reg, U32 (Addr and 16#FFFF_FFFF#));
               Cfg_Write32 (Reg + 4, U32 (Addr / 16#1_0000_0000#));
               Bar_Base (Index) := Addr;
               Bar_Base (Index + 1) := Addr;
               Bar_Seen (Index) := True;
               Bar_Seen (Index + 1) := True;
               Index := Index + 2;
            else
               --  32-bit MMIO BAR.
               Size := U64 ((not (Mask_Lo and 16#FFFF_FFF0#)) + 1);
               Addr := (Cursor32 + Size - 1) and not (Size - 1);
               Cursor32 := Addr + Size;
               Cfg_Write32 (Reg, U32 (Addr and 16#FFFF_FFFF#));
               Bar_Base (Index) := Addr;
               Bar_Seen (Index) := True;
               Index := Index + 1;
            end if;
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

   type MSIX_Info is record
      Found        : Boolean := False;
      Table_Bar    : Natural range 0 .. 5 := 0;
      Table_Offset : U32 := 0;
      Table_Size   : U16 := 0;
      Cap_Offset   : U64 := 0;
   end record;

   --  Walk the PCI capability list looking for the MSI-X capability.
   --  Returns Table_Bar, the byte offset of the table in that BAR,
   --  the number of entries (Table_Size is N-1 from the message
   --  control register, so add one), and the ECAM offset of the cap.
   procedure Find_MSIX_Capability (Info : out MSIX_Info) is
      Ptr    : U8 := Cfg_Read8 (16#34#);
      Cap_Id : U8;
      Ctrl   : U16;
      Tbl    : U32;
      Guard  : Natural := 0;
   begin
      Info := (Found => False, others => <>);

      while Ptr /= 0 and then Guard < 48 loop
         Guard := Guard + 1;
         Cap_Id := Cfg_Read8 (U64 (Ptr));

         if Cap_Id = MSIX_Cap_Id then
            Ctrl := Interfaces.Unsigned_16
              (Cfg_Read32 (U64 (Ptr) / 4 * 4) / 16#1_0000#);
            Tbl := Cfg_Read32 (U64 (Ptr) + 4);

            Info.Table_Bar    := Natural (Tbl and 16#7#);
            Info.Table_Offset := Tbl and 16#FFFF_FFF8#;
            Info.Table_Size   := (Ctrl and MSIX_Table_Mask) + 1;
            Info.Cap_Offset   := U64 (Ptr);
            Info.Found        := True;
            return;
         end if;

         Ptr := Cfg_Read8 (U64 (Ptr) + 1);
      end loop;
   end Find_MSIX_Capability;

   --  Try to set up a single shared MSI-X vector for the device.
   --  On success the kernel allocates a virtual IRQ source and returns
   --  the address/data to program into every MSI-X table entry.  The
   --  table region is mapped temporarily, then unmapped before return.
   function Setup_MSIX
     (Bar_Base : Bar_Array;
      Bar_Seen : Bar_Flags;
      Info     : MSIX_Info;
      Dev      : U64;
      IRQ_Cap  : out U64) return Boolean
   is
      Table_PA   : U64;
      Table_Len  : U64;
      Table_Cap  : U64;
      MSI_Addr   : U64;
      MSI_Data   : U64;
      Ctrl       : U16;
      Result     : U64;
      Map_Len    : U64;
      VA         : U64;
      type U32_Array is array (U64 range 0 .. 1023) of U32
        with Volatile_Components;
      Table      : U32_Array
        with Address => System.Storage_Elements.To_Address
          (System.Storage_Elements.Integer_Address (MSIX_Table_VA));
      Entry_Off  : U64;
   begin
      IRQ_Cap := Syscall_Failed;

      if not Info.Found then
         Log ("devmgr: no msix capability");
         return False;
      end if;

      if not Bar_Seen (Info.Table_Bar) then
         Log ("devmgr: msix table bar unseen");
         return False;
      end if;

      Table_PA  := Bar_Base (Info.Table_Bar) + U64 (Info.Table_Offset);
      Table_Len := U64 (Info.Table_Size) * 16;
      Map_Len   := (Table_Len + 4095) / 4096 * 4096;
      if Map_Len = 0 then
         Map_Len := 4096;
      end if;

      Table_Cap := IO_Map
        (Resource_Handle, Table_PA, Map_Len,
         Device_Id => Dev * 8);
      if Table_Cap = Syscall_Failed then
         Log ("devmgr: msix table io_map failed");
         return False;
      end if;

      Result := Map_MMIO
        (Address_Space => Address_Space_Cap,
         Cap           => Table_Cap,
         VA            => MSIX_Table_VA,
         Offset        => 0,
         Length        => Map_Len,
         Flags         => 3);
      if Result /= 0 then
         Log ("devmgr: msix table map failed");
         Result := Cap_Delete (Table_Cap);
         return False;
      end if;

      IRQ_Cap := IRQ_MSI_Create
        (Resource_Handle, Dev * 8, 0, MSI_Addr, MSI_Data);
      if IRQ_Cap = Syscall_Failed then
         Log ("devmgr: msi vector create failed");
         Result := Mem_Unmap (Address_Space_Cap, MSIX_Table_VA, Map_Len);
         Result := Cap_Delete (Table_Cap);
         return False;
      end if;

      --  Program every table entry with the same vector (single
      --  shared MSI-X vector for now).  Mask bits stay clear.
      for I in 0 .. U64 (Info.Table_Size) - 1 loop
         Entry_Off := I * 4;
         Table (Entry_Off)     := U32 (MSI_Addr and 16#FFFF_FFFF#);
         Table (Entry_Off + 1) :=
           U32 (Interfaces.Shift_Right (MSI_Addr, 32));
         Table (Entry_Off + 2) := U32 (MSI_Data);
         Table (Entry_Off + 3) := 0;
      end loop;

      --  Enable MSI-X in the message-control register.
      Ctrl := Interfaces.Unsigned_16
        (Cfg_Read32 (Info.Cap_Offset / 4 * 4) / 16#1_0000#);
      Ctrl := Ctrl or MSIX_Enable;
      Cfg_Write32
        (Info.Cap_Offset,
         (Cfg_Read32 (Info.Cap_Offset / 4 * 4) and 16#0000_FFFF#)
           or U32 (Ctrl) * 16#1_0000#);

      Result := Mem_Unmap (Address_Space_Cap, MSIX_Table_VA, Map_Len);
      Result := Cap_Delete (Table_Cap);
      Log ("devmgr: msix enabled for device" & U64'Image (Dev));
      return True;
   end Setup_MSIX;

   --  Spawn a PCI driver with the fixed 7-handle ABI, then push the
   --  driver config message (notify multiplier, IRQ source, PCI
   --  device id) as the first traffic on its service endpoint.
   procedure Spawn_PCI_Driver
     (Line_Index : Positive;
      Dev        : U64;
      Regions    : Region_Array;
      Bar_Base   : Bar_Array;
      Bar_Seen   : Bar_Flags;
      IRQ_Source : U64)
   is
      L : Driver_Line renames Lines (Line_Index);
      Image_Cap   : constant U64 := Boot_Cap (L.Path (1 .. L.Path_Len));
      Grant_Count : U64 := 0;
      Region_Cap  : U64;
      Map_Len     : U64;
      IRQ_Cap     : U64;
      MSI_IRQ_Cap : U64 := 0;
      MSI_Enabled : Boolean := False;
      MSIX        : MSIX_Info;
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
      if L.Class_Id = 18 and then Input_Count < 4 then
         Input_Svc (Input_Count) := Svc_EP;
         Input_Count := Input_Count + 1;
      end if;
      Log ("devmgr: spawned " & L.Path (1 .. L.Path_Len));

      --  If the function has an MSI-X capability, try to move it off
      --  the shared INTx line.  On success the config message carries
      --  the MSI IRQ cap in slot 0 and Word 3 = 1.
      Find_MSIX_Capability (MSIX);
      if Setup_MSIX (Bar_Base, Bar_Seen, MSIX, Dev, MSI_IRQ_Cap) then
         MSI_Enabled := True;
      end if;

      --  Driver config message: the driver replies with status 0.
      Message.Label := Driver_Config_Label;
      Message.Words := (others => 0);
      Message.Words (0) := U64 (Notify_Mult);
      Message.Words (1) := IRQ_Source;
      Message.Words (2) := Dev * 8;  --  PCI device id (bus 0)
      Message.Words (3) := (if MSI_Enabled then 1 else 0);
      Message.Caps := (others => 0);
      if MSI_Enabled then
         Message.Caps (0) := MSI_IRQ_Cap;
      end if;
      if IPC_Call (Svc_EP) /= IPC_Ok or else Message.Words (0) /= 0 then
         Log ("devmgr: driver config push failed");
      end if;

      --  GPU (class 16): record the display endpoint. The
      --  display stack (Bureau compositor + terminal client)
      --  launches later from the Sys filesystem — see
      --  Start_Display, called by init once the FS chain is
      --  online (milestone 29). Bureau takes over the scanout
      --  through the display-service protocol (the GPU
      --  driver's text console goes dark — it is NOT attached
      --  as a sink); the terminal's stream endpoint is the
      --  console sink (the Startup-Sequence CLI look: boot
      --  output scrolls in the terminal window's pane).
      if L.Class_Id = 16 then
         GPU_Svc := Svc_EP;
         Log ("devmgr: gpu online");
      end if;
   end Spawn_PCI_Driver;

   ------------------------------------------------------------------
   --  Display stack launch from the Sys filesystem (milestone 29):
   --  images are staged from BD0: through the file server into
   --  memory objects and spawned from the object caps (the
   --  memstage pattern — no kernel support needed). Handle layout
   --  is identical to the old initrd spawn, so the seat wiring is
   --  unchanged.
   ------------------------------------------------------------------

   --  Read Path from the Sys volume (BD0:) into a fresh memory
   --  object; returns the object cap (a spawnable image) or 0.
   function Stage_From_FS (Path : String) return U64 is
      Full    : constant String := "BD0:" & Path;
      Size    : U64 := 0;
      Pages   : U64;
      Mem_Cap : U64;
      Off     : U64 := 0;
      Chunk   : U64;
      Count   : U64 := 0;
      St      : U64;
      Result  : U64;
   begin
      St := Akernel_User.Files.Stat (Full, Size);
      if St /= Akernel_User.Files.Status_Ok then
         Log ("devmgr: fs stat failed: " & Path);
         return 0;
      end if;
      Pages := (Size + 4095) / 4096;
      Mem_Cap := Mem_Alloc (Pages);
      if Mem_Cap = Syscall_Failed then
         Log ("devmgr: staging alloc failed");
         return 0;
      end if;
      if Mem_Map (Address_Space_Cap, Mem_Cap, Stage_VA, 0,
                  Pages * 4096, 3) /= 0
      then
         Log ("devmgr: staging map failed");
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;
      St := Akernel_User.Files.Open (Full, Size);
      while St = Akernel_User.Files.Status_Ok and then Off < Size loop
         Chunk := U64'Min (Size - Off, 32768);
         St := Akernel_User.Files.Read
           (Full, Off,
            System.Storage_Elements.To_Address
              (System.Storage_Elements.Integer_Address
                 (Stage_VA + Off)),
            Chunk, Count);
         if St /= Akernel_User.Files.Status_Ok
           or else Count /= Chunk
         then
            exit;
         end if;
         Off := Off + Chunk;
      end loop;
      if Mem_Unmap (Address_Space_Cap, Stage_VA, Pages * 4096) /= 0
      then
         Log ("devmgr: staging unmap failed");
      end if;
      if Off < Size then
         Log ("devmgr: fs read failed: " & Path);
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;
      return Mem_Cap;
   end Stage_From_FS;

   --  Bureau handles: 1 = console Send (badged), 2 = display
   --  endpoint Send, 3 = window service Receive (init keeps the
   --  Send side as Bureau_Svc). After the spawn: push the seat
   --  (Bureau svc Send+Transfer) to every input driver — the
   --  focus is Bureau-internal since window protocol v2.
   procedure Spawn_Bureau (Image_Cap : U64) is
      Grant_Count : U64 := 0;
      Process_Cap : U64;
      Sink        : U64;
      Result      : U64;
   begin
      Bureau_Svc := EP_Create;
      if Bureau_Svc = Syscall_Failed then
         Log ("devmgr: bureau svc ep failed");
         return;
      end if;
      Set_Grant (Grant_Count, Console_Handle, Right_Send, Next_Id);
      Grant_Count := Grant_Count + 1;
      Set_Grant (Grant_Count, GPU_Svc, Right_Send, 0);
      Grant_Count := Grant_Count + 1;
      Set_Grant (Grant_Count, Bureau_Svc, Right_Receive, 0);
      Grant_Count := Grant_Count + 1;
      if Spawn (Image_Cap, Grant_Count, Process_Cap) = Spawn_Ok
        and then Process_Cap /= 0
      then
         Next_Id := Next_Id + 1;
         Log ("devmgr: spawned System/Bureau");
      else
         Log ("devmgr: bureau spawn failed");
         return;
      end if;

      --  Seat wiring: the input drivers learn Bureau.
      for I in 0 .. Input_Count - 1 loop
         Sink := Cap_Mint (Bureau_Svc, Right_Send + Right_Transfer,
                           0);
         if Sink = Syscall_Failed then
            Log ("devmgr: seat mint failed");
         else
            Message.Label := Seat_Config_Label;
            Message.Words := (others => 0);
            Message.Caps := (others => 0);
            Message.Caps (0) := Sink;
            if IPC_Call (Input_Svc (I)) /= IPC_Ok
              or else Message.Words (0) /= 0
            then
               Log ("devmgr: seat push failed");
            end if;
            Result := Cap_Delete (Sink);
         end if;
      end loop;
   end Spawn_Bureau;

   --  Uniform program ABI (milestone 31b): every program spawned
   --  from Sys: gets the same namespace — 1 = console Send
   --  (badged), 2 = file server Send, 3 = Bureau window service
   --  Send. A program is GUI only once it calls Surface_Create
   --  (the OpenWindow analog); its console endpoint, input queue
   --  and notification are created by the program itself at
   --  runtime. The terminal uses the same ABI — launching it
   --  starts the shell (milestone 31).
   procedure Spawn_Program (Path : String; Image_Cap : U64) is
      Grant_Count : U64 := 0;
      Process_Cap : U64;
   begin
      if Bureau_Svc = 0 then
         Log ("devmgr: program needs bureau first");
         return;
      end if;
      Set_Grant (Grant_Count, Console_Handle, Right_Send, Next_Id);
      Grant_Count := Grant_Count + 1;
      Set_Grant (Grant_Count, Akernel_User.Files.Endpoint,
                 Right_Send, 0);
      Grant_Count := Grant_Count + 1;
      Set_Grant (Grant_Count, Bureau_Svc, Right_Send, 0);
      Grant_Count := Grant_Count + 1;
      --  Handle 4: the elevation service (Send) — the uniform
      --  ABI for Sys: programs; terminals re-grant it to their
      --  shells, shells to commands at handle 5.
      Set_Grant (Grant_Count, Elevated_EP, Right_Send, 0);
      Grant_Count := Grant_Count + 1;
      if Spawn (Image_Cap, Grant_Count, Process_Cap) = Spawn_Ok
        and then Process_Cap /= 0
      then
         Next_Id := Next_Id + 1;
         Log ("devmgr: spawned " & Path);
      else
         Log ("devmgr: spawn failed: " & Path);
      end if;
   end Spawn_Program;

   --  The elevation service (milestone 45): System/Elevated
   --  holds the admin bootinfo cap (Manage+Transfer — it mints
   --  Manage-only child copies) and serves the init-owned
   --  Elevated endpoint. Handles: 1 = console Send (badged),
   --  2 = fs Send, 3 = Elevated EP Receive, 4 = admin.
   procedure Start_Elevated is
      Img         : U64;
      Process_Cap : U64;
      Admin_Cap   : U64;
      Grant_Count : U64 := 0;
      Result      : U64;
   begin
      if Elevated_EP = 0 then
         Log ("devmgr: no elevated endpoint");
         return;
      end if;
      Img := Stage_From_FS ("System/Elevated");
      if Img = 0 then
         Log ("devmgr: elevated image missing");
         return;
      end if;
      Admin_Cap := Boot_Cap ("admin");
      if Admin_Cap = 0 then
         Log ("devmgr: admin bootinfo cap missing");
         Result := Cap_Delete (Img);
         return;
      end if;
      Set_Grant (Grant_Count, Console_Handle, Right_Send, Next_Id);
      Grant_Count := Grant_Count + 1;
      Set_Grant (Grant_Count, Akernel_User.Files.Endpoint,
                 Right_Send, 0);
      Grant_Count := Grant_Count + 1;
      Set_Grant (Grant_Count, Elevated_EP, Right_Receive, 0);
      Grant_Count := Grant_Count + 1;
      Set_Grant (Grant_Count, Admin_Cap,
                 Right_Manage + Right_Transfer, 0);
      Grant_Count := Grant_Count + 1;
      if Spawn (Img, Grant_Count, Process_Cap) = Spawn_Ok
        and then Process_Cap /= 0
      then
         Next_Id := Next_Id + 1;
         Log ("devmgr: spawned System/Elevated");
      else
         Log ("devmgr: spawn failed: System/Elevated");
      end if;
      Result := Cap_Delete (Img);
   end Start_Elevated;

   --  Called by init after the FS chain is online: read
   --  Sys:System/Startup (one volume-relative program path per
   --  line, the Startup-Sequence analog) and spawn each known
   --  entry from the filesystem. Falls back to the initrd boot
   --  images when the list is unavailable (transition aid).
   procedure Start_Display is
      List   : constant String := "BD0:System/Startup";
      Size   : U64 := 0;
      St     : U64;
      Count  : U64 := 0;
      Tries  : Natural := 0;
      Buf_Len : Natural := 0;
      Img    : U64;
      Result : U64;
      L0, L1 : Natural;
   begin
      if GPU_Svc = 0 then
         Log ("devmgr: no gpu; display stack skipped");
         return;
      end if;

      --  The mount push is a synchronous rendezvous, but tolerate
      --  a scheduling window anyway.
      loop
         St := Akernel_User.Files.Stat (List, Size);
         exit when St = Akernel_User.Files.Status_Ok;
         Tries := Tries + 1;
         if Tries > 200 then
            exit;
         end if;
         Yield;
      end loop;

      if St = Akernel_User.Files.Status_Ok
        and then Akernel_User.Files.Open (List, Size) =
                  Akernel_User.Files.Status_Ok
      then
         if Size > U64 (Startup_Buf'Length) then
            Size := U64 (Startup_Buf'Length);
         end if;
         St := Akernel_User.Files.Read
           (List, 0, Startup_Buf'Address, Size, Count);
         if St = Akernel_User.Files.Status_Ok then
            Buf_Len := Natural (Count);
         end if;
      end if;

      if Buf_Len = 0 then
         --  Transition fallback: initrd boot images.
         Log ("devmgr: no Sys:System/Startup; initrd fallback");
         Img := Boot_Cap ("System/Bureau");
         if Img /= 0 then
            Spawn_Bureau (Img);
         else
            Log ("devmgr: bureau image unknown");
         end if;
         Img := Boot_Cap ("System/Terminal");
         if Img /= 0 then
            Spawn_Program ("System/Terminal", Img);
         else
            Log ("devmgr: terminal image unknown");
         end if;
         return;
      end if;

      L0 := 1;
      while L0 <= Buf_Len loop
         L1 := L0;
         while L1 <= Buf_Len
           and then Startup_Buf (L1) /= Character'Val (10)
           and then Startup_Buf (L1) /= Character'Val (13)
         loop
            L1 := L1 + 1;
         end loop;
         if L1 > L0 then
            declare
               Line : constant String := Startup_Buf (L0 .. L1 - 1);
            begin
               if Line = "System/Bureau" then
                  Img := Stage_From_FS (Line);
                  if Img /= 0 then
                     Spawn_Bureau (Img);
                     Result := Cap_Delete (Img);
                  end if;
               else
                  --  Uniform program (System/Terminal,
                  --  System/Demo, ...).
                  Img := Stage_From_FS (Line);
                  if Img /= 0 then
                     Spawn_Program (Line, Img);
                     Result := Cap_Delete (Img);
                  end if;
               end if;
            end;
         end if;
         L0 := L1 + 1;
      end loop;
   end Start_Display;

   --  BARs and discovered regions for one matched function (its
   --  config page is the one currently mapped at ECAM_VA).
   procedure Setup_PCI_Device (Line_Index : Positive; Dev : U64) is
      Bar_Base   : Bar_Array := (others => 0);
      Bar_Seen   : Bar_Flags := (others => False);
      Regions    : Region_Array;
      Found      : Boolean;
      Pin        : U8;
      IRQ_Source : U64 := 0;
   begin
      Assign_BARs (Bar_Base, Bar_Seen);

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

      Spawn_PCI_Driver (Line_Index, Dev, Regions,
                        Bar_Base, Bar_Seen, IRQ_Source);
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
