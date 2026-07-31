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

   procedure Register
     (Line   : not null Kernel.Objects.IRQ_Line_Access;
      Result : out Status);

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
