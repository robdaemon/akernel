package body Kernel.Capabilities is
   use type System.Address;
   procedure Initialize (Table : out Cap_Table) is
   begin
      for Cap in Handle loop
         Table.Entries (Cap) := Null_Cap;
      end loop;
   end Initialize;

   function Has_Rights (Have : Rights; Need : Rights) return Boolean is
   begin
      return
        (not Need.Read     or else Have.Read)     and then
        (not Need.Write    or else Have.Write)    and then
        (not Need.Execute  or else Have.Execute)  and then
        (not Need.Map      or else Have.Map)      and then
        (not Need.Send     or else Have.Send)     and then
        (not Need.Receive  or else Have.Receive)  and then
        (not Need.Wait     or else Have.Wait)     and then
        (not Need.Ack      or else Have.Ack)      and then
        (not Need.Transfer or else Have.Transfer) and then
        (not Need.Manage   or else Have.Manage);
   end Has_Rights;

   procedure Insert
     (Table  : in out Cap_Table;
      Kind   : Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : U64;
      Result : out Status;
      Cap    : out Handle)
   is
   begin
      Cap := Invalid_Handle;

      if Kind = Null_Object or else Object = System.Null_Address then
         Result := Invalid_Object;
         return;
      end if;

      for Candidate in Handle'Succ (Invalid_Handle) .. Handle'Last loop
         if not Table.Entries (Candidate).Valid then
            Table.Entries (Candidate) :=
              (Valid  => True,
               Kind   => Kind,
               Object => Object,
               Rights => Rights,
               Badge  => Badge);
            Cap := Candidate;
            Result := Ok;
            return;
         end if;
      end loop;

      Result := Table_Full;
   end Insert;

   procedure Insert_At
     (Table  : in out Cap_Table;
      Cap    : Handle;
      Kind   : Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : U64;
      Result : out Status)
   is
   begin
      if Cap = Invalid_Handle then
         Result := Invalid_Cap;
         return;
      end if;

      if Kind = Null_Object or else Object = System.Null_Address then
         Result := Invalid_Object;
         return;
      end if;

      if Table.Entries (Cap).Valid then
         Result := Slot_Occupied;
         return;
      end if;

      Table.Entries (Cap) :=
        (Valid  => True,
         Kind   => Kind,
         Object => Object,
         Rights => Rights,
         Badge  => Badge);
      Result := Ok;
   end Insert_At;

   procedure Lookup
     (Table     : Cap_Table;
      Cap       : Handle;
      Result    : out Status;
      Out_Entry : out Cap_Entry)
   is
   begin
      if Cap = Invalid_Handle or else not Table.Entries (Cap).Valid then
         Out_Entry := Null_Cap;
         Result := Invalid_Cap;
         return;
      end if;

      Out_Entry := Table.Entries (Cap);
      Result := Ok;
   end Lookup;

   procedure Duplicate
     (Table     : in out Cap_Table;
      Source    : Handle;
      New_Rights : Kernel.Capabilities.Rights;
      New_Badge  : U64;
      Result    : out Status;
      New_Cap   : out Handle)
   is
      Source_Entry : Cap_Entry;
   begin
      Lookup (Table, Source, Result, Source_Entry);
      New_Cap := Invalid_Handle;

      if Result /= Ok then
         return;
      end if;

      if not Source_Entry.Rights.Transfer
        or else not Has_Rights (Source_Entry.Rights, New_Rights)
      then
         Result := Rights_Denied;
         return;
      end if;

      Insert
        (Table  => Table,
         Kind   => Source_Entry.Kind,
         Object => Source_Entry.Object,
         Rights => New_Rights,
         Badge  => New_Badge,
         Result => Result,
         Cap    => New_Cap);
   end Duplicate;

   procedure Close
     (Table  : in out Cap_Table;
      Cap    : Handle;
      Result : out Status)
   is
   begin
      if Cap = Invalid_Handle or else not Table.Entries (Cap).Valid then
         Result := Invalid_Cap;
         return;
      end if;

      Table.Entries (Cap) := Null_Cap;
      Result := Ok;
   end Close;

   procedure Reset (Table : out Cap_Table) is
   begin
      Initialize (Table);
   end Reset;

   function Used_Count (Table : Cap_Table) return Natural is
      Count : Natural := 0;
   begin
      for Cap in Handle loop
         if Table.Entries (Cap).Valid then
            Count := Count + 1;
         end if;
      end loop;

      return Count;
   end Used_Count;
end Kernel.Capabilities;
