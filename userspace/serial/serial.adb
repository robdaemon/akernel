with Ada.Streams;
with Akernel_User.MMIO;
with Akernel_User.Syscalls;
with Akernel_User.IPC;
with Akernel_User.Streams;
with Akernel_User.Tables;

--  Console server, spawned by init's device manager as an ordinary
--  driver (`driver ns16550a Drivers/Serial none 0`): class 0 gets
--  the Receive cap on the init-minted console endpoint at handle 1,
--  the UART MMIO cap at handle 2 and the UART IRQ cap at handle 3
--  (the generic driver handle ABI). Clients print through
--  Akernel_User.Streams / Akernel_User.Console (write ops arrive as
--  stream-protocol messages). Writes are line-atomic: bytes
--  accumulate in a per-client buffer (keyed by the console cap
--  badge, which init sets to the manifest program id) and only hit
--  the UART on newline or a full buffer, so concurrent clients'
--  lines never interleave. Partial lines flush lazily (a full
--  buffer) or not at all if a client exits mid-line.
--  UART RX is IRQ-driven through a thread-bound notification:
--  the UART IRQ line signals it (irq_bind_ntfn), the server's
--  IPC_Recv wakes with a synthetic message (Notification_Label),
--  the server drains and acks.
--  Input: the server keeps a bounded input FIFO fed by UART RX
--  (still echoed for UX) and by source drivers through the
--  stream protocol's Op_Input (virtio-input keyboard chars).
--  Client Op_Read drains the FIFO (Count = 0 when empty).
--  Sinks: Op_Attach_Sink (any badge — a client attaches its own
--  endpoint) registers an endpoint Send cap (virtio-gpu text
--  console) that each flushed
--  line is mirrored to via stream Op_Write; a sink whose write
--  fails is dropped so a dead display server can never wedge the
--  console. Serial output always continues (debug/logging role).

procedure Serial is
   use Akernel_User.Syscalls;
   use type U64;
   use type Akernel_User.MMIO.U8;

   --  Grant order follows the devmgr driver handle ABI.
   Console_EP : constant U64 := 1;
   MMIO_Cap   : constant U64 := 2;
   IRQ_Cap    : constant U64 := 3;
   MMIO_VA    : constant Akernel_User.MMIO.U64 := 16#5000_0000#;
   Page_Size  : constant U64 := 4096;

   RBR : constant Akernel_User.MMIO.U64 := MMIO_VA + 0;
   THR : constant Akernel_User.MMIO.U64 := MMIO_VA + 0;
   FCR : constant Akernel_User.MMIO.U64 := MMIO_VA + 2;
   LSR : constant Akernel_User.MMIO.U64 := MMIO_VA + 5;

   LSR_DR   : constant Akernel_User.MMIO.U8 := 16#01#;
   LSR_THRE : constant Akernel_User.MMIO.U8 := 16#20#;
   FCR_FIFO : constant Akernel_User.MMIO.U8 := 16#07#;

   package RPC is new Akernel_User.IPC
     (Akernel_User.Streams.Stream_Request,
      Akernel_User.Streams.Stream_Response);

   Result : U64;
   Status : U64;
   Label  : U64;
   Badge  : U64;
   Reg    : Akernel_User.MMIO.U8;
   Ntfn   : U64;

   Request  : Akernel_User.Streams.Stream_Request;
   Response : Akernel_User.Streams.Stream_Response;
   Caps     : RPC.Cap_Array;
   Reply_H  : U64;

   --  Wait for THR (or the TX FIFO) to drain before the next byte.
   --  Without this a flushed-line burst silently overwrites a byte
   --  the QEMU chardev has not consumed yet (thr_ipending
   --  overwrite) — the "lost console line" flake.  The kernel's
   --  debug writer (Board.UART) shares this UART without a common
   --  lock and polls THRE the same way.
   procedure Wait_THRE is
   begin
     while (Akernel_User.MMIO.Read8 (LSR) and LSR_THRE) = 0 loop
        null;
     end loop;
   end Wait_THRE;

   procedure UART_Put_Char (Ch : Character) is
   begin
     Wait_THRE;
     Akernel_User.MMIO.Write8 (THR, Character'Pos (Ch));
   end UART_Put_Char;

   procedure UART_Put (S : String) is
   begin
      for Ch of S loop
        UART_Put_Char (Ch);
      end loop;
   end UART_Put;

   procedure UART_Put_Line (S : String) is
   begin
      UART_Put (S);
     UART_Put_Char (Character'Val (10));
   end UART_Put_Line;

   --  Input FIFO: UART RX bytes (echoed) and Op_Input bytes from
   --  source drivers converge here; Op_Read drains it. Drop-new
   --  on overflow (typing bursts never block the IRQ path).
   Input_Size : constant := 128;

   Input_Buf   : String (1 .. Input_Size);
   Input_Head  : Natural := 0;  --  next write slot (0-based)
   Input_Count : Natural := 0;

   procedure Input_Put (Ch : Character) is
   begin
      if Input_Count = Input_Size then
         return;  --  full: drop
      end if;
      Input_Buf (Input_Head + 1) := Ch;
      Input_Head := (Input_Head + 1) mod Input_Size;
      Input_Count := Input_Count + 1;
   end Input_Put;

   function Input_Get (Ch : out Character) return Boolean is
      Tail : Natural;
   begin
      if Input_Count = 0 then
         Ch := Character'Val (0);
         return False;
      end if;
      Tail := (Input_Head + Input_Size - Input_Count) mod Input_Size;
      Ch := Input_Buf (Tail + 1);
      Input_Count := Input_Count - 1;
      return True;
   end Input_Get;

   --  Drain input: feed the FIFO and echo back; interrupt clears
   --  once RBR is empty.
   procedure Drain_RX is
   begin
      loop
         Reg := Akernel_User.MMIO.Read8 (LSR);
         exit when (Reg and LSR_DR) = 0;
         Reg := Akernel_User.MMIO.Read8 (RBR);
         Input_Put (Character'Val (Natural (Reg)));
        UART_Put_Char (Character'Val (Natural (Reg)));
      end loop;
   end Drain_RX;

   --  Per-client line buffers (line-atomic writes): a client's
   --  bytes only reach the UART on newline or a full buffer.
   --  m80f: chunk-appended table (Akernel_User.Tables); fresh
   --  chunk slots are zeroed, so appends must stamp the
   --  Badge = U64'Last free marker before use.
   Line_Max    : constant := 160;

   type Client_Line is record
      Badge : U64 := U64'Last;
      Buf   : String (1 .. Line_Max);
      Len   : Natural := 0;
   end record;

   package Line_Tab is new Akernel_User.Tables (Client_Line);
   function Lines (I : Natural) return Line_Tab.Element_Access
     renames Line_Tab.Ref;

   --  Output sinks (Op_Attach_Sink): endpoint Send caps the
   --  console mirrors every flushed line to. m80f: chunk-appended
   --  (0 = free slot, matching the zeroed default); a failing
   --  sink is dropped and its cap deleted.
   package Sink_Tab is new Akernel_User.Tables (U64);
   function Sinks (I : Natural) return Sink_Tab.Element_Access
     renames Sink_Tab.Ref;

   --  Stream-write S to one sink; returns False on any IPC
   --  failure (caller drops the sink). Use Send, not Call: the sink
   --  is best-effort and a nested blocking RPC while serving a
   --  client was deleting the writer's reply cap in some schedules.
   function Sink_Write (Sink : U64; S : String) return Boolean is
      First  : Natural := S'First;
      Chunk  : Natural;
      Req    : Akernel_User.Streams.Stream_Request;
   begin
      while First <= S'Last loop
         Chunk := Natural'Min
           (S'Last - First + 1, Akernel_User.Streams.Max_Chunk);
         Req.Count := U64 (Chunk);
         Req.Data := (others => 0);
         for I in 1 .. Chunk loop
            Req.Data (Ada.Streams.Stream_Element_Offset (I)) :=
              Ada.Streams.Stream_Element (Character'Pos (S (First + I - 1)));
         end loop;
         if RPC.Send (Sink, Akernel_User.Streams.Op_Write, Req,
                      RPC.No_Caps) /= IPC_Ok
         then
            return False;
         end if;
         First := First + Chunk;
      end loop;
      return True;
   end Sink_Write;

   procedure Mirror_To_Sinks (S : String) is
   begin
      for I in 1 .. Sink_Tab.Last loop
         if Sinks (I).all /= 0 then
            if not Sink_Write (Sinks (I).all, S) then
               Result := Cap_Delete (Sinks (I).all);
               Sinks (I).all := 0;
            end if;
         end if;
      end loop;
   end Mirror_To_Sinks;

   procedure Flush_Line (Slot : Positive) is
   begin
      if Lines (Slot).Len > 0 then
         UART_Put (Lines (Slot).Buf (1 .. Lines (Slot).Len));
         Mirror_To_Sinks (Lines (Slot).Buf (1 .. Lines (Slot).Len));
         Lines (Slot).Len := 0;
      end if;
   end Flush_Line;

   procedure Buffer_Write (Badge : U64; Ch : Character) is
      Slot : Natural := 0;
      Free : Natural := 0;
   begin
      for I in 1 .. Line_Tab.Last loop
         if Lines (I).Badge = Badge then
            Slot := I;
            exit;
         elsif Lines (I).Badge = U64'Last and then Free = 0 then
            Free := I;
         end if;
      end loop;

      if Slot = 0 then
         if Free = 0 then
            Free := Line_Tab.Append;   --  0 = arena OOM
            if Free /= 0 then
               Lines (Free).Badge := U64'Last;  --  free marker
            end if;
         end if;
         if Free = 0 then
            --  Table full: bypass buffering rather than drop bytes.
           UART_Put_Char (Ch);
            return;
         end if;
         Slot := Free;
         Lines (Slot).Badge := Badge;
         Lines (Slot).Len := 0;
      end if;

      if Lines (Slot).Len = Line_Max then
         Flush_Line (Slot);
      end if;

      Lines (Slot).Len := Lines (Slot).Len + 1;
      Lines (Slot).Buf (Lines (Slot).Len) := Ch;

      if Ch = Character'Val (10) then
         Flush_Line (Slot);
         --  Release the slot: a badge only needs one while a
         --  partial line pends. With more console clients than
         --  slots (devmgr-spawned drivers print too), pinning the
         --  slot forever pushed steady-state writers onto the
         --  table-full bypass and lines interleaved character-wise.
         Lines (Slot).Badge := U64'Last;
      end if;
   end Buffer_Write;
begin
   Result := Map_MMIO
     (Address_Space => Address_Space_Cap,
      Cap           => MMIO_Cap,
      VA            => Akernel_User.Syscalls.U64 (MMIO_VA),
      Offset        => 0,
      Length        => Page_Size,
      Flags         => 3);

   if Result /= 0 then
      Debug_Put_Line ("serial map mmio failed");
      Process_Exit;
   end if;

   --  Enable the 16550 FIFOs: the 16-byte TX buffer absorbs
   --  flushed-line bursts (Wait_THRE still gates every write).
   Akernel_User.MMIO.Write8 (FCR, FCR_FIFO);

   UART_Put_Line ("console server online");

   --  IRQ-driven RX: a thread-bound notification signaled by the
   --  UART IRQ line; IPC_Recv delivers it as a synthetic message.
   Ntfn := Ntfn_Create;
   if Ntfn = Syscall_Failed
     or else Ntfn_Bind_Thread (Ntfn) /= 0
     or else IRQ_Bind_Ntfn (IRQ_Cap, Ntfn, 1) /= 0
   then
      Debug_Put_Line ("serial ntfn setup failed");
      Process_Exit;
   end if;

   loop
      Status := RPC.Receive
        (Console_EP, Label, Request, Badge, Caps, Reply_H);
      exit when Status /= IPC_Ok;

      if Label = Notification_Label then
         --  UART RX interrupt: input waiting in RBR. No reply cap
         --  rides a synthetic message, so nothing to reply to.
         Drain_RX;
         Result := IRQ_Ack (IRQ_Cap);
      else
         Drain_RX;

         if Label = Akernel_User.Streams.Op_Write then
            for I in 1 .. Ada.Streams.Stream_Element_Offset (Request.Count) loop
               Buffer_Write
                 (Badge, Character'Val (Natural (Request.Data (I))));
            end loop;
            Response := (Count => Request.Count, Data => (others => 0));
         elsif Label = Akernel_User.Streams.Op_Input then
            --  Source-driver input injection (virtio-input
            --  keyboard): into the FIFO, not the display.
            Response.Count := 0;
            Response.Data := (others => 0);
            for I in 1 .. Ada.Streams.Stream_Element_Offset (Request.Count) loop
               exit when Input_Count = Input_Size;
               Input_Put (Character'Val (Natural (Request.Data (I))));
               Response.Count := Response.Count + 1;
            end loop;
         elsif Label = Akernel_User.Streams.Op_Read then
            --  Drain the input FIFO (Count = 0 when empty).
            Response.Count := 0;
            Response.Data := (others => 0);
            declare
               Ch : Character;
            begin
               while Response.Count <
                 Akernel_User.Syscalls.U64 (Request.Count)
                 and then Response.Count <
                   Akernel_User.Syscalls.U64
                     (Akernel_User.Streams.Max_Chunk)
                 and then Input_Get (Ch)
               loop
                  Response.Count := Response.Count + 1;
                  Response.Data
                    (Ada.Streams.Stream_Element_Offset (Response.Count)) :=
                    Ada.Streams.Stream_Element (Character'Pos (Ch));
               end loop;
            end;
         elsif Label = Akernel_User.Streams.Op_Attach_Sink then
            --  Console-sink registration: any client badge may
            --  attach its own endpoint (milestone 31b: the
            --  terminal self-attaches; console Send caps are
            --  handed out broadly anyway — capability discipline
            --  comes later). Cap slot 0 carries the sink endpoint
            --  Send cap. Reply Count: 0 = attached, 1 = rejected.
            if Caps (0) /= 0 then
               Response.Count := 1;
               for I in 1 .. Sink_Tab.Last loop
                  if Sinks (I).all = 0 then
                     Sinks (I).all := Caps (0);
                     Response.Count := 0;
                     exit;
                  end if;
               end loop;
               if Response.Count = 1 then
                  declare
                     Slot : constant Natural := Sink_Tab.Append;
                  begin
                     if Slot /= 0 then
                        Sinks (Slot).all := Caps (0);
                        Response.Count := 0;
                     end if;
                  end;
               end if;
               if Response.Count = 1 then
                  --  No slot (arena OOM): drop the transferred
                  --  cap or leak it.
                  Result := Cap_Delete (Caps (0));
               end if;
            else
               if Caps (0) /= 0 then
                  Result := Cap_Delete (Caps (0));
               end if;
               Response.Count := 1;
            end if;
            Response.Data := (others => 0);
         else
            --  Unknown ops: no data.
            Response := (Count => 0, Data => (others => 0));
         end if;

         Status := RPC.Reply (Reply_H, Label, Response);
         --  If the caller exited before the reply, drop the request
         --  and keep serving other clients.  A dead client must not
         --  take the console server down.
         null;
      end if;
   end loop;

   Process_Exit;
end Serial;
