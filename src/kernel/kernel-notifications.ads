with Interfaces;
with System;
with Kernel.Capabilities;
with Kernel.Objects;
with Kernel.Tasks;

--  Notification objects (docs/IPC.md): a capability-ownable word of
--  pending signal bits with an optional bound thread. Signaling ORs
--  bits in; waiting consumes them. A thread binds at most one
--  notification to itself (ntfn_bind_thread): IPC_Recv then checks
--  it before blocking, and a signal arriving while the thread is
--  blocked in Receive wakes it with a synthetic message
--  (Label = Notification_Label, word 0 = bits) so a server can wait
--  on its endpoint and its IRQ notification at once. IRQ lines bind
--  a notification (irq_bind_ntfn) that the interrupt path signals
--  with a badge.

package Kernel.Notifications is
   subtype U64 is Interfaces.Unsigned_64;

   --  Label of the synthetic message IPC_Recv delivers for pending
   --  notification bits. Userspace protocols use small op codes;
   --  U64'Last is kernel-reserved.
   Notification_Label : constant U64 := U64'Last;

   Max_Notifications : constant := 16;

   type Status is
     (Ok,
      No_Slot,
      Already_Bound);

   --  Rights granted to the creator of a notification object.
   --  Wait = ntfn_wait, Write = ntfn_signal (writing bits into the
   --  object), Manage = ntfn_bind_thread. Transfer: a signaler cap
   --  must travel in messages (window protocol v3 pushes a
   --  Write+Transfer mint to the event producer).
   Notification_Full_Rights : constant Kernel.Capabilities.Rights :=
     (Read     => False,
      Write    => True,
      Execute  => False,
      Map      => False,
      Send     => False,
      Receive  => False,
      Wait     => True,
      Ack      => False,
      Transfer => True,
      Manage   => True);

   --  Allocate a zeroed notification from the static slab. On Ok the
   --  object has refcount 0; the caller inserts a cap (which
   --  retains it) or Discards it.
   procedure Create
     (Result : out Status;
      Object : out System.Address);

   --  Return an unreferenced (refcount 0) object to the slab.
   procedure Discard (Object : System.Address);

   --  Refcount operations (cap-count convention, as Kernel.IPC).
   procedure Retain (Object : System.Address);
   function Release (Object : System.Address) return Boolean;

   --  Fetch pending bits, clearing them. 0 = nothing pending.
   function Take (Object : System.Address) return U64;

   --  OR Bits into the pending word. If a thread is bound and
   --  blocked on this notification (ntfn_wait) it wakes with the
   --  consumed bits; if it is blocked in Receive, the endpoint wait
   --  is cancelled and a synthetic message is delivered instead.
   --  Otherwise the bits stay pending for the next wait/recv.
   procedure Signal (Object : System.Address; Bits : U64);

   --  Bind Thread to this notification (one binding per object and
   --  per thread; Already_Bound on conflict). The cap-close hook
   --  below clears both sides.
   procedure Bind_Thread
     (Object : System.Address;
      Thread : Kernel.Tasks.Thread_Access;
      Result : out Status);

   --  Cap-close hook. Unbind = True (thread teardown only): clears
   --  the thread binding on both sides. Unbind = False (ordinary
   --  cap_delete on a live thread): no-op — closing ONE cap to the
   --  object (e.g. a minted copy after a transfer) must not tear
   --  down the binding, which is thread<->object, not cap<->object.
   procedure Cleanup_Thread_Cap
     (Thread : Kernel.Tasks.Thread_Access;
      Object : System.Address;
      Unbind : Boolean);

private
   type Notification is record
      Header       : Kernel.Objects.Object_Header;
      Bits         : U64;
      Bound_Thread : Kernel.Tasks.Thread_Access;
      In_Use       : Boolean;
   end record;
end Kernel.Notifications;
