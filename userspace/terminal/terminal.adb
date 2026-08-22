with Interfaces;
with System;
with System.Storage_Elements;
with Ada.Streams;
with Akernel_User.Syscalls;
with Akernel_User.IPC;
with Akernel_User.Streams;
with Akernel_User.Files;
with Akernel_User.Window;
with Trinket;
with Trinket.Menus;
with Trinket.Paint;
with Trinket.Fonts;
with Trinket.Widgets;
with Terminal_Buffer;
with Terminal_Scroll;

--  Terminal: a console device (the CON: analog) living in a
--  Bureau window. Spawned from the Sys filesystem by the device
--  manager right after Bureau under the UNIFORM program ABI
--  (milestone 31b): 1 = console endpoint (Send, badged), 2 =
--  file server endpoint (Send), 3 = Bureau window-service
--  endpoint (Send). Everything else is runtime-created: the
--  stream sink endpoint is made with EP_Create and SELF-ATTACHED
--  to the console server (Op_Attach_Sink now accepts any badge),
--  so the boot mirror lands in this pane without devmgr wiring.
--
--  Milestone 58: the terminal keeps its stream-sink service loop
--  but stores text in Terminal_Buffer (circular scrollback) and
--  renders through Trinket into the Bureau surface. A scrollbar
--  at the right edge (Terminal_Scroll) controls the view offset
--  into the scrollback; focused navigation keys and pointer
--  events adjust the view, while text output and echo still go to
--  the bottom line and auto-scroll only when the view is already
--  at the bottom.

procedure Terminal is
   use Akernel_User.Syscalls;
   use type U64;
   use type Interfaces.Unsigned_8;

   Console_EP : constant U64 := 1;
   --  Uniform program ABI (milestone 31b): 2 = file server Send
   --  (staging authority for the shell spawn), 3 = Bureau window
   --  service Send.
   FS_EP      : constant U64 := 2;
   Win_EP     : constant U64 := 3;
   Elevated_Svc : constant U64 := 4;  --  elevation svc (from devmgr)
   --  Runtime-created stream sink endpoint (full rights: mints
   --  the console-server sink attach AND the shell's console
   --  cap). Filled in before the service loop starts.
   Sink_EP    : U64 := 0;

   Buf_VA : constant U64 := 16#6000_0000#;
   --  v3 input queue (one page, shared RW with Bureau) and the
   --  thread-bound notification that signals new events.
   Queue_VA : constant U64 := 16#5080_0000#;
   --  Scratch page for the serialized screen-bar menu tree
   --  (transient: Bureau copies it out at Op_Set_Menus).
   Menu_VA : constant U64 := 16#5080_1000#;
   Queue_Cap : U64 := 0;
   Ntfn_Cap  : U64 := 0;

   type Word_Array is array (U64 range 0 .. 511) of U64
     with Volatile_Components;
   Queue : Word_Array
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (Queue_VA));

   Max_W : constant := 1024;
   Max_H : constant := 768;
   Max_Objects : constant := (Max_W * Max_H * 4) / 4096 / 64;

   Surf_Id : U64;
   Pages   : U64;
   Surf_W  : U64;
   Surf_H  : U64;

   Obj_Caps : array (0 .. Max_Objects - 1) of U64 := (others => 0);

   subtype Pixel is Interfaces.Unsigned_32;
   type Pixel_Array is
     array (U64 range 0 .. Max_W * Max_H - 1) of Pixel
     with Volatile_Components;
   Buf : Pixel_Array
     with Address => System.Storage_Elements.To_Address
       (System.Storage_Elements.Integer_Address (Buf_VA));

   --  Drawing target that wraps the Bureau surface buffer.
   Canvas : Trinket.Canvas;

   --  Input FIFO: focused keys (Op_Input bytes) queue here;
   --  Op_Read drains it. Drop-new on overflow (typing bursts
   --  never block the seat). Sized for history recall: a
   --  recall injects BS x old-length + the recalled entry
   --  (up to 2 x 120) plus type-ahead slack.
   Input_Size  : constant := 512;
   Input_Buf   : String (1 .. Input_Size);
   Input_Head  : Natural := 0;  --  next write slot (0-based)
   Input_Count : Natural := 0;

   --  Milestone 60: Amiga-style command history (the CON:
   --  lineage — history is line discipline, so it lives here,
   --  never in the shell). Edit_Buf mirrors the input half of
   --  the current scrollback line (the rest is prompt/output);
   --  at Return the line joins the ring. Cursor-Up/Down recall
   --  older/newer entries by INJECTING bytes into the Op_Read
   --  FIFO (BS x current length, then the entry text) so the
   --  shell's own line buffer stays in sync with the display —
   --  the shell sees only an edited line and needs no history
   --  knowledge. Down past the newest entry restores the
   --  stashed in-progress line.
   Edit_Cap : constant := 120;  --  = the shell's Max_Line
   Edit_Buf : String (1 .. Edit_Cap);
   Edit_Len : Natural := 0;

   Max_Hist : constant := 32;
   type Hist_Entry is record
      Text : String (1 .. Edit_Cap);
      Len  : Natural := 0;
   end record;
   Hist      : array (0 .. Max_Hist - 1) of Hist_Entry;
   Hist_Head : Natural := 0;  --  next write slot (ring)
   Hist_Cnt  : Natural := 0;
   Stash     : Hist_Entry;    --  in-progress line during recall
   Recalling : Boolean := False;
   Recall_Ix : Natural := 0;  --  0 = oldest .. Hist_Cnt-1 = newest

   --  Last button state for synthesizing Press/Release from
   --  v3 pointer events.
   Prev_Buttons : U64 := 0;

   Result : U64;

   procedure Fail (S : String) is
   begin
      Debug_Put_Line ("FAIL terminal " & S);
      Process_Exit;
   end Fail;

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

   ------------------------------------------------------------------
   --  Milestone 60: command history

   function Hist_Slot (I : Natural) return Natural is
     ((Hist_Head + Max_Hist - Hist_Cnt + I) mod Max_Hist);
   --  Ring slot of entry I (0 = oldest, Hist_Cnt-1 = newest).

   procedure Hist_Push is
   begin
      if Edit_Len = 0 then
         return;
      end if;
      Hist (Hist_Head).Text (1 .. Edit_Len) := Edit_Buf (1 .. Edit_Len);
      Hist (Hist_Head).Len := Edit_Len;
      Hist_Head := (Hist_Head + 1) mod Max_Hist;
      if Hist_Cnt < Max_Hist then
         Hist_Cnt := Hist_Cnt + 1;
      end if;
   end Hist_Push;

   --  Replace the current input line with S: erase what the
   --  shell holds (BS per character, mirrored into the
   --  scrollback echo) and inject the replacement as if typed.
   procedure Recall_Replace (S : String) is
   begin
      for I in 1 .. Edit_Len loop
         Input_Put (Character'Val (8));
         Terminal_Buffer.Put_Char (Character'Val (8));
      end loop;
      Edit_Len := S'Length;
      Edit_Buf (1 .. Edit_Len) := S;
      for C of S loop
         Input_Put (C);
         Terminal_Buffer.Put_Char (C);
      end loop;
   end Recall_Replace;

   procedure Recall_Older is
   begin
      if not Recalling then
         if Hist_Cnt = 0 then
            return;
         end if;
         Stash.Text (1 .. Edit_Len) := Edit_Buf (1 .. Edit_Len);
         Stash.Len := Edit_Len;
         Recalling := True;
         Recall_Ix := Hist_Cnt - 1;
      elsif Recall_Ix = 0 then
         return;  --  oldest entry already on the line
      else
         Recall_Ix := Recall_Ix - 1;
      end if;
      declare
         E : Hist_Entry renames Hist (Hist_Slot (Recall_Ix));
      begin
         Recall_Replace (E.Text (1 .. E.Len));
      end;
   end Recall_Older;

   procedure Recall_Newer is
   begin
      if not Recalling then
         return;
      end if;
      if Recall_Ix < Hist_Cnt - 1 then
         Recall_Ix := Recall_Ix + 1;
         declare
            E : Hist_Entry renames Hist (Hist_Slot (Recall_Ix));
         begin
            Recall_Replace (E.Text (1 .. E.Len));
         end;
      else
         --  Past the newest: back to the line being typed.
         Recalling := False;
         Recall_Replace (Stash.Text (1 .. Stash.Len));
      end if;
   end Recall_Newer;

   --  One input character through the line discipline: queue it
   --  for Op_Read, echo it into the scrollback, and track the
   --  input extent in Edit_Buf. Backspace at an empty input is
   --  swallowed (it used to eat the prompt's last character).
   --  Other control bytes are dropped: the shell ignores them,
   --  so queueing/echoing only desynced the display.
   procedure Input_Char (Ch : Character) is
      Code : constant Natural := Character'Pos (Ch);
   begin
      if Code = 10 or else Code = 13 then
         Hist_Push;
         Edit_Len := 0;
         Recalling := False;
         Input_Put (Ch);
         Terminal_Buffer.Put_Char (Ch);
      elsif Code = 8 or else Code = 127 then
         if Edit_Len > 0 then
            Edit_Len := Edit_Len - 1;
            Input_Put (Ch);
            Terminal_Buffer.Put_Char (Ch);
         end if;
      elsif Code >= 32 and then Code < 127 then
         if Edit_Len < Edit_Cap then
            Edit_Len := Edit_Len + 1;
            Edit_Buf (Edit_Len) := Ch;
            Input_Put (Ch);
            Terminal_Buffer.Put_Char (Ch);
         end if;
      end if;
   end Input_Char;

   --  Repaint the visible window into the surface buffer and mark
   --  the whole pane dirty (Bureau flushes after the reply).
   procedure Render is
      Text_W : constant U64 := Surf_W - Terminal_Scroll.Scrollbar_W;
      Rows   : constant Natural := Terminal_Buffer.Rows;
      Cols   : constant Natural := Terminal_Buffer.Cols;
      LH     : constant U64 := Trinket.Fonts.Line_Height;
      Line   : String (1 .. Cols);
      Len    : Natural;
   begin
      Terminal_Scroll.Update_Range;
      Trinket.Paint.Fill_Rect
        (Canvas, 0, 0, Surf_W, Surf_H, Trinket.Pane);
      for R in 0 .. Rows - 1 loop
         declare
            Line_I : constant Natural := Terminal_Buffer.View_Top + R;
            Y      : constant U64 := U64 (R) * LH;
         begin
            exit when Line_I >= Terminal_Buffer.Line_Count;
            Terminal_Buffer.Get_Line (Line_I, Line, Len);
            if Len > 0 then
               Trinket.Fonts.Draw_Text
                 (Canvas, 0, Y, Line (1 .. Len), Trinket.Text_Dark);
            end if;
         end;
      end loop;
      Terminal_Scroll.Draw (Canvas);

      --  Solid block cursor at the current input position. Drawn
      --  after the text so it overwrites the cell; full-surface
      --  redraws erase the previous cursor position.
      declare
         Cur_Line : constant Natural := Terminal_Buffer.Current_Line;
         Cur_Col  : constant Natural := Terminal_Buffer.Current_Col;
         Top      : constant Natural := Terminal_Buffer.View_Top;
         Rows     : constant Natural := Terminal_Buffer.Rows;
         Char_W   : constant U64 := 8;
      begin
         if Cur_Line >= Top and then Cur_Line < Top + Rows then
            declare
               R : constant U64 := U64 (Cur_Line - Top);
               X : constant U64 := U64 (Cur_Col) * Char_W;
               Y : constant U64 := R * LH;
            begin
               if X + Char_W <= Surf_W - Terminal_Scroll.Scrollbar_W then
                  Trinket.Paint.Fill_Rect
                    (Canvas, X, Y, X + Char_W, Y + LH, Trinket.Sel_Blue);
               end if;
            end;
         end if;
      end;

      Terminal_Scroll.Clear_Dirty;
      Terminal_Buffer.Clear_Dirty;
   end Render;

   procedure Flush_Surface is
   begin
      Result := Akernel_User.Window.Surface_Update
        (Win_EP, Surf_Id, 0, 0, Surf_W, Surf_H);
      if Result /= Akernel_User.Window.Status_Ok then
         Debug_Put_Line ("terminal update failed");
      end if;
   end Flush_Surface;

   procedure Scroll_Page (Up : Boolean) is
      Top  : constant Natural := Terminal_Buffer.View_Top;
      Rows : constant Natural := Terminal_Buffer.Rows;
      Max  : constant Natural := Terminal_Buffer.Max_Top;
   begin
      if Up then
         if Top >= Rows then
            Terminal_Buffer.Set_Top (Top - Rows);
         else
            Terminal_Buffer.Set_Top (0);
         end if;
      else
         if Top + Rows <= Max then
            Terminal_Buffer.Set_Top (Top + Rows);
         else
            Terminal_Buffer.Set_Top (Max);
         end if;
      end if;
   end Scroll_Page;

   --  Milestone 60: cursor Up/Down are command history (Amiga
   --  CON: semantics); scrollback scrolling moved to Page Up/
   --  Page Down/Home/End (and the scrollbar pointer, unchanged).
   procedure Handle_Nav (Code : U64) is
   begin
      if Code = Trinket.Key_Up then
         Recall_Older;
      elsif Code = Trinket.Key_Down then
         Recall_Newer;
      elsif Code = Trinket.Key_Pageup then
         Scroll_Page (Up => True);
      elsif Code = Trinket.Key_Pagedown then
         Scroll_Page (Up => False);
      elsif Code = Trinket.Key_Home then
         Terminal_Buffer.Set_Top (0);
      elsif Code = Trinket.Key_End then
         Terminal_Buffer.Set_Top (Terminal_Buffer.Max_Top);
      end if;
   end Handle_Nav;

   --  Drain v3 input-queue events. ASCII keys feed the local input
   --  FIFO and echo into the scrollback; navigation keys scroll
   --  the view; pointer events operate the scrollbar.
   procedure Drain_Input_Queue is
      Head : constant U64 := Queue (Akernel_User.Window.Input_Queue_Head);
      Tail : U64 := Queue (Akernel_User.Window.Input_Queue_Tail);
      Slot : U64;
   begin
      while Tail < Head loop
         Slot := Akernel_User.Window.Input_Queue_First
           + (Tail mod Akernel_User.Window.Input_Queue_Events) * 2;
         if Queue (Slot) = Akernel_User.Window.Input_Event_Key then
            declare
               Code : constant Natural :=
                 Natural (Queue (Slot + 1) and 16#FF#);
            begin
               --  Milestone 57: navigation keys arrive as codes
               --  >= 16#80# (Trinket.Key_*). Milestone 60: ASCII
               --  goes through the line discipline (history
               --  tracking); nav keys recall history (Up/Down)
               --  or scroll the view (Page/Home/End).
               if Code < 16#80# then
                  Input_Char (Character'Val (Code));
               else
                  Handle_Nav (U64 (Code));
               end if;
            end;
         elsif Queue (Slot) = Akernel_User.Window.Input_Event_Pointer
         then
            declare
               Val : constant U64 := Queue (Slot + 1);
               X   : constant U64 :=
                 Akernel_User.Window.Pointer_X (Val);
               Y   : constant U64 :=
                 Akernel_User.Window.Pointer_Y (Val);
               Btn : constant U64 :=
                 Akernel_User.Window.Pointer_Buttons (Val);
               K   : Trinket.Widgets.Pointer_Kind;
               Consumed : Boolean;
               pragma Unreferenced (Consumed);
            begin
               if (Btn and 1) /= 0
                 and then (Prev_Buttons and 1) = 0
               then
                  K := Trinket.Widgets.Press;
               elsif (Btn and 1) = 0
                 and then (Prev_Buttons and 1) /= 0
               then
                  K := Trinket.Widgets.Release;
               else
                  K := Trinket.Widgets.Move;
               end if;
               Prev_Buttons := Btn;
               Consumed := Terminal_Scroll.Handle_Pointer (K, X, Y);
            end;
         elsif Queue (Slot) = Akernel_User.Window.Input_Event_Close
         then
            --  Close gadget (CLOSEWINDOW analog): destroy the
            --  surface and leave; the shell's console channel
            --  dies with us and the shell exits on its next
            --  read.
            Result := Akernel_User.Window.Surface_Destroy
              (Win_EP, Surf_Id);
            Process_Exit;
         elsif Queue (Slot) = Akernel_User.Window.Input_Event_Menu
         then
            --  Screen-bar menu pick (kind 4; value = item Id).
            --  Terminal > Quit takes the close-gadget path.
            if (Queue (Slot + 1) and 16#FFFF_FFFF#) = 1 then
               Result := Akernel_User.Window.Surface_Destroy
                 (Win_EP, Surf_Id);
               Process_Exit;
            end if;
         end if;
         Tail := Tail + 1;
      end loop;
      Queue (Akernel_User.Window.Input_Queue_Tail) := Tail;
   end Drain_Input_Queue;

   ------------------------------------------------------------------

   --  Milestone 31: stage System/Shell from the Sys volume into a
   --  memory object (memstage pattern) and spawn it on this
   --  terminal's stream endpoint. Launching a terminal starts the
   --  shell; the shell opens no window itself.
   Shell_Stage_VA : constant U64 := 16#5400_0000#;

   procedure Spawn_Shell is
      use System.Storage_Elements;
      Size     : U64 := 0;
      Pages    : U64;
      Mem_Cap  : U64;
      Off      : U64 := 0;
      Chunk    : U64;
      Count    : U64 := 0;
      St       : U64;
      Proc_Cap : U64 := 0;
      Args_Cap : U64 := 0;
   begin
      Akernel_User.Files.Bind (FS_EP);
      St := Akernel_User.Files.Stat ("BD0:System/Shell", Size);
      if St /= Akernel_User.Files.Status_Ok or else Size = 0 then
         Debug_Put_Line ("terminal shell stat failed");
         return;
      end if;
      Pages := (Size + 4095) / 4096;
      Mem_Cap := Mem_Alloc (Pages);
      if Mem_Cap = Syscall_Failed then
         Debug_Put_Line ("terminal shell alloc failed");
         return;
      end if;
      if Mem_Map (Address_Space_Cap, Mem_Cap, Shell_Stage_VA, 0,
                  Pages * 4096, 3) /= 0
      then
         Debug_Put_Line ("terminal shell map failed");
         Result := Cap_Delete (Mem_Cap);
         return;
      end if;
      St := Akernel_User.Files.Open ("BD0:System/Shell", Size);
      while St = Akernel_User.Files.Status_Ok and then Off < Size loop
         Chunk := U64'Min (Size - Off, 32768);
         St := Akernel_User.Files.Read
           ("BD0:System/Shell", Off,
            System'To_Address (Integer_Address (Shell_Stage_VA + Off)),
            Chunk, Count);
         exit when St /= Akernel_User.Files.Status_Ok
           or else Count /= Chunk;
         Off := Off + Chunk;
      end loop;
      Result := Mem_Unmap (Address_Space_Cap, Shell_Stage_VA,
                           Pages * 4096);
      if Off < Size then
         Debug_Put_Line ("terminal shell read failed");
         Result := Cap_Delete (Mem_Cap);
         return;
      end if;
      --  Shell handles (uniform command ABI): 1 = this sink
      --  endpoint (Send, badge 1) — its console channel — 2 =
      --  the fs endpoint (Send), 3 = the Bureau window service
      --  (Send; a shell child is GUI only once it calls
      --  Surface_Create), 4 = an empty args page (the uniform
      --  layout — commands take their argument string there),
      --  5 = the elevation service (milestone 45).
      Args_Cap := Mem_Alloc (1);
      if Args_Cap = Syscall_Failed then
         Debug_Put_Line ("terminal shell args alloc failed");
         Result := Cap_Delete (Mem_Cap);
         return;
      end if;
      Set_Grant (0, Sink_EP, Right_Send, 1);
      Set_Grant (1, FS_EP, Right_Send, 0);
      Set_Grant (2, Win_EP, Right_Send, 0);
      Set_Grant (3, Args_Cap, Right_Map + Right_Read, 0);
      Set_Grant (4, Elevated_Svc, Right_Send, 0);
      if Spawn (Mem_Cap, 5, Proc_Cap) /= Spawn_Ok
        or else Proc_Cap = 0
      then
         Debug_Put_Line ("terminal shell spawn failed");
      else
         Debug_Put_Line ("terminal spawned shell");
      end if;
      Result := Cap_Delete (Args_Cap);
      Result := Cap_Delete (Mem_Cap);
   end Spawn_Shell;

   ------------------------------------------------------------------

   --  Milestone 61 followup: screen-bar menus on the RAW window
   --  protocol (this client predates Trinket.Window). One
   --  transient page carries the tree serialized by
   --  Trinket.Menus.Serialize; Bureau copies it out at
   --  Op_Set_Menus, so the page is unmapped right after.
   procedure Declare_Menus is
      use System.Storage_Elements;
      Cap    : U64;
      Minted : U64;
   begin
      Cap := Mem_Alloc (1);
      if Cap = Syscall_Failed then
         return;
      end if;
      if Mem_Map (Address_Space_Cap, Cap, Menu_VA, 0, 4096, 3) /= 0
      then
         Result := Cap_Delete (Cap);
         return;
      end if;
      Trinket.Menus.Serialize
        ((1 => Trinket.Menus.M
            ("Terminal", (1 => Trinket.Menus.It (1, "Quit")))),
         To_Address (Integer_Address (Menu_VA)));
      Minted := Cap_Mint
        (Cap, Right_Map + Right_Read + Right_Transfer, 0);
      if Minted /= Syscall_Failed then
         Result := Akernel_User.Window.Surface_Set_Menus
           (Win_EP, Surf_Id, Minted);
         Result := Cap_Delete (Minted);
      end if;
      Result := Mem_Unmap (Address_Space_Cap, Menu_VA, 4096);
      Result := Cap_Delete (Cap);
   end Declare_Menus;

   ------------------------------------------------------------------

   package RPC is new Akernel_User.IPC
     (Akernel_User.Streams.Stream_Request,
      Akernel_User.Streams.Stream_Response);
   package Win renames Akernel_User.Window;

   Status   : U64;
   Label    : U64;
   Badge    : U64;
   Request  : Akernel_User.Streams.Stream_Request;
   Response : Akernel_User.Streams.Stream_Response;
   Caps     : RPC.Cap_Array;
   Reply_H  : U64;

   Pages_Left : U64;
   This       : U64;
   Count      : Natural;
   Minted     : U64;

begin
   --  1. v3 input channel: one-page event queue + thread-bound
   --  notification, pushed to Bureau at Surface_Create.
   Queue_Cap := Mem_Alloc (1);
   if Queue_Cap = Syscall_Failed then
      Fail ("queue alloc failed");
   end if;
   if Mem_Map (Address_Space_Cap, Queue_Cap, Queue_VA, 0,
               4096, 3) /= 0
   then
      Fail ("queue map failed");
   end if;
   Queue (Akernel_User.Window.Input_Queue_Head) := 0;
   Queue (Akernel_User.Window.Input_Queue_Tail) := 0;
   Ntfn_Cap := Ntfn_Create;
   if Ntfn_Cap = Syscall_Failed
     or else Ntfn_Bind_Thread (Ntfn_Cap) /= 0
   then
      Fail ("input ntfn setup failed");
   end if;

   --  2. Surface: request the terminal pane (87x29 cells); hand
   --  over the input queue + notification (v3).
   declare
      Q_Mint : constant U64 := Cap_Mint
        (Queue_Cap, Right_Map + Right_Read + Right_Write +
         Right_Transfer, 0);
      N_Mint : constant U64 := Cap_Mint
        (Ntfn_Cap, Right_Write + Right_Transfer, 0);
   begin
      if Q_Mint = Syscall_Failed or else N_Mint = Syscall_Failed then
         Fail ("input mint failed");
      end if;
      if Win.Surface_Create
        (Win_EP, 87 * 8, 29 * 16, Q_Mint, N_Mint, Surf_Id, Pages,
         Surf_W, Surf_H) /=
          Win.Status_Ok
      then
         Fail ("surface create failed");
      end if;
      Result := Cap_Delete (Q_Mint);
      Result := Cap_Delete (N_Mint);
   end;
   if Win.Surface_Set_Title
     (Win_EP, Surf_Id, "System/Terminal") /= Win.Status_Ok
   then
      Debug_Put_Line ("terminal title failed");
   end if;
   Declare_Menus;

   --  2. Surface buffer chunks, pushed to Bureau (4 caps/call).
   Pages_Left := Pages;
   Count := 0;
   while Pages_Left > 0 loop
      This := U64'Min (Pages_Left, 64);
      Obj_Caps (Count) := Mem_Alloc (This);
      if Obj_Caps (Count) = Syscall_Failed then
         Fail ("surface alloc failed");
      end if;
      Result := Mem_Map
        (Address_Space => Address_Space_Cap,
         Cap           => Obj_Caps (Count),
         VA            => Buf_VA + U64 (Count) * 64 * 4096,
         Offset        => 0,
         Length        => This * 4096,
         Flags         => 3);
      if Result /= 0 then
         Fail ("surface map failed");
      end if;
      Pages_Left := Pages_Left - This;
      Count := Count + 1;
   end loop;

   declare
      Objects : constant U64 := (Pages + 63) / 64;
      Base    : U64 := 0;
      Send    : array (0 .. 3) of U64;
      St      : U64;
   begin
      while Base < Objects loop
         Send := (others => 0);
         for I in 0 .. 3 loop
            exit when Base + U64 (I) >= Objects;
            Minted := Cap_Mint
              (Obj_Caps (Natural (Base + U64 (I))),
               Right_Map + Right_Read + Right_Transfer, 0);
            if Minted = Syscall_Failed then
               Fail ("surface mint failed");
            end if;
            Send (I) := Minted;
         end loop;
         St := Win.Surface_Set_Buffer
           (Win_EP, Surf_Id, Base, Send (0), Send (1), Send (2),
            Send (3));
         for I in 0 .. 3 loop
            if Send (I) /= 0 then
               Result := Cap_Delete (Send (I));
            end if;
         end loop;
         if St /= Win.Status_Ok then
            Fail ("surface set buffer rejected");
         end if;
         Base := Base + 4;
      end loop;
   end;

   if Win.Surface_Commit_Buffer (Win_EP, Surf_Id) /= Win.Status_Ok then
      Fail ("surface commit failed");
   end if;
   Debug_Put_Line ("PASS terminal surface ok");

   --  3. Wire the surface buffer to Trinket and initialize the
   --  scrollback/scroller. Bind the file server first because
   --  Trinket.Fonts loads Sys:Fonts/font8x8.bdf from disk.
   Akernel_User.Files.Bind (FS_EP);
   Trinket.Fonts.Init;

   declare
      Text_W : constant U64 := Surf_W - Terminal_Scroll.Scrollbar_W;
   begin
      Terminal_Buffer.Init
        (Natural (Text_W / 8),
         Natural (Surf_H / Trinket.Fonts.Line_Height));
      Terminal_Scroll.Init (Natural (Surf_W), Natural (Surf_H));
   end;

   Canvas :=
     (Base => System.Storage_Elements.To_Address
                (System.Storage_Elements.Integer_Address (Buf_VA)),
      W    => Surf_W,
      H    => Surf_H,
      CX0  => 0,
      CY0  => 0,
      CX1  => Surf_W,
      CY1  => Surf_H);

   Render;
   Flush_Surface;
   Debug_Put_Line ("terminal online");

   --  4. Console device wiring: create the stream sink endpoint
   --  and self-attach it at the console server (any badge may
   --  attach since 31b — the terminal owns this endpoint and
   --  mints the Send cap itself).
   Sink_EP := EP_Create;
   if Sink_EP = Syscall_Failed then
      Fail ("sink ep create failed");
   end if;
   declare
      Sink_Mint : constant U64 := Cap_Mint
        (Sink_EP, Right_Send + Right_Transfer, 0);
   begin
      if Sink_Mint = Syscall_Failed then
         Fail ("sink mint failed");
      end if;
      Message.Label := Akernel_User.Streams.Op_Attach_Sink;
      Message.Words := (others => 0);
      Message.Caps := (others => 0);
      Message.Caps (0) := Sink_Mint;
      --  Reply Count (first word): 0 = attached, 1 = rejected.
      if IPC_Call (Console_EP) /= IPC_Ok
        or else Message.Words (0) /= 0
      then
         Debug_Put_Line ("terminal sink attach failed");
      end if;
      Result := Cap_Delete (Sink_Mint);
   end;

   --  Launching a terminal starts the shell (milestone 31). Its
   --  first console write rendezvous-waits until the service loop
   --  below receives.
   Spawn_Shell;

   --  5. Stream sink service: Op_Write renders text; Op_Input
   --  queues focused keys + echoes them into the scrollback;
   --  Op_Read drains the input FIFO. Damaged bands flush at the
   --  TOP of the loop, AFTER the reply: an Op_Input is Bureau
   --  calling us, and calling Bureau back (Surface_Update) before
   --  replying deadlocks the rendezvous pair (docs/IPC.md: never
   --  call your caller while serving it).
   loop
      if Terminal_Buffer.Is_Dirty or Terminal_Scroll.Is_Dirty then
         Render;
         Flush_Surface;
      end if;
      Status := RPC.Receive
        (Sink_EP, Label, Request, Badge, Caps, Reply_H);
      if Status /= IPC_Ok then
         Debug_Put_Line ("terminal recv failed");
         Process_Exit;
      end if;

      if Label = Notification_Label then
         --  v3 input signal (synthetic message, NO reply cap):
         --  Bureau enqueued events; drain at our own pace.
         Drain_Input_Queue;

      elsif Label = Akernel_User.Streams.Op_Write then
         for I in 1 .. Ada.Streams.Stream_Element_Offset
           (Request.Count)
         loop
            Terminal_Buffer.Put_Char
              (Character'Val (Natural (Request.Data (I))));
         end loop;
         Response := (Count => Request.Count, Data => (others => 0));
         if Reply_H /= 0
           and then RPC.Reply (Reply_H, Label, Response) /= IPC_Ok
         then
            Debug_Put_Line ("terminal reply failed");
            Process_Exit;
         end if;
      elsif Label = Akernel_User.Streams.Op_Input then
         --  Seat input (focused keys from Bureau): line
         --  discipline lives in the console device — queue for
         --  Op_Read, echo into the scrollback, track the input
         --  line for history (milestone 60). Buffer only: the
         --  band flush happens at the top of the loop, after
         --  the reply (see the loop comment).
         for I in 1 .. Ada.Streams.Stream_Element_Offset
           (Request.Count)
         loop
            Input_Char (Character'Val (Natural (Request.Data (I))));
         end loop;
         Response := (Count => Request.Count, Data => (others => 0));
         if Reply_H /= 0
           and then RPC.Reply (Reply_H, Label, Response) /= IPC_Ok
         then
            Debug_Put_Line ("terminal reply failed");
            Process_Exit;
         end if;
      elsif Label = Akernel_User.Streams.Op_Read then
         --  Drain the input FIFO (Count = 0 when empty).
         declare
            Ch : Character;
         begin
            Response.Count := 0;
            Response.Data := (others => 0);
            while Response.Count <
              Akernel_User.Syscalls.U64 (Request.Count)
              and then Response.Count <
                Akernel_User.Syscalls.U64
                  (Akernel_User.Streams.Max_Chunk)
              and then Input_Get (Ch)
            loop
               Response.Count := Response.Count + 1;
               Response.Data
                 (Ada.Streams.Stream_Element_Offset
                    (Response.Count)) :=
                 Ada.Streams.Stream_Element (Character'Pos (Ch));
            end loop;
         end;
         if Reply_H /= 0 then
            declare
               Ignore : constant U64 :=
                 RPC.Reply (Reply_H, Label, Response);
            begin
               null;
            end;
         end if;
      else
         --  Unknown: no data.
         Response := (Count => 0, Data => (others => 0));
         if Reply_H /= 0 then
            declare
               Ignore : constant U64 :=
                 RPC.Reply (Reply_H, Label, Response);
            begin
               null;
            end;
         end if;
      end if;
   end loop;
end Terminal;
