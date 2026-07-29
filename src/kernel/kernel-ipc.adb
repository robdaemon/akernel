with Ada.Unchecked_Conversion;
with System.Storage_Elements;
with Arch;
with Kernel.Physical_Memory;
with Kernel.Scheduler;

package body Kernel.IPC is
   use type Kernel.Capabilities.Object_Kind;
   use type Kernel.Capabilities.Status;
   use type Kernel.Physical_Memory.Status;
   use type Kernel.Scheduler.Status;
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;

   type Endpoint_Access is access all Endpoint;

   function To_Endpoint is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Endpoint_Access);

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

   --  Dynamic endpoint storage: PMM-backed slab. Pool grows one
   --  physical frame at a time, limited by RAM rather than a fixed
   --  constant. Freed endpoints recycle through the intrusive free
   --  list (Next_Free valid only while the slot is free). Frames are
   --  never returned to the PMM (high-water mark; per-frame empty
   --  tracking is a possible later refinement).
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
      use type System.Address;
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

      Object.Has_Message := False;
      Object.Pending := Empty_Message;
      Object.Waiting_Sender := null;
      Object.Sender_Message := Empty_Message;
      Object.Waiting_Receiver := null;
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
      Wake_Result     : Kernel.Scheduler.Status;
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

      --  Last reference dropped: wake any remaining waiters (error
      --  status delivery arrives with the call/recv syscalls; no
      --  syscall can block on an endpoint before then), clear all
      --  state, and return the slot to the pool.
      if Endpoint_Object.Waiting_Sender /= null then
         Kernel.Scheduler.Wake
           (Endpoint_Object.Waiting_Sender, Wake_Result);
      end if;

      if Endpoint_Object.Waiting_Receiver /= null then
         Kernel.Scheduler.Wake
           (Endpoint_Object.Waiting_Receiver, Wake_Result);
      end if;

      Endpoint_Object.Has_Message := False;
      Endpoint_Object.Pending := Empty_Message;
      Endpoint_Object.Waiting_Sender := null;
      Endpoint_Object.Sender_Message := Empty_Message;
      Endpoint_Object.Waiting_Receiver := null;
      Free_Endpoint (Endpoint_Object);
      return True;
   end Release;

   procedure Cleanup_Thread_Cap
     (Thread : Kernel.Tasks.Thread_Access;
      Object : System.Address)
   is
      Endpoint_Object : constant Endpoint_Access := To_Endpoint (Object);
   begin
      if Thread = null or else Endpoint_Object = null then
         return;
      end if;

      if Endpoint_Object.Waiting_Sender = Thread then
         Endpoint_Object.Waiting_Sender := null;
         Endpoint_Object.Sender_Message := Empty_Message;
      end if;

      if Endpoint_Object.Waiting_Receiver = Thread then
         Endpoint_Object.Waiting_Receiver := null;
      end if;
   end Cleanup_Thread_Cap;

   function Is_Dead (Thread : Kernel.Tasks.Thread_Access) return Boolean is
   begin
      return Thread = null
        or else Kernel.Tasks.State (Thread.all) = Kernel.Tasks.Dead;
   end Is_Dead;

   procedure Drop_Dead_Waiters (Object : in out Endpoint) is
   begin
      if Object.Waiting_Sender /= null
        and then Is_Dead (Object.Waiting_Sender)
      then
         Object.Waiting_Sender := null;
         Object.Sender_Message := Empty_Message;
      end if;

      if Object.Waiting_Receiver /= null
        and then Is_Dead (Object.Waiting_Receiver)
      then
         Object.Waiting_Receiver := null;
      end if;
   end Drop_Dead_Waiters;

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
      Result := Ok;
   end Resolve_Endpoint;

   procedure Send
     (Sender       : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Payload      : Message;
      Result       : out Status)
   is
      Object           : Endpoint_Access;
      Badge            : U64;
      Message_To_Store : Message := Payload;
      Wake_Result      : Kernel.Scheduler.Status;
   begin
      Resolve_Endpoint
        (Caller       => Sender,
         Endpoint_Cap => Endpoint_Cap,
         Needed       => Send_Right,
         Result       => Result,
         Object       => Object,
         Badge        => Badge);

      if Result /= Ok then
         return;
      end if;

      Message_To_Store.Badge := Badge;
      Drop_Dead_Waiters (Object.all);

      if Object.Waiting_Receiver /= null then
         Object.Pending := Message_To_Store;
         Object.Has_Message := True;
         Kernel.Scheduler.Wake (Object.Waiting_Receiver, Wake_Result);
         Object.Waiting_Receiver := null;

         if Wake_Result = Kernel.Scheduler.Ok then
            Result := Ok;
         else
            Result := Endpoint_Full;
         end if;
         return;
      end if;

      if Object.Has_Message or else Object.Waiting_Sender /= null then
         Result := Endpoint_Full;
         return;
      end if;

      Object.Waiting_Sender := Sender;
      Object.Sender_Message := Message_To_Store;
      Kernel.Tasks.Set_State (Sender.all, Kernel.Tasks.Blocked_Send);
      Result := Would_Block;
   end Send;

   procedure Receive
     (Receiver     : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Result       : out Status;
      Payload      : out Message)
   is
      Object      : Endpoint_Access;
      Badge       : U64;
      Wake_Result : Kernel.Scheduler.Status;
   begin
      Payload := Empty_Message;

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

      Drop_Dead_Waiters (Object.all);

      if Object.Has_Message then
         Payload := Object.Pending;
         Object.Pending := Empty_Message;
         Object.Has_Message := False;
         Result := Ok;
         return;
      end if;

      if Object.Waiting_Sender /= null then
         Payload := Object.Sender_Message;
         Kernel.Scheduler.Wake (Object.Waiting_Sender, Wake_Result);
         Object.Waiting_Sender := null;
         Object.Sender_Message := Empty_Message;

         if Wake_Result = Kernel.Scheduler.Ok then
            Result := Ok;
         else
            Result := Endpoint_Full;
         end if;
         return;
      end if;

      if Object.Waiting_Receiver /= null then
         Result := Endpoint_Full;
         return;
      end if;

      Object.Waiting_Receiver := Receiver;
      Kernel.Tasks.Set_State (Receiver.all, Kernel.Tasks.Blocked_Receive);
      Result := Would_Block;
   end Receive;
end Kernel.IPC;
