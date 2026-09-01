with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Window;
with Trinket.Paint;
with Trinket.Fonts;
with Trinket.Menus;

package body Trinket.Window is
   use Akernel_User.Syscalls;
   use type Trinket.U64;
   package Win renames Akernel_User.Window;
   package SSE renames System.Storage_Elements;

   --  Mapping VAs (fixed literals, never derived — the 37b
   --  followup burn). Clear of text 0x4600_0000, args
   --  0x4800_0000, the newlib sbrk arena 0x5200_0000 (2 MiB),
   --  and stacks/IPC at 0x7000_0000+.
   Queue_VA : constant U64 := 16#5F00_0000#;
   Surf_VA  : constant U64 := 16#5F80_0000#;  --  8 MiB window
   Menu_VA  : constant U64 := 16#5F10_0000#;  --  m61 menu page
   AppQ_VA  : constant U64 := 16#5F20_0000#;  --  m68 app port page

   Chunk_Pages : constant U64 := 64;  --  per Mem_Alloc chunk
   Max_Chunks  : constant U64 := 4;

   type Word_Array is array (U64 range 0 .. 511) of U64
     with Volatile_Components;

   function Open
     (W         : in out Window;
      Bureau_EP : U64;
      Req_W     : U64;
      Req_H     : U64;
      Title     : String;
      Root      : Widgets.Any_Widget) return Boolean
   is
      Pages   : U64;
      Result  : U64;
      Q_Mint  : U64;
      N_Mint  : U64;
   begin
      Fonts.Init;
      W.EP := Bureau_EP;
      W.Root := Root;

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
        (Bureau_EP, Req_W, Req_H, Q_Mint, N_Mint,
         W.Id, Pages, W.Cnv.W, W.Cnv.H);
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

      if Pages > Chunk_Pages * Max_Chunks then
         return False;
      end if;
      --  Chunked surface buffer: each chunk is its own memory
      --  object (<= 64 pages), mapped contiguously; minted caps
      --  go to Bureau in groups of 4, then one commit.
      declare
         Chunks   : constant U64 :=
           (Pages + Chunk_Pages - 1) / Chunk_Pages;
         Minted   : U64;
         Left     : U64 := Pages;
         This     : U64;
      begin
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
              (Bureau_EP, W.Id, I, Minted);
            Result := Cap_Delete (Minted);
            if Result /= Win.Status_Ok then
               return False;
            end if;
         end loop;
      end;
      if Win.Surface_Commit_Buffer (Bureau_EP, W.Id) /=
        Win.Status_Ok
      then
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
       if Ovfl then
          if not W.Root.Dirty_Union (X0, Y0, X1, Y1) then
             return;  --  unreachable (Ovfl implies dirty)
          end if;
          N := 1;
          Rects (1) := (X0, Y0, X1, Y1);
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
          --  Repaint the band: face-fill it first so shrinking or
          --  moved content leaves no trails. The tree redraws
          --  clipped, so overlapping bands land identical pixels.
          Trinket.Paint.Fill_Rect (W.Cnv, X0, Y0, X1, Y1, Face);
          W.Root.Draw (W.Cnv);
          if Win.Surface_Update
            (W.EP, W.Id, X0, Y0, X1 - X0, Y1 - Y0) /= Win.Status_Ok
          then
             Debug_Put_Line ("trinket: update failed");
          end if;
       end loop;
       W.Root.Clear_Dirty;
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
                     Consumed := W.Root.On_Key (Val and 16#FF#);
                  elsif Queue (Slot) = Win.Input_Event_Pointer then
                     X := Win.Pointer_X (Val);
                     Y := Win.Pointer_Y (Val);
                     Btn := Win.Pointer_Buttons (Val);
                     if (Btn and 1) /= 0
                       and then (W.Prev_Buttons and 1) = 0
                     then
                        Consumed := W.Root.On_Pointer
                          (Widgets.Press, X, Y);
                     elsif (Btn and 1) = 0
                       and then (W.Prev_Buttons and 1) /= 0
                     then
                        Consumed := W.Root.On_Pointer
                          (Widgets.Release, X, Y);
                     else
                        Consumed := W.Root.On_Pointer
                          (Widgets.Move, X, Y);
                     end if;
                     W.Prev_Buttons := Btn;
                  elsif Queue (Slot) = Win.Input_Event_Close then
                     Done := True;
                  elsif Queue (Slot) = Win.Input_Event_Menu then
                     if W.On_Menu /= null then
                        W.On_Menu (Val and 16#FFFF_FFFF#);
                     end if;
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

   function Surf_Width (W : Window) return U64 is (W.Cnv.W);
   function Surf_Height (W : Window) return U64 is (W.Cnv.H);

end Trinket.Window;
