with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Window;
with Trinket.Paint;
with Trinket.Fonts;
with Trinket.Menus;

package body Trinket.Window is
   use Akernel_User.Syscalls;
   use type Trinket.U64;
   use type Widgets.Any_Widget;
   package Win renames Akernel_User.Window;
   package SSE renames System.Storage_Elements;

   --  Mapping VAs (fixed literals, never derived — the 37b
   --  followup burn). Clear of text 0x4600_0000, args
   --  0x4800_0000, the newlib sbrk arena 0x5200_0000 (2 MiB),
   --  and IPC at 0x6FFF_0000 / main stack at 0x7FF0_0000+.
   Queue_VA : constant U64 := 16#5F00_0000#;
   Surf_VA  : constant U64 := 16#5F80_0000#;  --  8 MiB window
   Menu_VA  : constant U64 := 16#5F10_0000#;  --  m61 menu page
   AppQ_VA  : constant U64 := 16#5F20_0000#;  --  m68 app port page

    Chunk_Pages : constant U64 := 64;  --  per Mem_Alloc chunk
    Max_Chunks  : constant U64 := 16;

    type Word_Array is array (U64 range 0 .. 511) of U64
      with Volatile_Components;

    --  Alloc/map/mint/push the surface chunk caps (<= 64 pages
    --  each) and commit. Used by Open and the v5 resize handler;
    --  on entry Bureau must hold NO buffer for W.Id (fresh create
    --  or post-resize teardown).
    function Push_Surface (W : in out Window; Pages : U64) return Boolean is
       Chunks : constant U64 :=
         (Pages + Chunk_Pages - 1) / Chunk_Pages;
       Minted : U64;
       Left   : U64 := Pages;
       This   : U64;
       Result : U64;
    begin
       if Pages = 0 or else Pages > Chunk_Pages * Max_Chunks then
          return False;
       end if;
       for I in 0 .. Chunks - 1 loop
          This := U64'Min (Chunk_Pages, Left);
          Left := Left - This;
          W.Chunk_Caps (Natural (I)) := Mem_Alloc (This);
          if W.Chunk_Caps (Natural (I)) = Syscall_Failed then
             return False;
          end if;
          Result := Mem_Map
            (Address_Space => Address_Space_Cap,
             Cap           => W.Chunk_Caps (Natural (I)),
             VA            => Surf_VA + I * Chunk_Pages * 4096,
             Offset        => 0,
             Length        => This * 4096,
             Flags         => 3);
          if Result /= 0 then
             return False;
          end if;
          Minted := Cap_Mint
            (W.Chunk_Caps (Natural (I)), Right_Map + Right_Read +
             Right_Transfer, 0);
          if Minted = Syscall_Failed then
             return False;
          end if;
          Result := Win.Surface_Set_Buffer
            (W.EP, W.Id, I, Minted);
          Result := Cap_Delete (Minted);
          if Result /= Win.Status_Ok then
             return False;
          end if;
       end loop;
       W.N_Chunks   := Natural (Chunks);
       W.Surf_Pages := Pages;
       return Win.Surface_Commit_Buffer (W.EP, W.Id) = Win.Status_Ok;
    end Push_Surface;

    --  v5 zoom ack: Bureau tore down its side of the buffer in
    --  Op_Surface_Resize; drop ours, push a fresh buffer at the
    --  granted size, re-layout the tree and repaint everything
    --  (dirty flags don't track geometry moves).
    procedure Handle_Resize (W : in out Window; New_W, New_H : U64) is
       Pages  : U64;
       GW     : U64;
       GH     : U64;
       Result : U64;
    begin
       if Win.Surface_Resize
         (W.EP, W.Id, New_W, New_H, Pages, GW, GH) /= Win.Status_Ok
       then
          return;
       end if;
       for I in 0 .. W.N_Chunks - 1 loop
          Result := Mem_Unmap
            (Address_Space_Cap,
             Surf_VA + U64 (I) * Chunk_Pages * 4096,
             U64'Min (Chunk_Pages, W.Surf_Pages - U64 (I) * Chunk_Pages)
               * 4096);
          Result := Cap_Delete (W.Chunk_Caps (I));
          W.Chunk_Caps (I) := 0;
       end loop;
       W.N_Chunks   := 0;
       W.Surf_Pages := 0;
       if not Push_Surface (W, Pages) then
          Debug_Put_Line ("trinket: resize buffer failed");
          return;
       end if;
       W.Cnv.W := GW;
       W.Cnv.H := GH;
       Reset_Clip (W.Cnv);
       W.Root.W := GW;
       W.Root.H := GH;
       W.Root.Layout;
       Trinket.Paint.Fill_Rect (W.Cnv, 0, 0, GW, GH, Win_Face);
       W.Root.Draw (W.Cnv);
       W.Root.Clear_Dirty;
       if Win.Surface_Update (W.EP, W.Id, 0, 0, GW, GH) /=
         Win.Status_Ok
       then
          Debug_Put_Line ("trinket: update failed");
       end if;
    end Handle_Resize;

    function Open
      (W         : in out Window;
       Bureau_EP : U64;
       Req_W     : U64;
       Req_H     : U64;
       Title     : String;
       Root      : Widgets.Any_Widget;
       Resizable : Boolean := True) return Boolean
    is
       Pages   : U64;
       Result  : U64;
       Q_Mint  : U64;
       N_Mint  : U64;
       Min_W   : U64;
       Min_H   : U64;
       Open_W  : U64 := Req_W;
       Open_H  : U64 := Req_H;
    begin
       Fonts.Init;
       W.EP := Bureau_EP;
       W.Root := Root;

       --  M86g: content-size negotiation — grow the request up
       --  to the root's Min_Size so a font change can never
       --  leave the layout cramped (Bureau still clamps the top
       --  end to the display; past that, widgets clip).
       Root.Min_Size (Min_W, Min_H);
       if Min_W > Open_W then
          Open_W := Min_W;
       end if;
       if Min_H > Open_H then
          Open_H := Min_H;
       end if;


      --  v3 input channel: queue page + sink EP + thread-bound
      --  notification (the demo.adb pattern).
      W.Queue_Cap := Mem_Alloc (1);
      W.Sink_EP := EP_Create;
      if W.Queue_Cap = Syscall_Failed
        or else W.Sink_EP = Syscall_Failed
      then
         return False;
      end if;
      Result := Mem_Map
        (Address_Space => Address_Space_Cap,
         Cap           => W.Queue_Cap,
         VA            => Queue_VA,
         Offset        => 0,
         Length        => 4096,
         Flags         => 3);
      if Result /= 0 then
         return False;
      end if;
      declare
         Queue : Word_Array
           with Address => SSE.To_Address
             (SSE.Integer_Address (Queue_VA));
      begin
         Queue (Win.Input_Queue_Head) := 0;
         Queue (Win.Input_Queue_Tail) := 0;
      end;
      W.Ntfn_Cap := Ntfn_Create;
      if W.Ntfn_Cap = Syscall_Failed
        or else Ntfn_Bind_Thread (W.Ntfn_Cap) /= 0
      then
         return False;
      end if;

      --  m68 app port: one-page ring, signalled with bit 2 on the
      --  same thread-bound notification (worker tasks wake the
      --  loop thread's blocking IPC_Recv).
      W.AppQ_Cap := Mem_Alloc (1);
      if W.AppQ_Cap = Syscall_Failed then
         return False;
      end if;
      Result := Mem_Map
        (Address_Space => Address_Space_Cap,
         Cap           => W.AppQ_Cap,
         VA            => AppQ_VA,
         Offset        => 0,
         Length        => 4096,
         Flags         => 3);
      if Result /= 0 then
         return False;
      end if;
      App_Port.Setup
        (W.App_Port,
         SSE.To_Address (SSE.Integer_Address (AppQ_VA)),
         W.Ntfn_Cap);

      Q_Mint := Cap_Mint
        (W.Queue_Cap, Right_Map + Right_Read + Right_Write +
         Right_Transfer, 0);
      N_Mint := Cap_Mint (W.Ntfn_Cap, Right_Write + Right_Transfer, 0);
      if Q_Mint = Syscall_Failed or else N_Mint = Syscall_Failed then
         return False;
      end if;
        Result := Win.Surface_Create
          (Bureau_EP, Open_W, Open_H, Q_Mint, N_Mint,
          W.Id, Pages, W.Cnv.W, W.Cnv.H,
          Flags => (if Resizable then Win.Flag_Resizable else 0));
      declare
         D1 : constant U64 := Cap_Delete (Q_Mint);
         D2 : constant U64 := Cap_Delete (N_Mint);
         pragma Unreferenced (D1, D2);
      begin
         null;
      end;
      if Result /= Win.Status_Ok then
         return False;
      end if;

       --  Chunked surface buffer: each chunk is its own memory
       --  object (<= 64 pages), mapped contiguously; minted caps
       --  go to Bureau one per Set_Buffer call, then one commit.
       if not Push_Surface (W, Pages) then
          return False;
       end if;
       if Win.Surface_Set_Title (Bureau_EP, W.Id, Title) /=
         Win.Status_Ok
       then
          return False;
       end if;

      W.Cnv.Base := SSE.To_Address (SSE.Integer_Address (Surf_VA));
      Reset_Clip (W.Cnv);
      W.Root.X := 0;
      W.Root.Y := 0;
      W.Root.W := W.Cnv.W;
      W.Root.H := W.Cnv.H;
      W.Root.Layout;
      W.Opened := True;
      return True;
   end Open;

    procedure Flush_Dirty (W : in out Window) is
       Rects : Widgets.Rect_Array;
       N     : Natural := 0;
       Ovfl  : Boolean := False;
       X0, Y0, X1, Y1 : U64;
    begin
       --  Fine-grained damage: one band per dirty widget cluster.
       --  Overflow (more than Max_Damage disjoint dirty rects)
       --  degrades to the old single union band.
       W.Root.Dirty_List (Rects, N, Ovfl);
       if W.Overlay /= null then
          --  M88: the overlay damages like any widget, but is not
          --  part of the tree's list.
          W.Overlay.Dirty_List (Rects, N, Ovfl);
       end if;
       if Ovfl then
          if not W.Root.Dirty_Union (X0, Y0, X1, Y1) then
             return;  --  unreachable (Ovfl implies dirty)
          end if;
          N := 1;
          Rects (1) := (X0, Y0, X1, Y1);
       end if;
       if W.Has_Pending then
          --  M88: the band a closed popup vacated — not reachable
          --  through any widget's Dirty flag.
          W.Has_Pending := False;
          if N < Widgets.Max_Damage then
             N := N + 1;
             Rects (N) := (W.Pend_X0, W.Pend_Y0, W.Pend_X1, W.Pend_Y1);
          else
             Rects (1) := (U64'Min (Rects (1).X0, W.Pend_X0),
                           U64'Min (Rects (1).Y0, W.Pend_Y0),
                           U64'Max (Rects (1).X1, W.Pend_X1),
                           U64'Max (Rects (1).Y1, W.Pend_Y1));
          end if;
       end if;
       if N = 0 then
          return;
       end if;
       for I in 1 .. N loop
          X0 := Rects (I).X0;
          Y0 := Rects (I).Y0;
          X1 := Rects (I).X1;
          Y1 := Rects (I).Y1;
          W.Cnv.CX0 := X0;
          W.Cnv.CY0 := Y0;
          W.Cnv.CX1 := X1;
          W.Cnv.CY1 := Y1;
          --  Repaint the band: window-bg fill first so shrinking
          --  or moved content leaves no trails. The tree redraws
          --  clipped, so overlapping bands land identical pixels.
          Trinket.Paint.Fill_Rect (W.Cnv, X0, Y0, X1, Y1,
                                   Win_Face);
          W.Root.Draw (W.Cnv);
          if W.Overlay /= null then
             --  M88: overlay paints last, on top, in every band.
             W.Overlay.Draw (W.Cnv);
          end if;
          if Win.Surface_Update
            (W.EP, W.Id, X0, Y0, X1 - X0, Y1 - Y0) /= Win.Status_Ok
          then
             Debug_Put_Line ("trinket: update failed");
          end if;
       end loop;
       W.Root.Clear_Dirty;
       if W.Overlay /= null then
          W.Overlay.Clear_Dirty;
       end if;
       Reset_Clip (W.Cnv);
    end Flush_Dirty;

   procedure Run (W : in out Window) is
      Queue : Word_Array
        with Address => SSE.To_Address
          (SSE.Integer_Address (Queue_VA));
      Reply_H : U64;
      Done    : Boolean := False;
   begin
      while not Done and then not W.Quit_Wanted loop
         Flush_Dirty (W);
         if IPC_Recv (W.Sink_EP, Reply_H) /= IPC_Ok then
            Debug_Put_Line ("trinket: recv failed");
            return;
         end if;
         if Message.Label = Notification_Label then
            declare
               Head : constant U64 := Queue (Win.Input_Queue_Head);
               Tail : U64 := Queue (Win.Input_Queue_Tail);
               Slot : U64;
               Val  : U64;
               X, Y : U64;
               Btn  : U64;
               Consumed : Boolean;
               pragma Unreferenced (Consumed);
            begin
               while Tail < Head loop
                  Slot := Win.Input_Queue_First
                    + (Tail mod Win.Input_Queue_Events) * 2;
                  Val := Queue (Slot + 1);
                  if Queue (Slot) = Win.Input_Event_Key then
                     if W.Overlay /= null then
                        --  M88: modal-ish — Escape closes, other
                        --  keys go to the overlay only; Tab never
                        --  cycles the tree behind it.
                        if (Val and 16#FF#) = 27 then
                           Close_Popup (W);
                        else
                           Consumed := W.Overlay.On_Key
                             (Val and 16#FF#);
                        end if;
                     elsif (Val and 16#FF#) = Key_Tab then
                        --  M87h: Tab never reaches widgets; it
                        --  cycles the window's focus chain.
                        Widgets.Cycle_Focus (W.Root);
                     else
                        Consumed := W.Root.On_Key (Val and 16#FF#);
                     end if;
                  elsif Queue (Slot) = Win.Input_Event_Pointer then
                     X := Win.Pointer_X (Val);
                     Y := Win.Pointer_Y (Val);
                     Btn := Win.Pointer_Buttons (Val);
                     if (Btn and 1) /= 0
                       and then (W.Prev_Buttons and 1) = 0
                     then
                        if W.Overlay /= null then
                           --  M88: press-in goes to the overlay;
                           --  press-outside dismisses (swallowed,
                           --  tree focus untouched).
                           if Widgets.Inside (W.Overlay.all, X, Y)
                           then
                              Consumed := W.Overlay.On_Pointer
                                (Widgets.Press, X, Y);
                           else
                              Close_Popup (W);
                           end if;
                        else
                           --  M87h: single-focus invariant — drop
                           --  all focus, the pressed gadget
                           --  re-takes it.
                           Widgets.Clear_Focus (W.Root);
                           Consumed := W.Root.On_Pointer
                             (Widgets.Press, X, Y);
                        end if;
                     elsif (Btn and 1) = 0
                       and then (W.Prev_Buttons and 1) /= 0
                     then
                        if W.Overlay /= null then
                           --  M88: a completed click ends the
                           --  popup (the release picks first).
                           Consumed := W.Overlay.On_Pointer
                             (Widgets.Release, X, Y);
                           Close_Popup (W);
                        else
                           Consumed := W.Root.On_Pointer
                             (Widgets.Release, X, Y);
                        end if;
                     else
                        if W.Overlay /= null then
                           Consumed := W.Overlay.On_Pointer
                             (Widgets.Move, X, Y);
                        else
                           Consumed := W.Root.On_Pointer
                             (Widgets.Move, X, Y);
                        end if;
                     end if;
                     W.Prev_Buttons := Btn;
                   elsif Queue (Slot) = Win.Input_Event_Close then
                      Done := True;
                   elsif Queue (Slot) = Win.Input_Event_Menu then
                      if W.On_Menu /= null then
                         W.On_Menu (Val and 16#FFFF_FFFF#);
                      end if;
                   elsif Queue (Slot) = Win.Input_Event_Resize then
                      --  v5: the zoom gadget. Resize the surface
                      --  and re-layout; only arrives when Open
                      --  was called with Resizable => True.
                      Handle_Resize (W, Win.Size_W (Val),
                                     Win.Size_H (Val));
                   end if;
                  Tail := Tail + 1;
               end loop;
                Queue (Win.Input_Queue_Tail) := Tail;
             end;
             --  m68: drain app messages posted by worker tasks
             --  (and same-thread posts). The quit message ends
             --  the loop after this batch is dispatched.
             declare
                Quit_Seen : Boolean;
             begin
                App_Port.Drain (W.App_Port, W.On_App, Quit_Seen);
                Done := Done or Quit_Seen;
             end;
          end if;
      end loop;
      Flush_Dirty (W);
   end Run;

   procedure Request_Quit (W : in out Window) is
      Posted : constant Boolean :=
        Post (W, App_Port.App_Code_Quit, 0, 0, 0);
   begin
      if not Posted then
         --  Ring full: a wake is already pending, so the loop
         --  will drain and re-check this flag before blocking.
         W.Quit_Wanted := True;
      end if;
   end Request_Quit;

   function Post
     (W             : in out Window;
      Code, A0, A1, A2 : U64) return Boolean is
   begin
      return App_Port.Post (W.App_Port, Code, A0, A1, A2);
   end Post;

   procedure Set_App_Handler
     (W : in out Window; Cb : App_Port.Msg_Callback) is
   begin
      W.On_App := Cb;
   end Set_App_Handler;

   --  Milestone 61: serialize the tree into a one-page memobj
   --  (layout in akernel_user-window.ads) and hand Bureau a
   --  Map+Read+Transfer mint; Bureau copies it out, so the page
   --  is deleted right after the call. The wire packing itself
   --  is Trinket.Menus.Serialize (shared with raw-protocol
   --  clients: terminal, demo).
   procedure Set_Menus
     (W : in out Window; Menus : Trinket.Menus.Menu_Array)
   is
      Cap    : U64;
      Minted : U64;
      Result : U64;
   begin
      if not W.Opened then
         return;
      end if;
      Cap := Mem_Alloc (1);
      if Cap = Syscall_Failed then
         return;
      end if;
      Result := Mem_Map
        (Address_Space => Address_Space_Cap,
         Cap           => Cap,
         VA            => Menu_VA,
         Offset        => 0,
         Length        => 4096,
         Flags         => 3);
      if Result /= 0 then
         Result := Cap_Delete (Cap);
         return;
      end if;
      Trinket.Menus.Serialize
        (Menus, SSE.To_Address (SSE.Integer_Address (Menu_VA)));
      Minted := Cap_Mint
        (Cap, Right_Map + Right_Read + Right_Transfer, 0);
      if Minted /= Syscall_Failed then
         Result := Win.Surface_Set_Menus (W.EP, W.Id, Minted);
         Result := Cap_Delete (Minted);
      end if;
      Result := Mem_Unmap (Address_Space_Cap, Menu_VA, 4096);
      Result := Cap_Delete (Cap);
   end Set_Menus;

   procedure Set_Menu_Handler
     (W : in out Window; Cb : Menu_Callback) is
   begin
      W.On_Menu := Cb;
   end Set_Menu_Handler;

   procedure Close (W : in out Window) is
      Result : U64;
   begin
      if W.Opened then
         Result := Win.Surface_Destroy (W.EP, W.Id);
         W.Opened := False;
      end if;
   end Close;

   --  M88: overlay lifecycle. Open sizes the panel to its
   --  Min_Size, clamps it into the surface, lays it out (a group
   --  panel gets its kids placed) and marks it dirty; Flush_Dirty
   --  picks the rect up from there. Close records the vacated
   --  band as pending damage (no widget owns that rect anymore).
   procedure Open_Popup
     (W : in out Window; Panel : Widgets.Any_Widget; X, Y : U64)
   is
      PW, PH : U64;
      PX      : U64 := X;
      PY      : U64 := Y;
   begin
      if Panel = null then
         return;
      end if;
      if W.Overlay /= null then
         Close_Popup (W);
      end if;
      Panel.Min_Size (PW, PH);
      if PX + PW > W.Cnv.W then
         PX := (if PW < W.Cnv.W then W.Cnv.W - PW else 0);
      end if;
      if PY + PH > W.Cnv.H then
         PY := (if PH < W.Cnv.H then W.Cnv.H - PH else 0);
      end if;
      Panel.X := PX;
      Panel.Y := PY;
      Panel.W := PW;
      Panel.H := PH;
      Panel.Layout;
      Panel.Dirty := True;
      W.Overlay := Panel;
   end Open_Popup;

   procedure Close_Popup (W : in out Window) is
   begin
      if W.Overlay = null then
         return;
      end if;
      W.Pend_X0 := W.Overlay.X;
      W.Pend_Y0 := W.Overlay.Y;
      W.Pend_X1 := W.Overlay.X + W.Overlay.W;
      W.Pend_Y1 := W.Overlay.Y + W.Overlay.H;
      W.Has_Pending := True;
      W.Overlay := null;
   end Close_Popup;

   function Popup_Active (W : Window) return Boolean is
     (W.Overlay /= null);

   function Surf_Width (W : Window) return U64 is (W.Cnv.W);
   function Surf_Height (W : Window) return U64 is (W.Cnv.H);

end Trinket.Window;
