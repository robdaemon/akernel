with Kernel.Scheduler;

package body Kernel.Interrupts is
   use type Kernel.Objects.IRQ_Line_Access;
   use type Kernel.Tasks.Task_Access;

   Max_Sources : constant := 1024;

   type IRQ_Array is array (Natural range 0 .. Max_Sources - 1)
     of Kernel.Objects.IRQ_Line_Access;

   Lines : IRQ_Array;

   procedure Initialize is
   begin
      for I in Lines'Range loop
         Lines (I) := null;
      end loop;
   end Initialize;

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
         Lines (Index) := Line;
         Result := Ok;
      end if;
   end Register;

   procedure Deliver
     (Source  : U64;
      Claimed : out Boolean)
   is
      Index : constant Natural := Natural (Source);
   begin
      Claimed := False;

      if Index >= Max_Sources or else Lines (Index) = null then
         return;
      end if;

      Lines (Index).Pending := True;
      Lines (Index).In_Flight := True;
      if Lines (Index).Waiter /= null then
         declare
            Wake_Result : Kernel.Scheduler.Status;
         begin
            Kernel.Scheduler.Wake (Lines (Index).Waiter, Wake_Result);
            Lines (Index).Waiter := null;
         end;
      end if;
      Claimed := True;
   end Deliver;

   procedure Wait
     (Line   : not null Kernel.Objects.IRQ_Line_Access;
      Waiter : Kernel.Tasks.Task_Access;
      Result : out Status)
   is
   begin
      if Line.Pending and then Line.In_Flight then
         Result := Ok;
      else
         if not Line.In_Flight then
            Line.Pending := False;
         end if;
         Line.Waiter := Waiter;
         Result := Would_Block;
      end if;
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
         Result := Ok;
         return;
      end if;

      Line.Pending := False;
      Line.In_Flight := False;
      Line.Waiter := null;
      Result := Ok;
   end Ack;
end Kernel.Interrupts;
