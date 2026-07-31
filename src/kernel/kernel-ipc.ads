with Interfaces;
with System;
with Kernel.Capabilities;
with Kernel.Objects;
with Kernel.Tasks;

--  Synchronous rendezvous IPC (docs/IPC.md). Messages live in the
--  per-thread IPC buffer page (Kernel.Tasks.IPC_Buffer_VA); transfer
--  is one copy from sender buffer to receiver buffer via the physmap.
--  Callers block in a per-endpoint FIFO queue until a receiver takes
--  their message, then stay blocked until the receiver replies via
--  the one-shot reply cap minted at handle 254.

package Kernel.IPC is
   subtype U64 is Interfaces.Unsigned_64;

   Max_Words : constant := 6;
   Max_Caps  : constant := 4;

   --  Syscall result codes surfaced in user a0.
   Result_Ok              : constant U64 := 0;
   Result_Invalid         : constant U64 := 1;

   --  Label of the synthetic message delivered by Receive when a
   --  thread-bound notification has pending bits (kernel-reserved;
   --  userspace protocols use small op codes). Word 0 carries the
   --  consumed bits.
   Notification_Label : constant U64 := U64'Last;
   Result_Transfer_Failed : constant U64 := 2;
   Result_Endpoint_Gone   : constant U64 := 3;
   Result_Reply_Gone      : constant U64 := 4;

   --  Reserved cap-table handle of the one-shot reply cap (255 is the
   --  process self address-space cap).
   Reply_Cap_Handle : constant Kernel.Capabilities.Handle :=
     Kernel.Capabilities.Handle'Pred (Kernel.Tasks.Address_Space_Cap_Handle);

   type Status is
     (Ok,
      Invalid_Task,
      Invalid_Cap,
      Wrong_Object,
      Rights_Denied,
      Would_Block,
      Transfer_Failed,
      Reply_Missing,
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
   --  reference dropped (object finalized and returned to the slab).
   --  Both are no-ops on pinned endpoints. Refcount convention:
   --  Count = number of caps referencing the object; a fresh dynamic
   --  endpoint starts at 0 and reaches 1 when its first cap inserts.
   procedure Retain (Object : System.Address);
   function Release (Object : System.Address) return Boolean;

   --  Allocate a dynamic endpoint from the kernel slab. On Ok the
   --  object has refcount 0; the caller is expected to insert a cap
   --  (which retains it) or Discard it.
   procedure Create_Endpoint
     (Result : out Status;
      Object : out System.Address);

   --  Return an unreferenced (refcount 0) endpoint to the slab. Only
   --  valid when no cap references the object (create-then-fail
   --  rollback).
   procedure Discard (Object : System.Address);

   --  Blocking rendezvous operations. Would_Block means the calling
   --  thread now blocks (the syscall handler performs the block and
   --  reschedule); any other non-Ok status is an immediate error.
   --
   --  Call: validates the caller's endpoint cap (Send right), then
   --  either transfers directly to a waiting receiver or enqueues the
   --  caller FIFO. The caller stays blocked until a reply arrives or
   --  fails; the waker writes the result code into its saved a0.
   procedure Call
     (Caller       : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Result       : out Status);

   --  Receive: takes the head queued caller's message (transfer +
   --  reply cap mint), or blocks the receiver when the queue is empty.
   procedure Receive
     (Receiver     : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Result       : out Status);

   --  Reply: consumes the one-shot reply cap at Reply_Cap_Handle,
   --  copies label+words into the caller's buffer, wakes it with
   --  Result_Ok.
   procedure Reply
     (Replier : Kernel.Tasks.Thread_Access;
      Result  : out Status);

   --  Notification delivery (thread-bound notifications): write the
   --  synthetic message (Notification_Label + bits in word 0, no
   --  caps) into the receiver's IPC buffer.
   procedure Write_Notification_Message
     (Receiver : Kernel.Tasks.Thread_Access;
      Bits     : U64);

   --  Cancel a pending Receive wait: clear the endpoint's
   --  waiting-receiver slot for Thread (endpoint found via the
   --  TCB's recorded Recv_Endpoint) and forget the recording.
   procedure Cancel_Receive (Thread : Kernel.Tasks.Thread_Access);

   --  Cap-close hook (exit/reap/close): unlinks the thread from the
   --  endpoint's caller queue and clears a waiting-receiver slot.
   procedure Cleanup_Thread_Cap
     (Thread : Kernel.Tasks.Thread_Access;
      Object : System.Address);

   --  Reply-cap-close hook: fails the caller a reply cap points at
   --  (server exited, was reaped, or re-received without replying).
   --  Caller wakes with Result_Reply_Gone.
   procedure Fail_Reply_Target (Caller_Object : System.Address);

private
   type Endpoint is record
      Header           : Kernel.Objects.Object_Header;
      Queue_Head       : Kernel.Tasks.Thread_Access;
      Queue_Tail       : Kernel.Tasks.Thread_Access;
      Waiting_Receiver : Kernel.Tasks.Thread_Access;
      Next_Free        : System.Address;
   end record;
end Kernel.IPC;
