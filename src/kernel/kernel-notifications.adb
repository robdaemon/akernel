with Ada.Unchecked_Conversion;
with Arch;
with Kernel.IPC;
with Kernel.Physical_Memory;
with Kernel.Scheduler;
with System.Storage_Elements;

package body Kernel.Notifications is
   use type Kernel.Objects.Refcount;
   use type Kernel.Physical_Memory.Status;
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;
   use type System.Address;
   use type U64;
   use System.Storage_Elements;

   type Notification_Access is access all Notification;

   function To_Notification
     (Addr : System.Address) return Notification_Access;

   ------------------------------------------------------------------
   --  Frame slab (M80c, Kernel.IPC's Grow_Pool template)
   ------------------------------------------------------------------

   --  PMM frames carved into 16-byte-rounded slots on an intrusive
   --  free list, grown on demand; frames are never returned
   --  (high-water slab), so object addresses are stable for the
   --  pool's life.  The FIRST slot of each frame never enters the
   --  free list: its Next_Free doubles as the frame-list link the
   --  membership walk below follows (Slot_Of was the only
   --  address->index decode over a static pool array; multi-frame
   --  slabs reimplement it as a frame-range + alignment walk).
   Slot_Bytes : constant Storage_Count :=
     Storage_Count ((Notification'Size + 127) / 128 * 16);
   Slots_Per_Frame : constant Natural :=
     Natural (Kernel.Physical_Memory.Page_Size) / Natural (Slot_Bytes);

   Frame_Head : System.Address := System.Null_Address;
   Free_Head  : System.Address := System.Null_Address;

   function To_Notification
     (Addr : System.Address) return Notification_Access
   is
      function Convert is new Ada.Unchecked_Conversion
        (System.Address, Notification_Access);
   begin
      return Convert (Addr);
   end To_Notification;

   procedure Free_Notification (Object : System.Address) is
      Slot : constant Notification_Access := To_Notification (Object);
   begin
      Slot.In_Use := False;
      Slot.Waiting := null;
      Slot.Next_Free := Free_Head;
      Free_Head := Object;
   end Free_Notification;

   procedure Grow_Pool (Result : out Status) is
      PMM_Result : Kernel.Physical_Memory.Status;
      Frame_PA   : Kernel.Capabilities.U64;
      Base       : System.Address;
      Header     : Notification_Access;
   begin
      Kernel.Physical_Memory.Allocate_Frame (PMM_Result, Frame_PA);

      if PMM_Result /= Kernel.Physical_Memory.Ok then
         Result := No_Slot;
         return;
      end if;

      Base := System'To_Address
        (Integer_Address (Arch.Phys_To_Virt (Frame_PA)));

      --  Slot 0 is the frame header; slots 1.. are notifications.
      Header := To_Notification (Base);
      Header.Next_Free := Frame_Head;
      Frame_Head := Base;

      for Slot in 1 .. Slots_Per_Frame - 1 loop
         Free_Notification (Base + Storage_Offset (Slot) * Slot_Bytes);
      end loop;

      Result := Ok;
   end Grow_Pool;

   --  Validated pool membership: the notification at Object when
   --  the address names a slot in some slab frame, null otherwise
   --  (never trusted: caps only reference objects the kernel itself
   --  handed out; this is the defensive check).
   function Slot_Access
     (Object : System.Address) return Notification_Access
   is
      Frame : System.Address := Frame_Head;
      Diff  : Integer_Address;
   begin
      --  Integer_Address is modular in this RTS: a negative Diff
      --  wraps huge, so the range check alone rejects it (the
      --  static-pool Slot_Of relied on the same trick).
      while Frame /= System.Null_Address loop
         Diff := To_Integer (Object)
                 - To_Integer (Frame + Slot_Bytes);
         if Diff mod Integer_Address (Slot_Bytes) = 0
           and then Diff < Integer_Address
             (Kernel.Physical_Memory.Page_Size - U64 (Slot_Bytes))
         then
            return To_Notification (Object);
         end if;
         Frame := To_Notification (Frame).Next_Free;
      end loop;
      return null;
   end Slot_Access;

   procedure Create
     (Result : out Status;
      Object : out System.Address)
   is
      Slot : Notification_Access;
   begin
      Object := System.Null_Address;

      if Free_Head = System.Null_Address then
         Grow_Pool (Result);
         if Result /= Ok then
            return;
         end if;
      end if;

      Slot := To_Notification (Free_Head);
      Free_Head := Slot.Next_Free;
      Slot.Next_Free := System.Null_Address;
      Slot.In_Use := True;
      Slot.Header.Count := 0;
      Slot.Bits := 0;
      Slot.Bound_Thread := null;
      Slot.Waiting := null;
      Object := Slot.all'Address;
      Result := Ok;
   end Create;

   procedure Discard (Object : System.Address) is
      Slot : constant Notification_Access := Slot_Access (Object);
   begin
      if Slot /= null then
         Free_Notification (Object);
      end if;
   end Discard;

   procedure Retain (Object : System.Address) is
      Slot : constant Notification_Access := Slot_Access (Object);
   begin
      if Slot /= null then
         Slot.Header.Count := Slot.Header.Count + 1;
      end if;
   end Retain;

   function Release (Object : System.Address) return Boolean is
      Slot : constant Notification_Access := Slot_Access (Object);
      Wake : Kernel.Scheduler.Status;
   begin
      if Slot = null then
         return False;
      end if;

      if Slot.Header.Count > 0 then
         Slot.Header.Count := Slot.Header.Count - 1;
      end if;

      if Slot.Header.Count = 0 then
         Slot.Bound_Thread := null;
         Slot.Bits := 0;
         --  Never strand a blocked waiter: the object is gone, so
         --  wake it with the failure result (Syscall_Failed).
         if Slot.Waiting /= null then
            Kernel.Tasks.Set_Saved_Result
              (Slot.Waiting.all, U64'Last);
            Kernel.Scheduler.Wake (Slot.Waiting, Wake);
         end if;
         Free_Notification (Object);
         return True;
      end if;

      return False;
   end Release;

   function Take (Object : System.Address) return U64 is
      Slot : constant Notification_Access := Slot_Access (Object);
      Bits : U64 := 0;
   begin
      if Slot /= null then
         Bits := Slot.Bits;
         Slot.Bits := 0;
      end if;
      return Bits;
   end Take;

   procedure Signal (Object : System.Address; Bits : U64) is
      Slot   : constant Notification_Access := Slot_Access (Object);
      Thread : Kernel.Tasks.Thread_Access;
      Wake   : Kernel.Scheduler.Status;
   begin
      if Slot = null then
         return;
      end if;

      Slot.Bits := Slot.Bits or Bits;

      --  A blocked ntfn_wait waiter comes first: it is explicitly
      --  parked on THIS object, bound or not.
      Thread := Slot.Waiting;
      if Thread /= null then
         Slot.Waiting := null;
         Kernel.Tasks.Set_Saved_Result (Thread.all, Take (Object));
         Kernel.Scheduler.Wake (Thread, Wake);
         return;
      end if;

      Thread := Slot.Bound_Thread;

      if Thread = null then
         return;
      end if;

      if Kernel.Tasks.State (Thread.all) = Kernel.Tasks.Blocked_Notification
      then
         Kernel.Tasks.Set_Saved_Result (Thread.all, Take (Object));
         Kernel.Scheduler.Wake (Thread, Wake);

      elsif Kernel.Tasks.State (Thread.all) = Kernel.Tasks.Blocked_Receive
      then
         --  The thread is waiting on an endpoint: cancel that wait
         --  and deliver the bits as a synthetic message so a server
         --  multiplexes endpoint traffic and IRQ notifications on
         --  one IPC_Recv.
         Kernel.IPC.Cancel_Receive (Thread);
         Kernel.IPC.Write_Notification_Message
           (Thread, Take (Object));
         Kernel.Tasks.Set_Saved_Result
           (Thread.all, Kernel.IPC.Result_Ok);
         Kernel.Scheduler.Wake (Thread, Wake);
      end if;
   end Signal;

   procedure Record_Waiter
     (Object : System.Address;
      Thread : Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
      Slot : constant Notification_Access := Slot_Access (Object);
   begin
      if Slot = null or else Thread = null then
         Result := No_Slot;
         return;
      end if;

      if Slot.Waiting /= null
        and then Slot.Waiting /= Thread
      then
         Result := Already_Waiting;
         return;
      end if;

      Slot.Waiting := Thread;
      Result := Ok;
   end Record_Waiter;

   procedure Clear_Waiter
     (Object : System.Address;
      Thread : Kernel.Tasks.Thread_Access)
   is
      Slot : constant Notification_Access := Slot_Access (Object);
   begin
      if Slot /= null and then Slot.Waiting = Thread then
         Slot.Waiting := null;
      end if;
   end Clear_Waiter;

   procedure Bind_Thread
     (Object : System.Address;
      Thread : Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
      Slot : constant Notification_Access := Slot_Access (Object);
   begin
      if Slot = null or else Thread = null then
         Result := No_Slot;
         return;
      end if;

      if Slot.Bound_Thread /= null
        or else Kernel.Tasks.Bound_Ntfn (Thread.all) /= System.Null_Address
      then
         Result := Already_Bound;
         return;
      end if;

      Slot.Bound_Thread := Thread;
      Kernel.Tasks.Set_Bound_Ntfn (Thread.all, Object);
      Result := Ok;
   end Bind_Thread;

   procedure Cleanup_Thread_Cap
     (Thread : Kernel.Tasks.Thread_Access;
      Object : System.Address;
      Unbind : Boolean)
   is
      Slot : constant Notification_Access := Slot_Access (Object);
   begin
      if not Unbind then
         return;
      end if;
      if Slot /= null and then Slot.Bound_Thread = Thread then
         Slot.Bound_Thread := null;
      end if;
      if Slot /= null and then Slot.Waiting = Thread then
         Slot.Waiting := null;
      end if;

      if Thread /= null
        and then Kernel.Tasks.Bound_Ntfn (Thread.all) = Object
      then
         Kernel.Tasks.Set_Bound_Ntfn (Thread.all, System.Null_Address);
      end if;
   end Cleanup_Thread_Cap;

   procedure Cleanup_Thread (Thread : Kernel.Tasks.Thread_Access) is
      Bound : System.Address;
      Slot  : Notification_Access;
      Frame : System.Address;
   begin
      if Thread = null then
         return;
      end if;

      Bound := Kernel.Tasks.Bound_Ntfn (Thread.all);
      if Bound /= System.Null_Address then
         Slot := Slot_Access (Bound);
         if Slot /= null and then Slot.Bound_Thread = Thread then
            Slot.Bound_Thread := null;
         end if;
         Kernel.Tasks.Set_Bound_Ntfn (Thread.all, System.Null_Address);
      end if;

      --  A blocked ntfn_wait waiter is registered in exactly one
      --  slot (Record_Waiter pairs with the Blocked_Notification
      --  state under the kernel lock), so the scan is gated on it.
      if Kernel.Tasks.State (Thread.all) =
           Kernel.Tasks.Blocked_Notification
      then
         Frame := Frame_Head;
         while Frame /= System.Null_Address loop
            for I in 1 .. Slots_Per_Frame - 1 loop
               Slot := To_Notification
                 (Frame + Storage_Offset (I) * Slot_Bytes);
               if Slot.In_Use and then Slot.Waiting = Thread then
                  Slot.Waiting := null;
               end if;
            end loop;
            Frame := To_Notification (Frame).Next_Free;
         end loop;
      end if;
   end Cleanup_Thread;
end Kernel.Notifications;
