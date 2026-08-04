with Interfaces;
with System;
with Kernel.Objects;
with Kernel.Tasks;

package Kernel.Interrupts is
   subtype U64 is Interfaces.Unsigned_64;

   type Status is
     (Ok,
      Invalid_IRQ,
      Would_Block,
      Already_Registered,
      Already_Waiting);

   procedure Initialize;

   --  Kernel-owned interrupt sources (e.g. the IOMMU fault queue):
   --  Deliver invokes the handler inline instead of waking a
   --  userspace waiter, and the PLIC source is completed
   --  immediately by the board dispatch path.
   type Kernel_Handler is access procedure;

   procedure Register_Kernel
     (Source  : U64;
      Handler : Kernel_Handler);

   function Is_Kernel_Source (Source : U64) return Boolean;

   procedure Register
     (Line   : not null Kernel.Objects.IRQ_Line_Access;
      Result : out Status);

   --  Drop the line from the source registry when its object is
   --  finalized (dynamic IRQ objects, Kernel.Devices).
   procedure Unregister
     (Line : not null Kernel.Objects.IRQ_Line_Access);

   procedure Deliver
     (Source  : U64;
      Claimed : out Boolean);

   procedure Wait
     (Line   : not null Kernel.Objects.IRQ_Line_Access;
      Waiter : Kernel.Tasks.Thread_Access;
      Result : out Status);

   procedure Ack
     (Line            : not null Kernel.Objects.IRQ_Line_Access;
      Result          : out Status;
      Complete_Source : out U64);

   --  Bind a notification object to the line: Deliver signals it
   --  with Badge when the interrupt fires (rebinding allowed).
   procedure Bind_Notification
     (Line   : not null Kernel.Objects.IRQ_Line_Access;
      Ntfn   : System.Address;
      Badge  : U64);

   procedure Cleanup_Thread_Cap
     (Thread : Kernel.Tasks.Thread_Access;
      Object : System.Address);
end Kernel.Interrupts;
