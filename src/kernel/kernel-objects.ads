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

   procedure Cleanup_Thread_Cap_Object
     (Thread : Kernel.Tasks.Thread_Access;
      Cap    : Kernel.Capabilities.Cap_Entry);
end Kernel.Objects;
