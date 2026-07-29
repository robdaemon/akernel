with Interfaces;
with Kernel.Capabilities;
with Kernel.Tasks;

package Kernel.Objects is
   subtype U64 is Interfaces.Unsigned_64;

   type MMIO_Region is record
      Physical_Base : U64;
      Length        : U64;
   end record;

   type IRQ_Line is record
      Source    : U64;
      Pending   : Boolean;
      In_Flight : Boolean;
      Waiter    : Kernel.Tasks.Thread_Access;
   end record;

   type IRQ_Line_Access is access all IRQ_Line;

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
   procedure Cleanup_Thread_Cap_Object
     (Thread : Kernel.Tasks.Thread_Access;
      Cap    : Kernel.Capabilities.Cap_Entry);
end Kernel.Objects;
