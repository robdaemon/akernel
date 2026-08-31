with Ada.Unchecked_Conversion;
with Kernel.Notifications;
with Kernel.Scheduler;

package body Kernel.Interrupts is
   use type Kernel.Objects.IRQ_Line_Access;
   use type Kernel.Tasks.Thread_Access;
   use type Kernel.Tasks.Thread_State;
   use type System.Address;

   type IRQ_Array is array (Natural range 0 .. Max_Sources - 1)
     of Kernel.Objects.IRQ_Line_Access;

   Lines : IRQ_Array;

   type Kernel_Handler_Array is array (Natural range 0 .. Max_Sources - 1)
     of Kernel_Handler;

   Kernel_Handlers : Kernel_Handler_Array;

   procedure Register_Kernel
     (Source  : U64;
      Handler : Kernel_Handler)
   is
      Index : constant Natural := Natural (Source);
   begin
      if Index < Max_Sources then
         Kernel_Handlers (Index) := Handler;
      end if;
   end Register_Kernel;

   function Is_Kernel_Source (Source : U64) return Boolean is
   begin
      return Natural (Source) < Max_Sources
        and then Kernel_Handlers (Natural (Source)) /= null;
   end Is_Kernel_Source;

   function To_IRQ_Line is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Kernel.Objects.IRQ_Line_Access);

   procedure Initialize is
   begin
      for I in Lines'Range loop
         Lines (I) := null;
         Kernel_Handlers (I) := null;
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

   procedure Cleanup_Thread (Thread : Kernel.Tasks.Thread_Access) is
      Cur : Kernel.Objects.IRQ_Line_Access;
   begin
      --  Line.Waiter is only ever registered together with the
      --  Blocked_IRQ state (Wait + the trap handler's block run
      --  under the kernel lock), so a thread in any other state
      --  cannot be a waiter and the source scan is skipped.
      if Thread = null
        or else Kernel.Tasks.State (Thread.all) /=
                  Kernel.Tasks.Blocked_IRQ
      then
         return;
      end if;

      for I in Lines'Range loop
         Cur := Lines (I);
         while Cur /= null loop
            if Cur.Waiter = Thread then
               Cur.Waiter := null;
            end if;
            Cur := Cur.Next;
         end loop;
      end loop;
   end Cleanup_Thread;

   procedure Register
     (Line   : not null Kernel.Objects.IRQ_Line_Access;
      Result : out Status)
   is
      Index : constant Natural := Natural (Line.Source);
      Cur   : Kernel.Objects.IRQ_Line_Access;
   begin
      if Index >= Max_Sources then
         Result := Invalid_IRQ;
         return;
      end if;

      --  Shared-IRQ chain: duplicate registration of the SAME line
      --  object fails; a different line for an already-claimed
      --  source chains (PCI INTx swizzle shares four PLIC sources
      --  across all slots — the fifth device onward always
      --  collides).
      Cur := Lines (Index);
      while Cur /= null loop
         if Cur = Line then
            Result := Already_Registered;
            return;
         end if;
         Cur := Cur.Next;
      end loop;

      Line.Pending := False;
      Line.In_Flight := False;
      Line.Waiter := null;
      Line.Ntfn := System.Null_Address;
      Line.Ntfn_Badge := 0;
      Line.Next := Lines (Index);
      Lines (Index) := Line;
      Result := Ok;
   end Register;

   procedure Unregister (Line : not null Kernel.Objects.IRQ_Line_Access) is
      Index : constant Natural := Natural (Line.Source);
      Cur   : Kernel.Objects.IRQ_Line_Access;
   begin
      if Index >= Max_Sources then
         return;
      end if;

      if Lines (Index) = Line then
         Lines (Index) := Line.Next;
      else
         Cur := Lines (Index);
         while Cur /= null loop
            if Cur.Next = Line then
               Cur.Next := Line.Next;
               exit;
            end if;
            Cur := Cur.Next;
         end loop;
      end if;
      Line.Next := null;
   end Unregister;

   procedure Deliver
     (Source  : U64;
      Claimed : out Boolean)
   is
      Index : constant Natural := Natural (Source);
      Wake_Result : Kernel.Scheduler.Status;
   begin
      Claimed := False;

      if Index >= Max_Sources then
         return;
      end if;

      if Kernel_Handlers (Index) /= null then
         Kernel_Handlers (Index).all;
         Claimed := True;
         return;
      end if;

      --  Walk the shared-IRQ chain: every line registered for the
      --  source is poked; each driver reads its own device ISR to
      --  claim the event. Level triggering re-delivers while any
      --  device keeps the line asserted, so a spuriously woken
      --  driver (ISR reads 0, acks) cannot mask the real raiser.
      declare
         Cur : Kernel.Objects.IRQ_Line_Access := Lines (Index);
      begin
         while Cur /= null loop
            Cur.Pending := True;
            Cur.In_Flight := True;

            if Cur.Ntfn /= System.Null_Address then
               Kernel.Notifications.Signal (Cur.Ntfn, Cur.Ntfn_Badge);
            end if;

            if Cur.Waiter /= null then
               Kernel.Scheduler.Wake (Cur.Waiter, Wake_Result);
               Cur.Waiter := null;
            end if;

            Claimed := True;
            Cur := Cur.Next;
         end loop;
      end;
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
