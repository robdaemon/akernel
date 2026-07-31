with Ada.Unchecked_Conversion;
with Kernel.Notifications;
with Kernel.Scheduler;

package body Kernel.Interrupts is
   use type Kernel.Objects.IRQ_Line_Access;
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;
   use type System.Address;

   Max_Sources : constant := 1024;

   type IRQ_Array is array (Natural range 0 .. Max_Sources - 1)
     of Kernel.Objects.IRQ_Line_Access;

   Lines : IRQ_Array;

   function To_IRQ_Line is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Kernel.Objects.IRQ_Line_Access);

   procedure Initialize is
   begin
      for I in Lines'Range loop
         Lines (I) := null;
      end loop;
   end Initialize;

   procedure Cleanup_Thread_Cap
     (Thread : Kernel.Tasks.Thread_Access;
      Object : System.Address)
   is
      Line : constant Kernel.Objects.IRQ_Line_Access := To_IRQ_Line (Object);
   begin
      if Thread = null or else Line = null then
         return;
      end if;

      if Line.Waiter = Thread then
         Line.Waiter := null;
      end if;
   end Cleanup_Thread_Cap;

   procedure Register
     (Line   : not null Kernel.Objects.IRQ_Line_Access;
      Result : out Status)
   is
      Index : constant Natural := Natural (Line.Source);
   begin
      if Index >= Max_Sources then
         Result := Invalid_IRQ;
      elsif Lines (Index) /= null then
         Result := Already_Registered;
      else
         Line.Pending := False;
         Line.In_Flight := False;
         Line.Waiter := null;
         Line.Ntfn := System.Null_Address;
         Line.Ntfn_Badge := 0;
         Lines (Index) := Line;
         Result := Ok;
      end if;
   end Register;

   procedure Deliver
     (Source  : U64;
      Claimed : out Boolean)
   is
      Index : constant Natural := Natural (Source);
      Wake_Result : Kernel.Scheduler.Status;
   begin
      Claimed := False;

      if Index >= Max_Sources or else Lines (Index) = null then
         return;
      end if;

      Lines (Index).Pending := True;
      Lines (Index).In_Flight := True;

      if Lines (Index).Ntfn /= System.Null_Address then
         Kernel.Notifications.Signal
           (Lines (Index).Ntfn, Lines (Index).Ntfn_Badge);
      end if;

      if Lines (Index).Waiter /= null then
         Kernel.Scheduler.Wake (Lines (Index).Waiter, Wake_Result);
         Lines (Index).Waiter := null;
      end if;

      Claimed := True;
   end Deliver;

   procedure Bind_Notification
     (Line   : not null Kernel.Objects.IRQ_Line_Access;
      Ntfn   : System.Address;
      Badge  : U64)
   is
   begin
      Line.Ntfn := Ntfn;
      Line.Ntfn_Badge := Badge;
   end Bind_Notification;

   procedure Wait
     (Line   : not null Kernel.Objects.IRQ_Line_Access;
      Waiter : Kernel.Tasks.Thread_Access;
      Result : out Status)
   is
   begin
      if Waiter = null then
         Result := Invalid_IRQ;
         return;
      end if;

      if Line.Waiter /= null
        and then Kernel.Tasks.State (Line.Waiter.all) = Kernel.Tasks.Dead
      then
         Line.Waiter := null;
      end if;

      if Line.Pending and then Line.In_Flight then
         Result := Ok;
         return;
      end if;

      if Line.In_Flight and then not Line.Pending then
         Result := Would_Block;
         return;
      end if;

      if Line.Waiter /= null and then Line.Waiter /= Waiter then
         Result := Already_Waiting;
         return;
      end if;

      if Kernel.Tasks.State (Waiter.all) = Kernel.Tasks.Dead then
         Result := Invalid_IRQ;
         return;
      end if;

      Line.Pending := False;
      Line.Waiter := Waiter;
      Result := Would_Block;
   end Wait;

   procedure Ack
     (Line            : not null Kernel.Objects.IRQ_Line_Access;
      Result          : out Status;
      Complete_Source : out U64)
   is
   begin
      Complete_Source := Line.Source;

      if not Line.In_Flight then
         Line.Pending := False;
         Line.Waiter := null;
         Result := Would_Block;
         return;
      end if;

      Line.Pending := False;
      Line.In_Flight := False;
      Line.Waiter := null;
      Result := Ok;
   end Ack;
end Kernel.Interrupts;
