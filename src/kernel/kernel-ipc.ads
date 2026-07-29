with Interfaces;
with System;
with Kernel.Capabilities;
with Kernel.Objects;
with Kernel.Tasks;

package Kernel.IPC is
   subtype U64 is Interfaces.Unsigned_64;

   Max_Words : constant := 6;
   Max_Caps  : constant := 4;

   type Word_Index is range 0 .. Max_Words - 1;
   type Cap_Index is range 0 .. Max_Caps - 1;

   type Word_Array is array (Word_Index) of U64;
   type Cap_Array is array (Cap_Index) of Kernel.Capabilities.Handle;

   type Message is record
      Label      : U64;
      Words      : Word_Array;
      Word_Count : Natural range 0 .. Max_Words;
      Caps       : Cap_Array;
      Cap_Count  : Natural range 0 .. Max_Caps;
      Badge      : U64;
   end record;

   Empty_Message : constant Message :=
     (Label      => 0,
      Words      => (others => 0),
      Word_Count => 0,
      Caps       => (others => Kernel.Capabilities.Invalid_Handle),
      Cap_Count  => 0,
      Badge      => 0);

   type Status is
     (Ok,
      Invalid_Task,
      Invalid_Cap,
      Wrong_Object,
      Rights_Denied,
      Would_Block,
      Endpoint_Full,
      No_Endpoints);

   --  Rights granted to the creator of a dynamic endpoint.
   Endpoint_Full_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => False,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => True,
      Receive  => True,
      Wait     => False,
      Ack      => False,
      Transfer => True,
      Manage   => True);

   type Endpoint is private;

   --  Pinned => True for kernel-owned static endpoints (never
   --  destroyed); False for dynamically-owned endpoints whose storage
   --  lifetime is governed by the refcount (one reference per cap).
   procedure Initialize (Object : out Endpoint; Pinned : Boolean);

   --  Refcount operations on an endpoint object address. Retain adds
   --  one reference; Release drops one and returns True when the last
   --  reference dropped (object finalized and returned to the pool).
   --  Both are no-ops on pinned endpoints. Refcount convention:
   --  Count = number of caps referencing the object; a fresh dynamic
   --  endpoint starts at 0 and reaches 1 when its first cap inserts.
   procedure Retain (Object : System.Address);
   function Release (Object : System.Address) return Boolean;

   --  Allocate a dynamic endpoint from the kernel pool. On Ok the
   --  object has refcount 0; the caller is expected to insert a cap
   --  (which retains it) or Discard it.
   procedure Create_Endpoint
     (Result : out Status;
      Object : out System.Address);

   --  Return an unreferenced (refcount 0) endpoint to the pool. Only
   --  valid when no cap references the object (create-then-fail
   --  rollback).
   procedure Discard (Object : System.Address);

   procedure Send
     (Sender       : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Payload      : Message;
      Result       : out Status);

   procedure Receive
     (Receiver     : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Result       : out Status;
      Payload      : out Message);

   procedure Cleanup_Thread_Cap
     (Thread : Kernel.Tasks.Thread_Access;
      Object : System.Address);

private
   type Endpoint is record
      Header           : Kernel.Objects.Object_Header;
      Has_Message      : Boolean;
      Pending          : Message;
      Waiting_Sender   : Kernel.Tasks.Thread_Access;
      Sender_Message   : Message;
      Waiting_Receiver : Kernel.Tasks.Thread_Access;
      Next_Free        : System.Address;
   end record;
end Kernel.IPC;
