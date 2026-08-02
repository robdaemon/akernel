with Kernel.Devices;
with Kernel.IPC;
with Kernel.Interrupts;
with Kernel.Memory;
with Kernel.Notifications;

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
         when Kernel.Capabilities.Memory_Object =>
            Kernel.Memory.Retain (Cap.Object);
         when Kernel.Capabilities.Notification_Object =>
            Kernel.Notifications.Retain (Cap.Object);
         when Kernel.Capabilities.MMIO_Object
            | Kernel.Capabilities.IRQ_Object =>
            Kernel.Devices.Retain (Cap.Object);
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
         when Kernel.Capabilities.Reply_Object =>
            Kernel.IPC.Fail_Reply_Target (Cap.Object);
         when Kernel.Capabilities.IRQ_Object =>
            declare
               Line : constant Kernel.Objects.IRQ_Line_Access :=
                 Kernel.Devices.Line_Of (Cap.Object);
            begin
               if Line /= null then
                  Kernel.Interrupts.Cleanup_Thread_Cap
                    (Thread, Line.all'Address);
               end if;
            end;
            if Kernel.Devices.Release (Cap.Object) then
               null;
            end if;
         when Kernel.Capabilities.MMIO_Object =>
            if Kernel.Devices.Release (Cap.Object) then
               null;
            end if;
         when Kernel.Capabilities.Memory_Object =>
            if Kernel.Memory.Release (Cap.Object) then
               null;
            end if;
         when Kernel.Capabilities.Notification_Object =>
            Kernel.Notifications.Cleanup_Thread_Cap (Thread, Cap.Object);
            if Kernel.Notifications.Release (Cap.Object) then
               null;
            end if;
         when others =>
            null;
      end case;
   end Cleanup_Thread_Cap_Object;
end Kernel.Objects;
