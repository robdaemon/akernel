with Interfaces;
with System;
with Kernel.Capabilities;
with Kernel.Tasks;

package Kernel.Objects is
   subtype U64 is Interfaces.Unsigned_64;

   type MMIO_Region is record
      Physical_Base : U64;
      Length        : U64;
   end record;

   type IRQ_Line;
   type IRQ_Line_Access is access all IRQ_Line;

   type IRQ_Line is record
      Source    : U64;
      Pending   : Boolean;
      In_Flight : Boolean;
      Waiter    : Kernel.Tasks.Thread_Access;
      --  Notification signaled (with badge) when the line fires;
      --  Null_Address = none bound (irq_bind_ntfn syscall).
      Ntfn       : System.Address;
      Ntfn_Badge : U64;
      --  Shared-IRQ chain: PCI INTx lines are swizzled onto only
      --  four PLIC sources ((dev + pin - 1) mod 4), so several
      --  devices legitimately share one source. Lines (source)
      --  heads a chain; Deliver walks it and pokes every line
      --  (each driver reads its own device ISR to claim the
      --  event; level triggering re-delivers while any device
      --  keeps the line asserted).
      Next       : IRQ_Line_Access := null;
   end record;

   --  Boot file: a slice of the initrd image (physmap VA + length).
   --  Pinned statics: one per initrd file, created at boot by
   --  Kernel.Boot_Files.Enumerate, never destroyed. Consumed by the
   --  spawn image-cap path and the cap-based boot byte API.
   type Boot_File is record
      Base   : U64;
      Length : U64;
   end record;

   --  Refcounting: dynamically-owned shared objects (endpoints, later
   --  memory objects) embed Object_Header as their first component.
   --  The kind-owning package implements Retain/Release; this package
   --  dispatches by cap kind. Pinned objects (Count = Pinned_Refcount,
   --  and whole pinned-by-kind static objects such as MMIO_Region and
   --  IRQ_Line) are never destroyed.

   type Refcount is new Natural;

   Pinned_Refcount : constant Refcount := Refcount'Last;

   type Object_Header is record
      Count : Refcount;
   end record;

   --  Increment the object's refcount if the cap kind is refcounted.
   --  No-op for pinned kinds and invalid caps. Called by cap-insert
   --  wrappers after a successful insert/duplicate.
   procedure Retain_Cap (Cap : Kernel.Capabilities.Cap_Entry);

   --  Decrement-and-maybe-destroy dispatcher: runs kind-specific
   --  thread-waiter cleanup, then releases one object reference for
   --  refcounted kinds, running the object finalizer when the last
   --  reference drops. Called on cap close, thread exit, and reap.
   --  Thread_Dying must be True only when the close is part of the
   --  thread's own teardown (Discard_Slot): thread-lifetime hooks
   --  (e.g. the notification thread binding) must not fire when a
   --  live thread merely cap_deletes one of several caps to the
   --  same object.
   procedure Cleanup_Thread_Cap_Object
     (Thread       : Kernel.Tasks.Thread_Access;
      Cap          : Kernel.Capabilities.Cap_Entry;
      Thread_Dying : Boolean := False);
end Kernel.Objects;
