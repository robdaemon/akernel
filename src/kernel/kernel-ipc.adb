with System;
with Ada.Unchecked_Conversion;
with Kernel.Scheduler;

package body Kernel.IPC is
   use type Kernel.Capabilities.Object_Kind;
   use type Kernel.Capabilities.Status;
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

   procedure Initialize (Object : out Endpoint) is
   begin
      Object.Has_Message := False;
      Object.Pending := Empty_Message;
      Object.Waiting_Sender := null;
      Object.Sender_Message := Empty_Message;
      Object.Waiting_Receiver := null;
   end Initialize;

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
