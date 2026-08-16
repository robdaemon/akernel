with System;
with System.Storage_Elements;
with Interfaces;
with Ada.Streams;
with Akernel_User.Console;
with Akernel_User.Syscalls;
with Akernel_User.IPC;
with Akernel_User.Streams;
with Virtio;
with Virtio.PCI;
with Virtio.Queues;

--  Virtio input driver over the PCI transport (virtio-keyboard-pci
--  / virtio-tablet-pci / virtio-mouse-pci, modern id 1af4:1052).
--  Spawned once per matching function by init's device manager
--  (System/Drivers line of class 18); one driver image serves
--  every input device — the role is discovered from the device
--  config identification string. Fixed 7-handle PCI driver ABI
--  (grant order): 1 = console endpoint (Send), 2 = common-cfg MMIO
--  cap, 3 = notify MMIO cap, 4 = ISR MMIO cap, 5 = device-cfg MMIO
--  cap (input config: ids / select / subsel / data), 6 = IRQ cap,
--  7 = service endpoint (first message = devmgr driver config).
--
--  Only the eventq (queue 0) is programmed: 8 posted event buffers
--  (8 bytes each: u16 type, u16 code, u32 value), one descriptor
--  per buffer, descriptor id == slot index. Completions are
--  IRQ-driven (INTx -> PLIC -> thread-bound notification), each
--  completed buffer is decoded and reposted immediately.
--
--  Event routing (virtio-input uses Linux input codes):
--  - EV_KEY codes < 256: keyboard. US keymap with shift/caps
--    state; printable chars (+ enter/tab/backspace/escape) go to
--    the console server as Op_Input stream messages — the same
--    input FIFO the UART RX feeds, so keyboard and serial input
--    converge ahead of the GPU console.
--  - EV_KEY codes >= 256 (BTN_*): pointer buttons, debug-logged.
--  - EV_ABS / EV_REL: pointer motion, debug-logged on change.
--  Pointer events get a structured channel when the GPU console
--  lands; until then the serial log is their home.

procedure Virtio_Input is
   use Akernel_User.Syscalls;
   use type U64;
   use type Virtio.U8;
   use type Virtio.U16;
   use type Virtio.U32;
   use type Interfaces.Unsigned_8;

   subtype U8 is Interfaces.Unsigned_8;

   Console_EP : constant U64 := 1;
   Common_Cap : constant U64 := 2;
   Notify_Cap : constant U64 := 3;
   ISR_Cap    : constant U64 := 4;
   Cfg_Cap    : constant U64 := 5;
   IRQ_Cap    : constant U64 := 6;
   Svc_EP     : constant U64 := 7;

   Common_VA : constant U64 := 16#5000_0000#;
   Notify_VA : constant U64 := 16#5000_1000#;
   ISR_VA    : constant U64 := 16#5000_2000#;
   Cfg_VA    : constant U64 := 16#5000_3000#;
   DMA_VA    : constant U64 := 16#5004_0000#;
   --  DMA object layout: page 0 descriptors, page 1 avail ring,
   --  page 2 used ring, page 3 event slots (8 x 8 bytes).
   DMA_Pages : constant U64 := 4;

   Queue_Num  : constant Virtio.U16 := 8;
   Event_Len  : constant Virtio.U32 := 8;
   Num_Slots  : constant := 8;

   --  First service-endpoint message from the device manager.
   Driver_Config_Label : constant U64 := U64'Last - 1;
   --  Seat config: devmgr pushes Bureau's window-service endpoint
   --  (cap slot 0) once Bureau exists (GPU addr 0x7 scans after
   --  the input functions, so this arrives as a SECOND message on
   --  the service endpoint, after bring-up). From then on keys
   --  and pointer go to Bureau (Op_Key / Op_Pointer); before,
   --  keys fall back to the console input FIFO and pointer to
   --  the serial log.
   Seat_Config_Label : constant U64 := U64'Last - 2;
   Op_Key_Label     : constant U64 := 30;
   Op_Pointer_Label : constant U64 := 31;
   Seat_EP : U64 := 0;

   --  Pointer state (Last_X/Last_Y unset until the first ABS event).
   Last_X : U64 := U64'Last;
   Last_Y : U64 := U64'Last;
   Buttons   : U64 := 0;
   Abs_Dirty : Boolean := False;

   --  virtio-input config (Linux virtio_input.h layout, which is
   --  what QEMU implements: the region is the CURRENTLY SELECTED
   --  config blob — select/subsel/size at 0x00..0x02, payload at
   --  0x08 — not the ids-at-0x00 draft layout).
   Cfg_Select : constant U64 := 16#00#;
   Cfg_Subsel : constant U64 := 16#01#;
   Cfg_Size   : constant U64 := 16#02#;
   Cfg_Data   : constant U64 := 16#08#;

   Sel_None     : constant Virtio.U8 := 0;
   Sel_Ident    : constant Virtio.U8 := 16#01#;
   Sel_Ev_Bits  : constant Virtio.U8 := 16#11#;
   Sel_Abs_Info : constant Virtio.U8 := 16#12#;

   --  Linux input event types / codes.
   Ev_Syn : constant Virtio.U16 := 16#00#;
   Ev_Key : constant Virtio.U16 := 16#01#;
   Ev_Rel : constant Virtio.U16 := 16#02#;
   Ev_Abs : constant Virtio.U16 := 16#03#;

   Key_Esc        : constant := 1;
   Key_Enter      : constant := 28;
   Key_Backspace  : constant := 14;
   Key_Tab        : constant := 15;
   Key_Leftshift  : constant := 42;
   Key_Rightshift : constant := 54;
   Key_Capslock   : constant := 58;
   --  Navigation keys (milestone 57): forwarded as codes
   --  16#80#+ (Trinket.Key_*); text-only consumers (terminal
   --  line discipline) drop codes >= 16#80#. Milestone 60 fix:
   --  these are LINUX keycodes (qemu virtio-keyboard speaks
   --  input-event-codes.h) — the m57 table used PC set-1
   --  scancodes (Up=72), which only coincidentally match Linux
   --  for the typewriter block; nav keys never arrived from a
   --  real keyboard. 110 = Insert: unmapped.
   Key_Home       : constant := 102;
   Key_Up         : constant := 103;
   Key_Pageup     : constant := 104;
   Key_Left       : constant := 105;
   Key_Right      : constant := 106;
   Key_End        : constant := 107;
   Key_Down       : constant := 108;
   Key_Pagedown   : constant := 109;
   Key_Delete     : constant := 111;

   ------------------------------------------------------------------
   --  Region register access
   ------------------------------------------------------------------

   type U8_File is array (U64 range 0 .. 4095) of Virtio.U8
     with Volatile_Components;
   type U16_File is array (U64 range 0 .. 2047) of Virtio.U16
     with Volatile_Components;
   type U32_File is array (U64 range 0 .. 1023) of Virtio.U32
     with Volatile_Components;

   function To_Addr (VA : U64) return System.Address is
     (System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (VA)));

   Common8  : U8_File  with Address => To_Addr (Common_VA);
   Common16 : U16_File with Address => To_Addr (Common_VA);
   Common32 : U32_File with Address => To_Addr (Common_VA);
   Notify16 : U16_File with Address => To_Addr (Notify_VA);
   ISR8     : U8_File  with Address => To_Addr (ISR_VA);
   Cfg8     : U8_File  with Address => To_Addr (Cfg_VA);

   function Common_Read8 (Offset : U64) return Virtio.U8 is
     (Common8 (Offset));
   function Common_Read16 (Offset : U64) return Virtio.U16 is
     (Common16 (Offset / 2));
   function Common_Read32 (Offset : U64) return Virtio.U32 is
     (Common32 (Offset / 4));

   procedure Common_Write8 (Offset : U64; Value : Virtio.U8) is
   begin
      Common8 (Offset) := Value;
   end Common_Write8;

   procedure Common_Write16 (Offset : U64; Value : Virtio.U16) is
   begin
      Common16 (Offset / 2) := Value;
   end Common_Write16;

   procedure Common_Write32 (Offset : U64; Value : Virtio.U32) is
   begin
      Common32 (Offset / 4) := Value;
   end Common_Write32;

   function ISR_Read return Virtio.U32 is
     (Virtio.U32 (ISR8 (0)));

   Notify_Mult : U64 := 0;

   procedure Notify_Write (Notify_Offset : U64; Value : Virtio.U16) is
   begin
      Notify16 ((Notify_Offset * Notify_Mult) / 2) := Value;
   end Notify_Write;

   package Dev is new Virtio.PCI
     (Common_Read8   => Common_Read8,
      Common_Read16  => Common_Read16,
      Common_Read32  => Common_Read32,
      Common_Write8  => Common_Write8,
      Common_Write16 => Common_Write16,
      Common_Write32 => Common_Write32,
      ISR_Read       => ISR_Read,
      Notify_Write   => Notify_Write);

   ------------------------------------------------------------------
   --  Event slots (page 3: 8 slots x 8 bytes = 4 u16 each:
   --  [0] type, [1] code, [2..3] value little-endian)
   ------------------------------------------------------------------

   type Slot_Words is array (Natural range 0 .. 4 * Num_Slots - 1)
     of Virtio.U16 with Volatile_Components;

   Slots : Slot_Words with Address => To_Addr (DMA_VA + 3 * 4096);

   ------------------------------------------------------------------
   --  Console Op_Input channel (byte stream into the console
   --  server's input FIFO)
   ------------------------------------------------------------------

   package RPC is new Akernel_User.IPC
     (Akernel_User.Streams.Stream_Request,
      Akernel_User.Streams.Stream_Response);

   procedure Send_Input_Char (Ch : Character) is
      Req  : Akernel_User.Streams.Stream_Request;
      Resp : Akernel_User.Streams.Stream_Response;
      Rlbl : U64;
      Res  : U64;
   begin
      Req.Count := 1;
      Req.Data := (others => 0);
      Req.Data (1) := Ada.Streams.Stream_Element (Character'Pos (Ch));
      Res := RPC.Call (Console_EP, Akernel_User.Streams.Op_Input,
                       Req, RPC.No_Caps, Rlbl, Resp);
      if Res /= 0 then
         Debug_Put_Line ("virtio-input console delivery failed");
      end if;
   end Send_Input_Char;

   --  Seat channel (raw word messages to Bureau).
   procedure Send_Seat_Key (Ch : Character) is
      Res : U64;
   begin
      Message.Label := Op_Key_Label;
      Message.Words := (others => 0);
      Message.Words (0) := U64 (Character'Pos (Ch));
      Message.Caps := (others => 0);
      Res := IPC_Call (Seat_EP);
      if Res /= IPC_Ok then
         Debug_Put_Line ("virtio-input seat key delivery failed");
      end if;
   end Send_Seat_Key;

   procedure Send_Seat_Pointer is
      Res : U64;
   begin
      Message.Label := Op_Pointer_Label;
      Message.Words := (others => 0);
      Message.Words (0) := Last_X;
      Message.Words (1) := Last_Y;
      Message.Words (2) := Buttons;
      Message.Caps := (others => 0);
      Res := IPC_Call (Seat_EP);
      if Res /= IPC_Ok then
         Debug_Put_Line ("virtio-input seat pointer delivery failed");
      end if;
   end Send_Seat_Pointer;

   ------------------------------------------------------------------
   --  US keymap (unshifted / shifted), codes 0 .. 127.
   ------------------------------------------------------------------

   NUL : constant Character := Character'Val (0);

   Keymap_Unshifted : constant array (0 .. 127) of Character :=
     (NUL, Character'Val (27), '1', '2', '3', '4', '5', '6',
      '7', '8', '9', '0', '-', '=',
      Character'Val (8), Character'Val (9),
      'q', 'w', 'e', 'r', 't', 'y', 'u', 'i',
      'o', 'p', '[', ']', Character'Val (10), NUL, 'a', 's',
      'd', 'f', 'g', 'h', 'j', 'k', 'l', ';',
      ''', '`', NUL, '\', 'z', 'x', 'c', 'v',
      'b', 'n', 'm', ',', '.', '/', NUL, '*',
      NUL, ' ', NUL, others => NUL);

   Keymap_Shifted : constant array (0 .. 127) of Character :=
     (NUL, Character'Val (27), '!', '@', '#', '$', '%', '^',
      '&', '*', '(', ')', '_', '+',
      Character'Val (8), Character'Val (9),
      'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I',
      'O', 'P', '{', '}', Character'Val (10), NUL, 'A', 'S',
      'D', 'F', 'G', 'H', 'J', 'K', 'L', ':',
      '"', '~', NUL, '|', 'Z', 'X', 'C', 'V',
      'B', 'N', 'M', '<', '>', '?', NUL, '*',
      NUL, ' ', NUL, others => NUL);

   Shift_Down : Boolean := False;
   Caps_Lock  : Boolean := False;

   ------------------------------------------------------------------

   Result    : U64;
   Reply_H   : U64;  --  reply cap of the request being served (m47)
   DMA_Cap   : U64;
   Ntfn_Cap  : U64;
   Bits      : U64;
   ISR       : Virtio.U32;
   Q         : Virtio.Queues.Queue;
   Desc_PA   : U64;
   Avail_PA  : U64;
   Used_PA   : U64;
   Ev_PA     : U64;
   Head      : Virtio.U16;
   Written   : Virtio.U32;
   Is_Keyboard : Boolean := False;
   Is_Pointer  : Boolean := False;

   procedure Fail (S : String) is
   begin
      Akernel_User.Console.Put_Line ("FAIL " & S);
      Process_Exit;
   end Fail;

   procedure Map_Region (Cap : U64; VA : U64; Name : String) is
   begin
      Result := Map_MMIO
        (Address_Space => Address_Space_Cap,
         Cap           => Cap,
         VA            => VA,
         Offset        => 0,
         Length        => 4096,
         Flags         => 3);
      if Result /= 0 then
         Debug_Put_Line ("virtio-input map " & Name & " failed");
         Process_Exit;
      end if;
   end Map_Region;

   --  Config select/subsel read: returns the size byte; Data
   --  holds up to Max bytes (callers bound by what they consume).
   type Cfg_Data_Array is array (Natural range 0 .. 127) of U8;

   function Cfg_Read
     (Sel : Virtio.U8;
      Subsel : Virtio.U8;
      Data   : out Cfg_Data_Array;
      Max    : Natural) return Natural
   is
      Size : Natural;
   begin
      Cfg8 (Cfg_Select) := Sel;
      Cfg8 (Cfg_Subsel) := Subsel;
      Size := Natural (Cfg8 (Cfg_Size));
      if Size > Max then
         Size := Max;
      end if;
      for I in 0 .. Size - 1 loop
         Data (I) := Cfg8 (Cfg_Data + U64 (I));
      end loop;
      Cfg8 (Cfg_Select) := Sel_None;
      return Size;
   end Cfg_Read;

   Ident : Cfg_Data_Array;

   function Ident_Has (Frag : String) return Boolean is
   begin
      for I in 0 .. 120 - Frag'Length loop
         declare
            Match : Boolean := True;
         begin
            for J in Frag'Range loop
               if Ident (I + J - Frag'First) /=
                 U8 (Character'Pos (Frag (J)))
               then
                  Match := False;
                  exit;
               end if;
            end loop;
            if Match then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Ident_Has;

   --  Bitmap test: byte B bit N covers code B*8+N.
   function Bitmap_Test
     (Data : Cfg_Data_Array; Code : Natural) return Boolean
   is
     ((Data (Code / 8) and U8 (2 ** (Code mod 8))) /= 0);

   procedure Post_Event_Buffer (Slot : Natural) is
      D : constant Virtio.U16 := Virtio.Queues.Alloc (Q);
   begin
      if D = Virtio.No_Desc then
         Fail ("virtio-input descriptor exhaustion");
      end if;
      Virtio.Queues.Set_Buffer
        (Q, D, Ev_PA + U64 (Slot) * U64 (Event_Len), Event_Len,
         Device_Writes => True);
      Virtio.Queues.Submit (Q, D);
   end Post_Event_Buffer;

   ------------------------------------------------------------------
   --  Event decode
   ------------------------------------------------------------------

   procedure Handle_Key (Code : Natural; Pressed : Boolean) is
      Ch : Character := NUL;
   begin
      if Code = Key_Leftshift or else Code = Key_Rightshift then
         Shift_Down := Pressed;
         return;
      end if;

      if Code = Key_Capslock then
         if Pressed then
            Caps_Lock := not Caps_Lock;
         end if;
         return;
      end if;

      --  value 1 = press, 2 = autorepeat (both produce input),
      --  0 = release.
      if not Pressed or else Code > 127 then
         return;
      end if;

      --  Navigation keys bypass the ASCII keymaps: codes
      --  16#80#..16#88# (Trinket.Key_* order).
      declare
         Ext : constant array (Key_Home .. Key_Delete) of U8 :=
           (Key_Home => 16#84#, Key_Up => 16#80#,
            Key_Pageup => 16#86#, Key_Left => 16#82#,
            Key_Right => 16#83#, Key_End => 16#85#,
            Key_Down => 16#81#, Key_Pagedown => 16#87#,
            Key_Delete => 16#88#,
            others => 0);
      begin
         if Code in Key_Home .. Key_Delete
           and then Ext (Code) /= 0
         then
            if Seat_EP /= 0 then
               Send_Seat_Key (Character'Val (Natural (Ext (Code))));
            end if;
            return;
         end if;
      end;

      Ch := (if Shift_Down
             then Keymap_Shifted (Code)
             else Keymap_Unshifted (Code));

      --  CapsLock inverts letter case (shift + caps = lowercase).
      if Caps_Lock then
         if Ch in 'a' .. 'z' then
            Ch := Character'Val (Character'Pos (Ch) - 32);
         elsif Ch in 'A' .. 'Z' then
            Ch := Character'Val (Character'Pos (Ch) + 32);
         end if;
      end if;

      if Ch /= NUL then
         if Seat_EP /= 0 then
            Send_Seat_Key (Ch);
         else
            Debug_Put_Line ("input key delivered");
            Send_Input_Char (Ch);
         end if;
      end if;
   end Handle_Key;

   procedure Handle_Event (Slot : Natural) is
      E_Type : constant Natural := Natural (Slots (Slot * 4 + 0));
      E_Code : constant Natural := Natural (Slots (Slot * 4 + 1));
      E_Val  : constant U64 :=
        U64 (Slots (Slot * 4 + 2)) or U64 (Slots (Slot * 4 + 3)) * 16#1_0000#;
   begin
      if E_Type = Natural (Ev_Key) then
         if E_Code < 256 then
            Handle_Key (E_Code, E_Val /= 0);
            --  Autorepeat (value 2) counts as pressed for input.
         elsif E_Code = 272 then  --  BTN_LEFT
            Buttons := (Buttons and not 1) or (E_Val and 1);
            Abs_Dirty := True;
         elsif E_Code = 273 then  --  BTN_RIGHT
            Buttons := (Buttons and not 2) or ((E_Val and 1) * 2);
            Abs_Dirty := True;
         else
            Debug_Put_Line ("input button event");
         end if;
      elsif E_Type = Natural (Ev_Abs) then
         if E_Code = 0 then
            Last_X := E_Val;
            Abs_Dirty := True;
         elsif E_Code = 1 then
            Last_Y := E_Val;
            Abs_Dirty := True;
         end if;
      elsif E_Type = Natural (Ev_Rel) then
         Debug_Put_Line ("input rel move");
      elsif E_Type = Natural (Ev_Syn) then
         --  Event batch boundary: push one pointer message.
         if Abs_Dirty and then Seat_EP /= 0
           and then Last_X /= U64'Last and then Last_Y /= U64'Last
         then
            Abs_Dirty := False;
            Send_Seat_Pointer;
         end if;
      end if;
   end Handle_Event;

begin
   Akernel_User.Console.Set_Endpoint (Console_EP);

   Map_Region (Common_Cap, Common_VA, "common");
   Map_Region (Notify_Cap, Notify_VA, "notify");
   Map_Region (ISR_Cap,    ISR_VA,    "isr");
   Map_Region (Cfg_Cap,    Cfg_VA,    "cfg");

   --  Devmgr driver config message (notify multiplier, IRQ
   --  source, requester id); answered with status 0.
   Result := IPC_Recv (Svc_EP, Reply_H);
   if Result /= IPC_Ok or else Message.Label /= Driver_Config_Label then
      Debug_Put_Line ("virtio-input config message missing");
      Process_Exit;
   end if;
   Notify_Mult := Message.Words (0);
   Message.Words := (others => 0);
   if IPC_Reply (Reply_H) /= IPC_Ok then
      Debug_Put_Line ("virtio-input config reply failed");
      Process_Exit;
   end if;

   if Dev.Num_Queues = 0 then
      Debug_Put_Line ("virtio-input no queues");
      Process_Exit;
   end if;

   Dev.Reset;
   Dev.Set_Status (Virtio.Status_Acknowledge);
   Dev.Add_Status (Virtio.Status_Driver);
   Dev.Set_Driver_Features (0);
   Dev.Add_Status (Virtio.Status_Features_Ok);

   if (Dev.Status and Virtio.Status_Features_Ok) = 0 then
      Debug_Put_Line ("virtio-input features rejected");
      Process_Exit;
   end if;

   --  Role discovery + directed config self-tests before the
   --  queues go live: the device answers select/subsel config
   --  reads as soon as FEATURES_OK.
   --  Role discovery + directed config self-tests before the
   --  queues go live. No type bitmap exists at EV_BITS subsel 0
   --  (QEMU's config table has per-type entries only), so the
   --  checks probe the concrete types directly.
   Ident := (others => 0);
   if Cfg_Read (Sel_Ident, 0, Ident, 64) = 0 then
      Fail ("virtio-input ident read failed");
   end if;

   Is_Keyboard := Ident_Has ("Keyboard");
   Is_Pointer  := Ident_Has ("Tablet") or else Ident_Has ("Mouse");

   if Is_Keyboard then
      if Cfg_Read (Sel_Ev_Bits, Virtio.U8 (Ev_Key), Ident, 16) = 0
        or else not Bitmap_Test (Ident, 30)  --  KEY_A
      then
         Fail ("virtio-input keyboard keymap bits missing");
      end if;
      Akernel_User.Console.Put_Line ("PASS virtio-input keyboard config ok");
   elsif Is_Pointer then
      if Ident_Has ("Tablet") then
         if Cfg_Read (Sel_Ev_Bits, Virtio.U8 (Ev_Abs), Ident, 16) = 0
           or else not Bitmap_Test (Ident, 0)  --  ABS_X
         then
            Fail ("virtio-input tablet abs bits missing");
         end if;
         if Cfg_Read (Sel_Abs_Info, 0, Ident, 24) < 8
           or else (Ident (4) = 0 and then Ident (5) = 0
                    and then Ident (6) = 0 and then Ident (7) = 0)
         then
            Fail ("virtio-input tablet abs range missing");
         end if;
      else
         if Cfg_Read (Sel_Ev_Bits, Virtio.U8 (Ev_Rel), Ident, 16) = 0
         then
            Fail ("virtio-input mouse rel bits missing");
         end if;
      end if;
      Akernel_User.Console.Put_Line ("PASS virtio-input pointer config ok");
   else
      Fail ("virtio-input unknown device role");
   end if;

   --  IRQ-driven event delivery: notification bound to this
   --  thread, IRQ line bound to the notification (badge 1).
   Ntfn_Cap := Ntfn_Create;
   if Ntfn_Cap = Syscall_Failed
     or else Ntfn_Bind_Thread (Ntfn_Cap) /= 0
     or else IRQ_Bind_Ntfn (IRQ_Cap, Ntfn_Cap, Badge => 1) /= 0
   then
      Debug_Put_Line ("virtio-input ntfn setup failed");
      Process_Exit;
   end if;

   DMA_Cap := Mem_Alloc (DMA_Pages);
   if DMA_Cap = Syscall_Failed then
      Debug_Put_Line ("virtio-input dma alloc failed");
      Process_Exit;
   end if;

   Result := Mem_Map
     (Address_Space => Address_Space_Cap,
      Cap           => DMA_Cap,
      VA            => DMA_VA,
      Offset        => 0,
      Length        => DMA_Pages * 4096,
      Flags         => 3);
   if Result /= 0 then
      Debug_Put_Line ("virtio-input dma map failed");
      Process_Exit;
   end if;

   Desc_PA := Mem_Object_PA (DMA_Cap, 0);
   Avail_PA := Mem_Object_PA (DMA_Cap, 1);
   Used_PA := Mem_Object_PA (DMA_Cap, 2);
   Ev_PA   := Mem_Object_PA (DMA_Cap, 3);
   if Desc_PA = 0 or else Avail_PA = 0 or else Used_PA = 0
     or else Ev_PA = 0
   then
      Debug_Put_Line ("virtio-input dma pa query failed");
      Process_Exit;
   end if;

   Virtio.Queues.Initialize
     (Q     => Q,
      Desc  => To_Addr (DMA_VA),
      Avail => To_Addr (DMA_VA + 4096),
      Used  => To_Addr (DMA_VA + 2 * 4096),
      Num   => Queue_Num);

   Dev.Queue_Select (0);
   Dev.Queue_Setup
     (Num      => Virtio.U32 (Queue_Num),
      Desc_PA  => Desc_PA,
      Avail_PA => Avail_PA,
      Used_PA  => Used_PA);

   for Slot in 0 .. Num_Slots - 1 loop
      Post_Event_Buffer (Slot);
   end loop;

   Dev.Add_Status (Virtio.Status_Driver_Ok);

   Akernel_User.Console.Put_Line ("virtio-input service online");

   ------------------------------------------------------------------
   --  IRQ-driven event loop
   ------------------------------------------------------------------

   loop
      Result := IPC_Recv (Svc_EP, Reply_H);
      if Result /= IPC_Ok then
         Debug_Put_Line ("virtio-input recv failed");
         Process_Exit;
      end if;

      if Message.Label = Notification_Label then
         --  IRQ notification (synthetic message, NO reply cap):
         --  drain completions and ack. Every IRQ cap holder must
         --  ack after being poked (docs/IPC.md).
         ISR := Dev.Interrupt_Status;
         if ISR /= 0 then
            Dev.ACK_Interrupt (ISR);
         end if;
         Result := IRQ_Ack (IRQ_Cap);

         while Virtio.Queues.Has_Completed (Q) loop
            Virtio.Queues.Pop (Q, Head, Written);

            if Written >= Event_Len then
               Handle_Event (Natural (Head));
            end if;

            --  Repost the same descriptor (descriptor id == slot).
            Virtio.Queues.Set_Buffer
              (Q, Head, Ev_PA + U64 (Head) * U64 (Event_Len),
               Event_Len, Device_Writes => True);
            Virtio.Queues.Submit (Q, Head);
         end loop;

      elsif Message.Label = Seat_Config_Label then
         --  Devmgr pushes Bureau's window-service endpoint.
         Seat_EP := Message.Caps (0);
         Message.Words := (others => 0);
         if IPC_Reply (Reply_H) /= IPC_Ok then
            Debug_Put_Line ("virtio-input seat reply failed");
            Process_Exit;
         end if;
         Debug_Put_Line ("virtio-input seat online");

      else
         Message.Words := (others => 0);
         Message.Words (0) := 3;
         if IPC_Reply (Reply_H) /= IPC_Ok then
            Debug_Put_Line ("virtio-input reply failed");
            Process_Exit;
         end if;
      end if;
   end loop;
end Virtio_Input;
