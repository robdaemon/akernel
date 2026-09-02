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

   --  Reply caps (milestone 47): each received call mints an
   --  ordinary free-slot cap of Reply_Object kind in the receiver's
   --  table; the handle is delivered to the receiver in a1. A
   --  server thread may hold MANY outstanding reply caps at once
   --  (recv no longer clobbers a fixed slot) and reply in any
   --  order. Server death closes every reply cap and each target
   --  wakes with Reply_Gone (the cap-close hook).
   --  Handle 254 keeps no special meaning any more (255 stays the
   --  process self address-space cap).

   type Status is
     (Ok,
      Invalid_Task,
      Invalid_Cap,
      Wrong_Object,
      Rights_Denied,
      Would_Block,
      Transfer_Failed,
      Endpoint_Gone,
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

   --  Send: like Call, but the rendezvous ends at delivery — no
   --  reply cap is minted and the sender never waits for a reply.
   --  A waiting receiver takes the message immediately and Send
   --  returns Ok; otherwise the message is COPIED into a
   --  kernel-side queued-send slot and Send returns Ok at once
   --  (fire-and-forget). The copy is load-bearing: the sender keeps
   --  running and would otherwise overwrite its live buffer, badge,
   --  and queue links with its next IPC op while still queued
   --  (the M66c/M68 plain-send corruption). A Send whose message
   --  carries caps with no waiting receiver falls back to blocking
   --  (queued copies cannot hold caps); so does a full slot pool.
   --  A receiver that replies to a sent message gets Reply_Missing.
   procedure Send
     (Caller       : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Result       : out Status);

   --  Receive: takes the head queued caller's message (transfer +
   --  reply cap mint), else the head queued fire-and-forget send
   --  copy, or blocks the receiver when both queues are empty. On
   --  Ok with a call (Reply_Wanted) Reply_Handle is the freshly
   --  minted reply cap; a plain send completes at delivery and
   --  Reply_Handle is Invalid_Handle.
   procedure Receive
     (Receiver     : Kernel.Tasks.Thread_Access;
      Endpoint_Cap : Kernel.Capabilities.Handle;
      Result       : out Status;
      Reply_Handle : out Kernel.Capabilities.Handle);

   --  Reply: consumes the reply cap at Cap (Reply_Object kind,
   --  minted by an earlier Receive; badge must match the caller's
   --  thread-slot generation — stale caps from a reused slot fail
   --  Reply_Missing), transfers label+words+caps into the caller's
   --  buffer (m75: caps DO travel in replies), wakes it with
   --  Result_Ok, or Result_Transfer_Failed when a cap in the
   --  replier's buffer cannot be transferred.
   procedure Reply
     (Replier : Kernel.Tasks.Thread_Access;
      Cap     : Kernel.Capabilities.Handle;
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
   --  (server exited, was reaped, or dropped the request with
   --  cap_delete). Caller wakes with Result_Reply_Gone. The cap's
   --  badge must match the caller's thread-slot generation (m75):
   --  a stale cap whose caller's slot was reused fails nothing.
   procedure Fail_Reply_Target
     (Caller_Object : System.Address;
      Badge         : Kernel.Capabilities.U64);

   --  Receiver-teardown hook: permanently fail an endpoint whose
   --  receiving side is dying. Queued callers and a waiting
   --  receiver wake with Result_Endpoint_Gone; later Calls and
   --  Receives fail immediately with Endpoint_Gone instead of
   --  blocking forever on a server that no longer exists (the
   --  orphaned-shell burn: a shell whose terminal closed stayed
   --  blocked in its read call). Idempotent; does not free the
   --  endpoint (Send caps elsewhere keep it referenced).
   procedure Fail_Endpoint (Object : System.Address);

   --  Milestone 41b/Proc:self: when True, an endpoint call whose
   --  cap badge is zero surfaces the caller's process id as the
   --  message badge. This lets a VFS file server learn the real
   --  client identity without breaking other endpoints that use
   --  zero as a legitimate anonymous badge.
   procedure Set_Stamp_Identity (Object : in out Endpoint;
                                 Stamp  : Boolean);
   function Stamp_Identity (Object : Endpoint) return Boolean;

   --  Address-based variant for use from the syscall layer, where
   --  the endpoint object is known only by its system address.
   procedure Set_Stamp_Identity (Object_Address : System.Address;
                                 Stamp          : Boolean);

private
   type Queued_Send_Word_Array is array (0 .. Max_Words - 1) of U64;

   --  Kernel-side copy of a fire-and-forget Send (see Send above).
   --  Lives in a fixed pool in the body; an endpoint chains pending
   --  copies FIFO through Next. No caps: a queued copy cannot hold
   --  a live cap-table reference.
   type Queued_Send;
   type Queued_Send_Access is access all Queued_Send;

   type Queued_Send is record
      Label  : U64;
      Words  : Queued_Send_Word_Array;
      Badge  : U64;
      Next   : Queued_Send_Access;
      In_Use : Boolean;
      Next_Free : Queued_Send_Access;  --  slab free-list link
   end record;

   type Endpoint is record
      Header           : Kernel.Objects.Object_Header;
      Queue_Head       : Kernel.Tasks.Thread_Access;
      Queue_Tail       : Kernel.Tasks.Thread_Access;
      Waiting_Receiver : Kernel.Tasks.Thread_Access;
      Send_Queue_Head  : Queued_Send_Access;
      Send_Queue_Tail  : Queued_Send_Access;
      Failed           : Boolean;
      Stamp_Identity   : Boolean := False;
      Next_Free        : System.Address;
   end record;
end Kernel.IPC;
