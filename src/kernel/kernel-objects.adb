with Kernel.IPC;
with Kernel.Interrupts;

package body Kernel.Objects is
   use type Kernel.Tasks.Thread_Access;

   procedure Retain_Cap (Cap : Kernel.Capabilities.Cap_Entry) is
      use type Kernel.Capabilities.Object_Kind;
   begin
      if not Cap.Valid then
         return;
      end if;

      case Cap.Kind is
         when Kernel.Capabilities.Endpoint_Object =>
            Kernel.IPC.Retain (Cap.Object);
         when others =>
            null;
      end case;
   end Retain_Cap;

   procedure Cleanup_Thread_Cap_Object
     (Thread : Kernel.Tasks.Thread_Access;
      Cap    : Kernel.Capabilities.Cap_Entry)
   is
      use type Kernel.Capabilities.Object_Kind;
   begin
      if Thread = null or else not Cap.Valid then
         return;
      end if;

      case Cap.Kind is
         when Kernel.Capabilities.Endpoint_Object =>
            Kernel.IPC.Cleanup_Thread_Cap (Thread, Cap.Object);
            if Kernel.IPC.Release (Cap.Object) then
               null;
            end if;
         when Kernel.Capabilities.IRQ_Object =>
            Kernel.Interrupts.Cleanup_Thread_Cap (Thread, Cap.Object);
         when others =>
            null;
      end case;
   end Cleanup_Thread_Cap_Object;
end Kernel.Objects;
