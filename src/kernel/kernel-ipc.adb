with Ada.Unchecked_Conversion;
with System.Storage_Elements;
with Arch;
with Kernel.Physical_Memory;
with Kernel.Processes;
with Kernel.Scheduler;

package body Kernel.IPC is
   use type Kernel.Capabilities.Object_Kind;
   use type Kernel.Capabilities.Status;
   use type Kernel.Capabilities.U64;
   use type Kernel.Physical_Memory.Status;
   use type System.Address;
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;

   type Endpoint_Access is access all Endpoint;

   function To_Endpoint is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Endpoint_Access);

   function To_Thread is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Kernel.Tasks.Thread_Access);

   Send_Right : constant Kernel.Capabilities.Rights :=
     (Read     => False,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => True,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => False,
      Manage   => False);

   Receive_Right : constant Kernel.Capabilities.Rights :=
     (Read     => False,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => False,
      Receive  => True,
      Wait     => False,
      Ack      => False,
      Transfer => False,
      Manage   => False);

   ------------------------------------------------------------------
   --  IPC buffer overlay (docs/IPC.md message format, 96 bytes)
   ------------------------------------------------------------------

   type Buffer_Word_Array is array (0 .. Max_Words - 1) of U64;
   type Buffer_Cap_Array is array (0 .. Max_Caps - 1) of U64;

   type Buffer_Message is record
      Label : U64;
      Words : Buffer_Word_Array;
      Caps  : Buffer_Cap_Array;
      Badge : U64;
   end record;

   type Buffer_Message_Access is access all Buffer_Message;

   function Buffer_Of
     (Thread : Kernel.Tasks.Thread_Access) return Buffer_Message_Access
   is
      PA : Kernel.Capabilities.U64;
   begin
      if Thread = null then
         return null;
      end if;

      PA := Kernel.Tasks.IPC_Buffer_PA (Thread.all);
      if PA = 0 then
         return null;
      end if;

      declare
         VA : constant System.Address := System'To_Address
           (System.Storage_Elements.Integer_Address (Arch.Phys_To_Virt (PA)));
         function To_Buffer is new Ada.Unchecked_Conversion
           (Source => System.Address,
            Target => Buffer_Message_Access);
      begin
         return To_Buffer (VA);
      end;
   end Buffer_Of;

   function Is_Dead (Thread : Kernel.Tasks.Thread_Access) return Boolean is
   begin
      return Thread = null
        or else Kernel.Tasks.State (Thread.all) = Kernel.Tasks.Dead;
   end Is_Dead;

   --  Deliver a syscall result code to a blocked thread and wake it.
   --  Do NOT touch the saved context of a running/ready thread:
   --  its saved a0 is from a previous trap and will be restored the
   --  next time it blocks, corrupting its entry parameters.
   procedure Wake_With_Result
     (Thread : Kernel.Tasks.Thread_Access;
      Value  : U64)
   is
      Wake_Result : Kernel.Scheduler.Status;
   begin
      if Is_Dead (Thread) then
         return;
      end if;

      if Kernel.Tasks.State (Thread.all) not in
           Kernel.Tasks.Blocked_Send
         | Kernel.Tasks.Blocked_Receive
         | Kernel.Tasks.Blocked_IRQ
         | Kernel.Tasks.Blocked_Notification
         | Kernel.Tasks.Blocked_Sleeping
         | Kernel.Tasks.Blocked_Thread_Wait
      then
         return;
      end if;

      Kernel.Tasks.Set_Saved_Result (Thread.all, Value);
      Kernel.Tasks.Set_Awaiting_Reply (Thread.all, False);
      Kernel.Scheduler.Wake (Thread, Wake_Result);
   end Wake_With_Result;

   ------------------------------------------------------------------
   --  Queued-send pool (fire-and-forget message copies)
   ------------------------------------------------------------------

   --  Fixed pool; a send that finds no slot falls back to blocking
   --  the caller (classic rendezvous), so a full pool degrades to
   --  back-pressure rather than message loss.
   Max_Queued_Sends : constant := 64;

   Send_Pool : array (1 .. Max_Queued_Sends) of aliased Queued_Send :=
     (others =>
        (Label  => 0,
         Words  => (others => 0),
         Badge  => 0,
         Next   => null,
         In_Use => False));

   function Alloc_Queued_Send return Queued_Send_Access is
   begin
      for Slot of Send_Pool loop
         if not Slot.In_Use then
            Slot.In_Use := True;
            Slot.Next   := null;
            return Slot'Access;
         end if;
      end loop;
      return null;
   end Alloc_Queued_Send;

   procedure Free_Queued_Send (Slot : Queued_Send_Access) is
   begin
      Slot.In_Use := False;
      Slot.Next   := null;
   end Free_Queued_Send;

   --  Copy the caller's message words/label/badge into a pool slot.
   function Queue_Send_Copy
     (Caller : Kernel.Tasks.Thread_Access;
      Badge  : U64) return Queued_Send_Access
   is
      Buf  : constant Buffer_Message_Access := Buffer_Of (Caller);
      Slot : Queued_Send_Access;
   begin
      Slot := Alloc_Queued_Send;
      if Slot = null then
         return null;
      end if;

      Slot.Label := Buf.Label;
      for I in Buf.Words'Range loop
         Slot.Words (I) := Buf.Words (I);
      end loop;
      Slot.Badge := Badge;
      return Slot;
   end Queue_Send_Copy;

   ------------------------------------------------------------------
   --  Dynamic endpoint slab (PMM-backed)
   ------------------------------------------------------------------

   Free_Head : System.Address := System.Null_Address;

   procedure Free_Endpoint (Object : Endpoint_Access) is
   begin
      Object.Next_Free := Free_Head;
      Free_Head := Object.all'Address;
   end Free_Endpoint;

   procedure Grow_Pool (Result : out Status) is
      use System.Storage_Elements;

      --  Slot size rounded up to 16 bytes; computed at elaboration
      --  ('Size is not static for record types).
      Slot_Bytes : constant Storage_Count :=
        Storage_Count ((Endpoint'Size + 127) / 128 * 16);
      Slots_Per_Frame : constant Natural :=
        Natural (Kernel.Physical_Memory.Page_Size) / Natural (Slot_Bytes);

      PMM_Result : Kernel.Physical_Memory.Status;
      Frame_PA   : Kernel.Capabilities.U64;
      Base       : System.Address;
   begin
      Kernel.Physical_Memory.Allocate_Frame (PMM_Result, Frame_PA);

      if PMM_Result /= Kernel.Physical_Memory.Ok then
         Result := No_Endpoints;
         return;
      end if;

      Base := System'To_Address
        (Integer_Address (Arch.Phys_To_Virt (Frame_PA)));

      for Slot in 0 .. Slots_Per_Frame - 1 loop
         Free_Endpoint
           (To_Endpoint (Base + Storage_Offset (Slot) * Slot_Bytes));
      end loop;

      Result := Ok;
   end Grow_Pool;

   procedure Create_Endpoint
     (Result : out Status;
      Object : out System.Address)
   is
      Slot : Endpoint_Access;
   begin
      Object := System.Null_Address;

      if Free_Head = System.Null_Address then
         Grow_Pool (Result);
         if Result /= Ok then
            return;
         end if;
      end if;

      Slot := To_Endpoint (Free_Head);
      Free_Head := Slot.Next_Free;
      Slot.Next_Free := System.Null_Address;
      Initialize (Slot.all, Pinned => False);
      Object := Slot.all'Address;
      Result := Ok;
   end Create_Endpoint;

   procedure Discard (Object : System.Address) is
      Slot : constant Endpoint_Access := To_Endpoint (Object);
   begin
      if Slot = null then
         return;
      end if;

      Free_Endpoint (Slot);
   end Discard;

   procedure Initialize (Object : out Endpoint; Pinned : Boolean) is
   begin
      if Pinned then
         Object.Header.Count := Kernel.Objects.Pinned_Refcount;
      else
         Object.Header.Count := 0;
      end if;

      Object.Queue_Head := null;
      Object.Queue_Tail := null;
      Object.Waiting_Receiver := null;
      Object.Send_Queue_Head := null;
      Object.Send_Queue_Tail := null;
      Object.Failed := False;
      Object.Next_Free := System.Null_Address;
   end Initialize;

   procedure Retain (Object : System.Address) is
      Endpoint_Object : constant Endpoint_Access := To_Endpoint (Object);
      use type Kernel.Objects.Refcount;
   begin
      if Endpoint_Object = null
        or else Endpoint_Object.Header.Count =
          Kernel.Objects.Pinned_Refcount
      then
         return;
      end if;

      Endpoint_Object.Header.Count := Endpoint_Object.Header.Count + 1;
   end Retain;

   function Release (Object : System.Address) return Boolean is
      Endpoint_Object : constant Endpoint_Access := To_Endpoint (Object);
      use type Kernel.Objects.Refcount;
   begin
      if Endpoint_Object = null
        or else Endpoint_Object.Header.Count =
          Kernel.Objects.Pinned_Refcount
        or else Endpoint_Object.Header.Count = 0
      then
         return False;
      end if;

      Endpoint_Object.Header.Count := Endpoint_Object.Header.Count - 1;

      if Endpoint_Object.Header.Count /= 0 then
         return False;
      end if;

      --  Last reference dropped: fail every queued caller and the
      --  waiting receiver (each wakes with Result_Endpoint_Gone),
      --  then return the slot to the slab.
      Fail_Endpoint (Object);

      Free_Endpoint (Endpoint_Object);
      return True;
   end Release;

   procedure Fail_Endpoint (Object : System.Address) is
      Endpoint_Object : constant Endpoint_Access :=
        To_Endpoint (Object);
      Caller          : Kernel.Tasks.Thread_Access;
   begin
      if Endpoint_Object = null or else Endpoint_Object.Failed then
         return;
      end if;

      Endpoint_Object.Failed := True;

      while Endpoint_Object.Queue_Head /= null loop
         Caller := Endpoint_Object.Queue_Head;
         Endpoint_Object.Queue_Head :=
           Kernel.Tasks.Endpoint_Queue_Next (Caller.all);
         Kernel.Tasks.Set_Endpoint_Queue_Next (Caller.all, null);
         Kernel.Tasks.Set_Queued_On_EP
           (Caller.all, System.Null_Address);
         Wake_With_Result (Caller, Result_Endpoint_Gone);
      end loop;
      Endpoint_Object.Queue_Tail := null;

      --  Queued fire-and-forget sends are ownerless once the
      --  endpoint dies: drop the copies back into the pool.
      declare
         Slot : Queued_Send_Access := Endpoint_Object.Send_Queue_Head;
         Next : Queued_Send_Access;
      begin
         while Slot /= null loop
            Next := Slot.Next;
            Free_Queued_Send (Slot);
            Slot := Next;
         end loop;
         Endpoint_Object.Send_Queue_Head := null;
         Endpoint_Object.Send_Queue_Tail := null;
      end;

      Wake_With_Result (Endpoint_Object.Waiting_Receiver,
                        Result_Endpoint_Gone);
      Endpoint_Object.Waiting_Receiver := null;
   end Fail_Endpoint;

   ------------------------------------------------------------------
   --  Caller queue
   ------------------------------------------------------------------

   --  A stored Queue_Tail is trusted only while it still points at
   --  a thread queued on THIS endpoint with no successor.  Any
   --  residual staleness turns the enqueue into a wild Queue_Next
   --  write (m76), so a suspicious tail is rebuilt by walking from
   --  Queue_Head; the walk is bounded by the thread-table size so
   --  a corrupt cycle cannot hang the kernel.
   Max_Queue_Walk : constant := Kernel.Processes.Max_Thread_Slots;

   procedure Enqueue_Caller
     (Object : in out Endpoint;
      Caller : Kernel.Tasks.Thread_Access)
   is
      Scan : Kernel.Tasks.Thread_Access;
      Tail : Kernel.Tasks.Thread_Access;
   begin
      Kernel.Tasks.Set_Endpoint_Queue_Next (Caller.all, null);
      Kernel.Tasks.Set_Queued_On_EP (Caller.all, Object'Address);

      Tail := Object.Queue_Tail;
      if (Tail = null and then Object.Queue_Head /= null)
        or else
          (Tail /= null
           and then
             (Kernel.Tasks.Queued_On_EP (Tail.all) /= Object'Address
              or else Kernel.Tasks.Endpoint_Queue_Next (Tail.all) /=
                null))
      then
         Tail := null;
         Scan := Object.Queue_Head;
         for I in 1 .. Max_Queue_Walk loop
            exit when Scan = null;
            exit when Kernel.Tasks.Queued_On_EP (Scan.all) /=
              Object'Address;
            if Kernel.Tasks.Endpoint_Queue_Next (Scan.all) = null then
               Tail := Scan;
               exit;
            end if;
            Scan := Kernel.Tasks.Endpoint_Queue_Next (Scan.all);
         end loop;
         if Tail = null then
            --  The head chain is unusable: drop it rather than
            --  trust any of its links.
            Object.Queue_Head := null;
         end if;
      end if;

      if Tail = null then
         Object.Queue_Head := Caller;
      else
         Kernel.Tasks.Set_Endpoint_Queue_Next (Tail.all, Caller);
      end if;

      Object.Queue_Tail := Caller;
   end Enqueue_Caller;

   --  Pop the head caller, skipping dead entries. Null when empty.
   procedure Dequeue_Caller
     (Object : in out Endpoint;
      Caller : out Kernel.Tasks.Thread_Access)
   is
   begin
      loop
         Caller := Object.Queue_Head;
         exit when Caller = null;

         Object.Queue_Head := Kernel.Tasks.Endpoint_Queue_Next (Caller.all);
         if Object.Queue_Head = null then
            Object.Queue_Tail := null;
         end if;
         Kernel.Tasks.Set_Endpoint_Queue_Next (Caller.all, null);
         Kernel.Tasks.Set_Queued_On_EP
           (Caller.all, System.Null_Address);

         exit when not Is_Dead (Caller);
      end loop;
   end Dequeue_Caller;

   ------------------------------------------------------------------
   --  Endpoint resolution
   ------------------------------------------------------------------

   procedure Set_Stamp_Identity
     (Object : in out Endpoint;
      Stamp  : Boolean)
   is
   begin
      Object.Stamp_Identity := Stamp;
   end Set_Stamp_Identity;

   function Stamp_Identity (Object : Endpoint) return Boolean is
   begin
      return Object.Stamp_Identity;
   end Stamp_Identity;

   procedure Set_Stamp_Identity
     (Object_Address : System.Address;
      Stamp          : Boolean)
   is
      EP : constant Endpoint_Access := To_Endpoint (Object_Address);
   begin
      if EP /= null then
         EP.Stamp_Identity := Stamp;
      end if;
   end Set_Stamp_Identity;

   procedure Resolve_Endpoint
     (Caller       : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Needed       : Kernel.Capabilities.Rights;
      Result       : out Status;
      Object       : out Endpoint_Access;
      Badge        : out U64)
   is
      Cap_Result : Kernel.Capabilities.Status;
      Cap_Info   : Kernel.Capabilities.Cap_Entry;
   begin
      Object := null;
      Badge := 0;

      if Is_Dead (Caller) then
         Result := Invalid_Task;
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Caller.all,
         Cap       => Endpoint_Cap,
         Result    => Cap_Result,
         Out_Entry => Cap_Info);

      if Cap_Result /= Kernel.Capabilities.Ok then
         Result := Invalid_Cap;
         return;
      end if;

      if Cap_Info.Kind /= Kernel.Capabilities.Endpoint_Object then
         Result := Wrong_Object;
         return;
      end if;

      if not Kernel.Capabilities.Has_Rights (Cap_Info.Rights, Needed) then
         Result := Rights_Denied;
         return;
      end if;

      Object := To_Endpoint (Cap_Info.Object);
      if Object = null then
         Result := Wrong_Object;
         return;
      end if;

      Badge := Cap_Info.Badge;
      --  Milestone 41b/Proc:self: when an endpoint is marked as an
      --  identity endpoint, a zero cap badge is treated as "anonymous
      --  caller" and stamped with the caller's process id.  This lets
      --  the VFS forward the real client identity to filesystem
      --  servers without forcing every client to hold a unique,
      --  pre-minted capability, and without breaking other endpoints
      --  that legitimately use badge zero.
      if Badge = 0 and then Object.Stamp_Identity then
         Badge :=
           Kernel.Capabilities.U64
             (Kernel.Tasks.Process_Id_Of
                (Kernel.Tasks.Owning_Process (Caller.all).all));
      end if;
      Result := Ok;
   end Resolve_Endpoint;

   ------------------------------------------------------------------
   --  Message transfer
   ------------------------------------------------------------------

   --  Copy the message from the sender's IPC buffer to the receiver's,
   --  transferring caps (sender table -> receiver table, Transfer
   --  right required). On failure nothing is delivered and any caps
   --  already inserted into the receiver's table are rolled back.
   procedure Transfer_Message
     (Sender   : Kernel.Tasks.Thread_Access;
      Receiver : Kernel.Tasks.Thread_Access;
      Badge    : U64;
      Result   : out Status)
   is
      Send_Buf : constant Buffer_Message_Access := Buffer_Of (Sender);
      Recv_Buf : constant Buffer_Message_Access := Buffer_Of (Receiver);
      New_Handles : Buffer_Cap_Array := (others => 0);
      Cap_Result  : Kernel.Capabilities.Status;
      Cap_Info    : Kernel.Capabilities.Cap_Entry;
      New_Cap     : Kernel.Capabilities.Handle;

      procedure Rollback is
      begin
         for Slot of New_Handles loop
            if Slot /= 0 then
               Kernel.Tasks.Close_Cap
                 (Receiver,
                  Kernel.Capabilities.Handle (Slot),
                  Cap_Result);
            end if;
         end loop;
      end Rollback;
   begin
      if Send_Buf = null or else Recv_Buf = null then
         Result := Invalid_Task;
         return;
      end if;

      for Index in New_Handles'Range loop
         declare
            Raw : constant U64 := Send_Buf.Caps (Index);
         begin
            if Raw /= 0 then
               if Raw > U64 (Kernel.Capabilities.Handle'Last) then
                  Rollback;
                  Result := Transfer_Failed;
                  return;
               end if;

               Kernel.Tasks.Lookup_Cap
                 (TCB       => Sender.all,
                  Cap       => Kernel.Capabilities.Handle (Raw),
                  Result    => Cap_Result,
                  Out_Entry => Cap_Info);

               if Cap_Result /= Kernel.Capabilities.Ok
                 or else not Cap_Info.Rights.Transfer
                 or else Cap_Info.Kind = Kernel.Capabilities.Reply_Object
               then
                  --  Reply_Object rejected like cap_mint / spawn
                  --  grants do: a rollback Close_Cap on one would
                  --  wrongly fire Fail_Reply_Target via the close
                  --  hooks.
                  Rollback;
                  Result := Transfer_Failed;
                  return;
               end if;

               Kernel.Tasks.Insert_Cap
                 (TCB    => Receiver.all,
                  Kind   => Cap_Info.Kind,
                  Object => Cap_Info.Object,
                  Rights => Cap_Info.Rights,
                  Badge  => Cap_Info.Badge,
                  Result => Cap_Result,
                  Cap    => New_Cap);

               if Cap_Result /= Kernel.Capabilities.Ok then
                  Rollback;
                  Result := Transfer_Failed;
                  return;
               end if;

               New_Handles (Index) := U64 (New_Cap);
            end if;
         end;
      end loop;

      Recv_Buf.Label := Send_Buf.Label;
      Recv_Buf.Words := Send_Buf.Words;
      Recv_Buf.Caps := New_Handles;
      Recv_Buf.Badge := Badge;
      Result := Ok;
   end Transfer_Message;

   ------------------------------------------------------------------
   --  Reply cap
   ------------------------------------------------------------------

   procedure Fail_Reply_Target
     (Caller_Object : System.Address;
      Badge         : U64)
   is
      Caller : constant Kernel.Tasks.Thread_Access :=
        To_Thread (Caller_Object);
   begin
      if Is_Dead (Caller)
        or else not Kernel.Tasks.Is_Awaiting_Reply (Caller.all)
        or else Badge /= Kernel.Tasks.Reply_Generation (Caller.all)
      then
         --  Badge mismatch (m75): the cap outlived its caller's
         --  thread-slot incarnation; failing the slot's current
         --  occupant would be a cross-delivery.
         return;
      end if;

      Wake_With_Result (Caller, Result_Reply_Gone);
   end Fail_Reply_Target;

   --  Mint a one-shot reply cap in the receiver's table, pointing
   --  at the caller. Milestone 47: an ordinary free-slot cap (was
   --  a fixed handle-254 slot a re-receive overwrote, failing the
   --  previous caller); a server thread may now hold many
   --  outstanding reply caps and reply in any order. The badge
   --  stamps the caller's thread-slot generation (m75): after the
   --  caller dies and its slot is reused, the stale cap fails
   --  Reply/Fail_Reply_Target's generation check instead of
   --  cross-delivering to the slot's new owner.
   procedure Mint_Reply_Cap
     (Receiver : Kernel.Tasks.Thread_Access;
      Caller   : Kernel.Tasks.Thread_Access;
      Result   : out Status;
      Cap      : out Kernel.Capabilities.Handle)
   is
      Cap_Result : Kernel.Capabilities.Status;
   begin
      Cap := Kernel.Capabilities.Invalid_Handle;

      Kernel.Tasks.Insert_Cap
        (TCB    => Receiver.all,
         Kind   => Kernel.Capabilities.Reply_Object,
         Object => Caller.all'Address,
         Rights => Kernel.Capabilities.No_Rights,
         Badge  => Kernel.Tasks.Reply_Generation (Caller.all),
         Result => Cap_Result,
         Cap    => Cap);

      if Cap_Result /= Kernel.Capabilities.Ok then
         Result := Transfer_Failed;
         return;
      end if;

      Kernel.Tasks.Set_Awaiting_Reply (Caller.all, True);
      Result := Ok;
   end Mint_Reply_Cap;

   ------------------------------------------------------------------
   --  Rendezvous operations
   ------------------------------------------------------------------

   procedure Call
     (Caller       : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Result       : out Status)
   is
      Object       : Endpoint_Access;
      Badge        : U64;
      Receiver     : Kernel.Tasks.Thread_Access;
      Transfer_St  : Status;
      Mint_St      : Status;
      Reply_Cap    : Kernel.Capabilities.Handle;
   begin
      if Buffer_Of (Caller) = null then
         Result := Invalid_Task;
         return;
      end if;

      Resolve_Endpoint
        (Caller       => Caller,
         Endpoint_Cap => Endpoint_Cap,
         Needed       => Send_Right,
         Result       => Result,
         Object       => Object,
         Badge        => Badge);

      if Result /= Ok then
         return;
      end if;

      Kernel.Tasks.Set_Reply_Wanted (Caller.all, True);

      --  A failed endpoint fails fresh calls immediately instead of
      --  queuing the caller behind a dead server.
      if Object.Failed then
         Result := Endpoint_Gone;
         return;
      end if;

      if Object.Waiting_Receiver /= null
        and then not Is_Dead (Object.Waiting_Receiver)
        and then Kernel.Tasks.State (Object.Waiting_Receiver.all) =
               Kernel.Tasks.Blocked_Receive
        and then Kernel.Tasks.Recv_Endpoint (Object.Waiting_Receiver.all) =
               Object.all'Address
      then
         Receiver := Object.Waiting_Receiver;
         Object.Waiting_Receiver := null;

         Transfer_Message (Caller, Receiver, Badge, Transfer_St);
         if Transfer_St /= Ok then
            Wake_With_Result (Receiver, Result_Transfer_Failed);
            Result := Transfer_St;
            return;
         end if;

         Mint_Reply_Cap (Receiver, Caller, Mint_St, Reply_Cap);
         if Mint_St /= Ok then
            Wake_With_Result (Receiver, Result_Transfer_Failed);
            Result := Mint_St;
            return;
         end if;

         Kernel.Tasks.Set_IPC_Badge (Caller.all, Badge);
         --  The receiver surfaces Ok in a0 and its reply-cap handle
         --  in a1 (milestone 47).
         Kernel.Tasks.Set_Saved_A1
           (Receiver.all, Kernel.Capabilities.U64 (Reply_Cap));
         Wake_With_Result (Receiver, Result_Ok);
         Result := Would_Block;
         return;
      end if;

      --  The recorded waiting receiver is not actually blocked in
      --  Receive (e.g., it woke for a nested Send). Drop the stale
      --  reference so a later Receive can retake the slot.
      if Object.Waiting_Receiver /= null
        and then not Is_Dead (Object.Waiting_Receiver)
      then
         Kernel.Tasks.Set_Recv_Endpoint
           (Object.Waiting_Receiver.all, System.Null_Address);
      end if;
      Object.Waiting_Receiver := null;

      --  No receiver: enqueue FIFO; badge recorded for the later
      --  transfer.
      Kernel.Tasks.Set_IPC_Badge (Caller.all, Badge);
      Enqueue_Caller (Object.all, Caller);
      Result := Would_Block;
   end Call;

   procedure Send
     (Caller       : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Result       : out Status)
   is
      Object       : Endpoint_Access;
      Badge        : U64;
      Receiver     : Kernel.Tasks.Thread_Access;
      Transfer_St  : Status;
   begin
      if Buffer_Of (Caller) = null then
         Result := Invalid_Task;
         return;
      end if;

      Resolve_Endpoint
        (Caller       => Caller,
         Endpoint_Cap => Endpoint_Cap,
         Needed       => Send_Right,
         Result       => Result,
         Object       => Object,
         Badge        => Badge);

      if Result /= Ok then
         return;
      end if;

      Kernel.Tasks.Set_Reply_Wanted (Caller.all, False);

      --  Same failed-endpoint rule as Call.
      if Object.Failed then
         Result := Endpoint_Gone;
         return;
      end if;

      if Object.Waiting_Receiver /= null
        and then not Is_Dead (Object.Waiting_Receiver)
        and then Kernel.Tasks.State (Object.Waiting_Receiver.all) =
               Kernel.Tasks.Blocked_Receive
        and then Kernel.Tasks.Recv_Endpoint (Object.Waiting_Receiver.all) =
               Object.all'Address
      then
         --  Direct handoff: delivered at once, no reply phase, so
         --  the sender returns Ok instead of blocking.
         Receiver := Object.Waiting_Receiver;
         Object.Waiting_Receiver := null;

         Transfer_Message (Caller, Receiver, Badge, Transfer_St);
         if Transfer_St /= Ok then
            Wake_With_Result (Receiver, Result_Transfer_Failed);
            Result := Transfer_St;
            return;
         end if;

         --  No reply cap minted: the woken receiver surfaces a1 = 0.
         Kernel.Tasks.Set_Saved_A1 (Receiver.all, 0);
         Wake_With_Result (Receiver, Result_Ok);
         Result := Ok;
         return;
      end if;

      --  The recorded waiting receiver is not actually blocked in
      --  Receive (e.g., it woke for a nested Send). Drop the stale
      --  reference so a later Receive can retake the slot.
      if Object.Waiting_Receiver /= null
        and then not Is_Dead (Object.Waiting_Receiver)
      then
         Kernel.Tasks.Set_Recv_Endpoint
           (Object.Waiting_Receiver.all, System.Null_Address);
      end if;
      Object.Waiting_Receiver := null;

      --  No receiver: fire-and-forget means the sender KEEPS
      --  RUNNING, so the queued state cannot reference its live
      --  buffer/badge/queue links — its next IPC op would clobber
      --  them while the endpoint still points at the thread (the
      --  M68 plain-send corruption: a send followed by a report
      --  call cross-delivered the call to the send's receiver).
      --  Copy the message into a kernel-side slot; the next Receive
      --  drains the copy. Cap-carrying sends (a queued copy cannot
      --  hold caps) and a full pool fall back to the blocking
      --  rendezvous, which is safe because the caller is suspended
      --  for the whole time it sits on the caller queue.
      declare
         Buf : constant Buffer_Message_Access := Buffer_Of (Caller);
         Has_Caps : Boolean := False;
         Slot : Queued_Send_Access;
      begin
         for Raw of Buf.Caps loop
            if Raw /= 0 then
               Has_Caps := True;
               exit;
            end if;
         end loop;

         if not Has_Caps then
            Slot := Queue_Send_Copy (Caller, Badge);
            if Slot /= null then
               if Object.Send_Queue_Tail = null then
                  Object.Send_Queue_Head := Slot;
               else
                  Object.Send_Queue_Tail.Next := Slot;
               end if;
               Object.Send_Queue_Tail := Slot;
               Result := Ok;
               return;
            end if;
         end if;
      end;

      --  Blocking fallback: enqueue FIFO; the dequeueing Receive
      --  wakes the sender with Ok (Reply_Wanted is False, so no
      --  reply cap).
      Kernel.Tasks.Set_IPC_Badge (Caller.all, Badge);
      Enqueue_Caller (Object.all, Caller);
      Result := Would_Block;
   end Send;

   procedure Receive
     (Receiver     : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Result       : out Status;
      Reply_Handle : out Kernel.Capabilities.Handle)
   is
      Object      : Endpoint_Access;
      Badge       : U64;
      Caller      : Kernel.Tasks.Thread_Access;
      Transfer_St : Status;
      Mint_St     : Status;
   begin
      Reply_Handle := Kernel.Capabilities.Invalid_Handle;

      if Buffer_Of (Receiver) = null then
         Result := Invalid_Task;
         return;
      end if;

      Resolve_Endpoint
        (Caller       => Receiver,
         Endpoint_Cap => Endpoint_Cap,
         Needed       => Receive_Right,
         Result       => Result,
         Object       => Object,
         Badge        => Badge);

      if Result /= Ok then
         return;
      end if;

      if Object.Failed then
         Result := Endpoint_Gone;
         return;
      end if;

      Dequeue_Caller (Object.all, Caller);

      if Caller = null then
         --  No blocked caller: drain a queued fire-and-forget send
         --  copy (payload only; these never carry caps or a reply
         --  phase, so a1 stays 0).
         if Object.Send_Queue_Head /= null then
            declare
               Slot     : constant Queued_Send_Access :=
                 Object.Send_Queue_Head;
               Recv_Buf : constant Buffer_Message_Access :=
                 Buffer_Of (Receiver);
            begin
               Object.Send_Queue_Head := Slot.Next;
               if Object.Send_Queue_Head = null then
                  Object.Send_Queue_Tail := null;
               end if;

               Recv_Buf.Label := Slot.Label;
               for I in Recv_Buf.Words'Range loop
                  Recv_Buf.Words (I) := Slot.Words (I);
               end loop;
               Recv_Buf.Badge := Slot.Badge;
               Recv_Buf.Caps  := (others => 0);
               Free_Queued_Send (Slot);
            end;
            Result := Ok;
            return;
         end if;

         if Object.Waiting_Receiver /= null
           and then Object.Waiting_Receiver /= Receiver
           and then not Is_Dead (Object.Waiting_Receiver)
         then
            --  Single receiver discipline: another live thread is
            --  already the registered receiver.
            Result := Invalid_Task;
            return;
         end if;

         Object.Waiting_Receiver := Receiver;
         Kernel.Tasks.Set_Recv_Endpoint
           (Receiver.all, Object.all'Address);
         Result := Would_Block;
         return;
      end if;

      Transfer_Message
        (Caller, Receiver, Kernel.Tasks.IPC_Badge (Caller.all), Transfer_St);
      if Transfer_St /= Ok then
         Wake_With_Result (Caller, Result_Transfer_Failed);
         Result := Transfer_St;
         return;
      end if;

      if not Kernel.Tasks.Is_Reply_Wanted (Caller.all) then
         --  Plain send: delivery completes the rendezvous. No reply
         --  cap is minted, so a Reply from this receiver fails.
         Wake_With_Result (Caller, Result_Ok);
         Result := Ok;
         return;
      end if;

      Mint_Reply_Cap (Receiver, Caller, Mint_St, Reply_Handle);
      if Mint_St /= Ok then
         Reply_Handle := Kernel.Capabilities.Invalid_Handle;
         Wake_With_Result (Caller, Result_Transfer_Failed);
         Result := Mint_St;
         return;
      end if;

      --  Caller stays blocked awaiting the reply; receiver returns
      --  with the message in its buffer.
      Result := Ok;
   end Receive;

   procedure Reply
     (Replier : Kernel.Tasks.Thread_Access;
      Cap     : Kernel.Capabilities.Handle;
      Result  : out Status)
   is
      Replier_Buf : constant Buffer_Message_Access := Buffer_Of (Replier);
      Cap_Result  : Kernel.Capabilities.Status;
      Cap_Info    : Kernel.Capabilities.Cap_Entry;
      Caller      : Kernel.Tasks.Thread_Access;
      Caller_Buf  : Buffer_Message_Access;
      Transfer_St : Status;
      Wake_Result : Kernel.Scheduler.Status;
   begin
      if Replier = null or else Replier_Buf = null then
         Result := Invalid_Task;
         return;
      end if;

      Kernel.Tasks.Lookup_Cap
        (TCB       => Replier.all,
         Cap       => Cap,
         Result    => Cap_Result,
         Out_Entry => Cap_Info);

      if Cap_Result /= Kernel.Capabilities.Ok
        or else Cap_Info.Kind /= Kernel.Capabilities.Reply_Object
      then
         Result := Reply_Missing;
         return;
      end if;

      Caller := To_Thread (Cap_Info.Object);

      if Is_Dead (Caller)
        or else not Kernel.Tasks.Is_Awaiting_Reply (Caller.all)
        or else Cap_Info.Badge /=
                Kernel.Tasks.Reply_Generation (Caller.all)
      then
         --  Badge mismatch (m75): the cap was minted for a dead
         --  caller whose thread slot has since been reused;
         --  replying through it would cross-deliver to the slot's
         --  new owner.
         Kernel.Tasks.Forget_Cap (Replier, Cap, Cap_Result);
         Result := Reply_Missing;
         return;
      end if;

      Caller_Buf := Buffer_Of (Caller);
      if Caller_Buf = null then
         Kernel.Tasks.Forget_Cap (Replier, Cap, Cap_Result);
         Wake_With_Result (Caller, Result_Reply_Gone);
         Result := Reply_Missing;
         return;
      end if;

      --  One-shot: consume the cap, transfer label+words+caps into
      --  the caller's buffer, wake it. Caps travel in replies as of
      --  m75 (every server's reply sites are audited to clear
      --  Message.Caps; libman replies with a minted service-
      --  endpoint cap). The reply cap itself is consumed with
      --  Forget_Cap (raw close, no hooks) — Close_Cap would fire
      --  Fail_Reply_Target and wrongly wake the just-satisfied
      --  caller with Reply_Gone.
      Kernel.Tasks.Forget_Cap (Replier, Cap, Cap_Result);

      Transfer_Message (Replier, Caller, 0, Transfer_St);
      if Transfer_St /= Ok then
         --  Delivery failed (bad/revoked cap in the replier's
         --  buffer): the caller still wakes, with
         --  Result_Transfer_Failed; the reply cap is gone either
         --  way.
         Wake_With_Result (Caller, Result_Transfer_Failed);
         Result := Ok;
         return;
      end if;

      Kernel.Tasks.Set_Awaiting_Reply (Caller.all, False);
      Kernel.Tasks.Set_Saved_Result (Caller.all, Result_Ok);
      Kernel.Scheduler.Wake (Caller, Wake_Result);
      Result := Ok;
   end Reply;

   procedure Write_Notification_Message
     (Receiver : Kernel.Tasks.Thread_Access;
      Bits     : U64)
   is
      Buf : constant Buffer_Message_Access := Buffer_Of (Receiver);
   begin
      if Buf = null then
         return;
      end if;

      Buf.Label := Notification_Label;
      Buf.Words := (others => 0);
      Buf.Words (0) := Bits;
      Buf.Caps := (others => 0);
   end Write_Notification_Message;

   procedure Cancel_Receive (Thread : Kernel.Tasks.Thread_Access) is
      Endpoint_Addr  : System.Address;
      Endpoint_Object : Endpoint_Access;
   begin
      if Thread = null then
         return;
      end if;

      Endpoint_Addr := Kernel.Tasks.Recv_Endpoint (Thread.all);
      if Endpoint_Addr = System.Null_Address then
         return;
      end if;

      Endpoint_Object := To_Endpoint (Endpoint_Addr);
      if Endpoint_Object /= null
        and then Endpoint_Object.Waiting_Receiver = Thread
      then
         Endpoint_Object.Waiting_Receiver := null;
      end if;

      Kernel.Tasks.Set_Recv_Endpoint (Thread.all, System.Null_Address);
   end Cancel_Receive;

   procedure Cleanup_Thread_Cap
     (Thread : Kernel.Tasks.Thread_Access;
      Object : System.Address)
   is
      Endpoint_Object : constant Endpoint_Access := To_Endpoint (Object);
      Scan            : Kernel.Tasks.Thread_Access;
      Previous        : Kernel.Tasks.Thread_Access;
   begin
      if Thread = null or else Endpoint_Object = null then
         return;
      end if;

      if Endpoint_Object.Waiting_Receiver = Thread then
         Endpoint_Object.Waiting_Receiver := null;
      end if;

      Kernel.Tasks.Set_Recv_Endpoint (Thread.all, System.Null_Address);

      --  Unlink the thread from the caller queue if present.
      Previous := null;
      Scan := Endpoint_Object.Queue_Head;
      while Scan /= null loop
         if Scan = Thread then
            if Previous = null then
               Endpoint_Object.Queue_Head :=
                 Kernel.Tasks.Endpoint_Queue_Next (Scan.all);
            else
               Kernel.Tasks.Set_Endpoint_Queue_Next
                 (Previous.all,
                  Kernel.Tasks.Endpoint_Queue_Next (Scan.all));
            end if;

            if Endpoint_Object.Queue_Tail = Thread then
               Endpoint_Object.Queue_Tail := Previous;
            end if;

            Kernel.Tasks.Set_Endpoint_Queue_Next (Thread.all, null);
            Kernel.Tasks.Set_Queued_On_EP
              (Thread.all, System.Null_Address);
            exit;
         end if;

         Previous := Scan;
         Scan := Kernel.Tasks.Endpoint_Queue_Next (Scan.all);
      end loop;
   end Cleanup_Thread_Cap;
end Kernel.IPC;
