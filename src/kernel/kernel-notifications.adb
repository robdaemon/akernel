with Kernel.IPC;
with Kernel.Scheduler;
with System.Storage_Elements;

package body Kernel.Notifications is
   use type Kernel.Objects.Refcount;
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;
   use type System.Address;
   use type U64;
   use System.Storage_Elements;

   Pool : array (1 .. Max_Notifications) of Notification;

   --  Pool slot index for an object address, 0 when the address is
   --  not a pool slot (never trusted: caps only reference objects
   --  the kernel itself handed out).
   function Slot_Of (Object : System.Address) return Natural is
      Base : constant System.Address := Pool (Pool'First)'Address;
      Diff : constant Integer_Address :=
        To_Integer (Object) - To_Integer (Base);
   begin
      if Diff < 0
        or else Diff mod (Notification'Max_Size_In_Storage_Elements) /= 0
      then
         return 0;
      end if;

      declare
         Index : constant Natural :=
           Natural (Diff / Notification'Max_Size_In_Storage_Elements) + 1;
      begin
         if Index not in Pool'Range then
            return 0;
         end if;
         return Index;
      end;
   end Slot_Of;

   procedure Create
     (Result : out Status;
      Object : out System.Address)
   is
   begin
      Object := System.Null_Address;

      for I in Pool'Range loop
         if not Pool (I).In_Use then
            Pool (I).In_Use := True;
            Pool (I).Header.Count := 0;
            Pool (I).Bits := 0;
            Pool (I).Bound_Thread := null;
            Object := Pool (I)'Address;
            Result := Ok;
            return;
         end if;
      end loop;

      Result := No_Slot;
   end Create;

   procedure Discard (Object : System.Address) is
      Slot : constant Natural := Slot_Of (Object);
   begin
      if Slot /= 0 then
         Pool (Slot).In_Use := False;
      end if;
   end Discard;

   procedure Retain (Object : System.Address) is
      Slot : constant Natural := Slot_Of (Object);
   begin
      if Slot /= 0 then
         Pool (Slot).Header.Count := Pool (Slot).Header.Count + 1;
      end if;
   end Retain;

   function Release (Object : System.Address) return Boolean is
      Slot : constant Natural := Slot_Of (Object);
   begin
      if Slot = 0 then
         return False;
      end if;

      if Pool (Slot).Header.Count > 0 then
         Pool (Slot).Header.Count := Pool (Slot).Header.Count - 1;
      end if;

      if Pool (Slot).Header.Count = 0 then
         Pool (Slot).In_Use := False;
         Pool (Slot).Bound_Thread := null;
         Pool (Slot).Bits := 0;
         return True;
      end if;

      return False;
   end Release;

   function Take (Object : System.Address) return U64 is
      Slot  : constant Natural := Slot_Of (Object);
      Bits  : U64 := 0;
   begin
      if Slot /= 0 then
         Bits := Pool (Slot).Bits;
         Pool (Slot).Bits := 0;
      end if;
      return Bits;
   end Take;

   procedure Signal (Object : System.Address; Bits : U64) is
      Slot   : constant Natural := Slot_Of (Object);
      Thread : Kernel.Tasks.Thread_Access;
      Wake   : Kernel.Scheduler.Status;
   begin
      if Slot = 0 then
         return;
      end if;

      Pool (Slot).Bits := Pool (Slot).Bits or Bits;
      Thread := Pool (Slot).Bound_Thread;

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

   procedure Bind_Thread
     (Object : System.Address;
      Thread : Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
      Slot : constant Natural := Slot_Of (Object);
   begin
      if Slot = 0 or else Thread = null then
         Result := No_Slot;
         return;
      end if;

      if Pool (Slot).Bound_Thread /= null
        or else Kernel.Tasks.Bound_Ntfn (Thread.all) /= System.Null_Address
      then
         Result := Already_Bound;
         return;
      end if;

      Pool (Slot).Bound_Thread := Thread;
      Kernel.Tasks.Set_Bound_Ntfn (Thread.all, Object);
      Result := Ok;
   end Bind_Thread;

   procedure Cleanup_Thread_Cap
     (Thread : Kernel.Tasks.Thread_Access;
      Object : System.Address;
      Unbind : Boolean)
   is
      Slot : constant Natural := Slot_Of (Object);
   begin
      if not Unbind then
         return;
      end if;
      if Slot /= 0 and then Pool (Slot).Bound_Thread = Thread then
         Pool (Slot).Bound_Thread := null;
      end if;

      if Thread /= null
        and then Kernel.Tasks.Bound_Ntfn (Thread.all) = Object
      then
         Kernel.Tasks.Set_Bound_Ntfn (Thread.all, System.Null_Address);
      end if;
   end Cleanup_Thread_Cap;
end Kernel.Notifications;
