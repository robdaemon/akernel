with Ada.Unchecked_Conversion;
with Arch;
with Kernel.Physical_Memory;
with System.Address_To_Access_Conversions;
with System.Storage_Elements;

package body Kernel.Capabilities is
   pragma SPARK_Mode (On);

   use System.Storage_Elements;
   use type System.Address;
   use type Kernel.Physical_Memory.Status;

   function To_Addr is
     new Ada.Unchecked_Conversion (U64, System.Address);

   type Slot_Index is range 0 .. Caps_Per_Page - 1;
   type Page_Entries is array (Slot_Index) of Cap_Entry;

   package Page_Conv is
     new System.Address_To_Access_Conversions (Page_Entries);
   package Word_Conv is
     new System.Address_To_Access_Conversions (U64);

   function Page_At (PA : U64) return Page_Conv.Object_Pointer
   is
      pragma SPARK_Mode (Off);
   begin
      return Page_Conv.To_Pointer (To_Addr (Arch.Phys_To_Virt (PA)));
   end Page_At;

   function Page_No (Cap : Handle) return Page_Index is
     (Page_Index (Cap / Caps_Per_Page));

   function Slot_No (Cap : Handle) return Slot_Index is
     (Slot_Index (Cap mod Caps_Per_Page));

   --  A zeroed frame is a page of Null_Cap entries: Valid = False,
   --  Kind = Null_Object (first literal), Object/Rights/Badge all 0.
   procedure Zero_Page (PA : U64) is
      pragma SPARK_Mode (Off);
      Addr : System.Address := To_Addr (Arch.Phys_To_Virt (PA));
   begin
      for I in 1 .. 4096 / 8 loop
         Word_Conv.To_Pointer (Addr).all := 0;
         Addr := Addr + 8;
      end loop;
   end Zero_Page;

   function Get (Table : Cap_Table; Cap : Handle) return Cap_Entry is
      pragma SPARK_Mode (Off);
      P : constant Page_Index := Page_No (Cap);
   begin
      if Table.Root (P) = 0 then
         return Null_Cap;
      end if;
      return Page_At (Table.Root (P)) (Slot_No (Cap));
   end Get;

   procedure Put
     (Table : Cap_Table; Cap : Handle; New_Entry : Cap_Entry)
   is
      pragma SPARK_Mode (Off);
   begin
      Page_At (Table.Root (Page_No (Cap))) (Slot_No (Cap)) := New_Entry;
   end Put;

   procedure Ensure_Page
     (Table  : in out Cap_Table;
      Page   : Page_Index;
      Result : out Status)
   is
      pragma SPARK_Mode (Off);
      Frame      : U64;
      PMM_Result : Kernel.Physical_Memory.Status;
   begin
      if Table.Root (Page) /= 0 then
         Result := Ok;
         return;
      end if;

      Kernel.Physical_Memory.Allocate_Frame (PMM_Result, Frame);
      if PMM_Result /= Kernel.Physical_Memory.Ok then
         Result := Table_Full;
         return;
      end if;

      Zero_Page (Frame);
      Table.Root (Page) := Frame;
      Result := Ok;
   end Ensure_Page;

   procedure Release_Page
     (Table : in out Cap_Table; Page : Page_Index)
   is
      pragma SPARK_Mode (Off);
      PMM_Result : Kernel.Physical_Memory.Status;
   begin
      Kernel.Physical_Memory.Deallocate_Frame
        (Table.Root (Page), PMM_Result);
      Table.Root (Page) := 0;
   end Release_Page;

   procedure Initialize (Table : out Cap_Table) is
   begin
      Table.Root  := (others => 0);
      Table.Count := (others => 0);
      Table.Total := 0;
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

   function To_Rights (Mask : U64) return Rights is
   begin
      return
        (Read     => (Mask and 1) /= 0,
         Write    => (Mask and 2) /= 0,
         Execute  => (Mask and 4) /= 0,
         Map      => (Mask and 8) /= 0,
         Send     => (Mask and 16) /= 0,
         Receive  => (Mask and 32) /= 0,
         Wait     => (Mask and 64) /= 0,
         Ack      => (Mask and 128) /= 0,
         Transfer => (Mask and 256) /= 0,
         Manage   => (Mask and 512) /= 0);
   end To_Rights;

   function To_Mask (R : Rights) return U64 is
      Mask : U64 := 0;
   begin
      if R.Read then
         Mask := Mask or 1;
      end if;
      if R.Write then
         Mask := Mask or 2;
      end if;
      if R.Execute then
         Mask := Mask or 4;
      end if;
      if R.Map then
         Mask := Mask or 8;
      end if;
      if R.Send then
         Mask := Mask or 16;
      end if;
      if R.Receive then
         Mask := Mask or 32;
      end if;
      if R.Wait then
         Mask := Mask or 64;
      end if;
      if R.Ack then
         Mask := Mask or 128;
      end if;
      if R.Transfer then
         Mask := Mask or 256;
      end if;
      if R.Manage then
         Mask := Mask or 512;
      end if;
      return Mask;
   end To_Mask;

   procedure Lemma_Mask_Round_Trip (Mask : U64) is
   begin
      null;
   end Lemma_Mask_Round_Trip;

   procedure Insert
     (Table  : in out Cap_Table;
      Kind   : Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : U64;
      Result : out Status;
      Cap    : out Handle)
   is
      pragma SPARK_Mode (Off);
   begin
      Cap := Invalid_Handle;

      if Kind = Null_Object or else Object = System.Null_Address then
         Result := Invalid_Object;
         return;
      end if;

      --  Lowest free handle. Absent pages read as all-free via the
      --  root array; Get on a missing page never dereferences.
      for Candidate in Handle'Succ (Invalid_Handle) .. Handle'Last loop
         if not Get (Table, Candidate).Valid then
            declare
               P : constant Page_Index := Page_No (Candidate);
            begin
               Ensure_Page (Table, P, Result);
               if Result /= Ok then
                  return;
               end if;

               Put
                 (Table, Candidate,
                  (Valid  => True,
                   Kind   => Kind,
                   Object => Object,
                   Rights => Rights,
                   Badge  => Badge));
               Table.Count (P) := Table.Count (P) + 1;
               Table.Total := Table.Total + 1;
               Cap := Candidate;
               Result := Ok;
               return;
            end;
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
      pragma SPARK_Mode (Off);
      P : Page_Index;
   begin
      if Cap = Invalid_Handle then
         Result := Invalid_Cap;
         return;
      end if;

      if Kind = Null_Object or else Object = System.Null_Address then
         Result := Invalid_Object;
         return;
      end if;

      P := Page_No (Cap);
      if Table.Root (P) /= 0 and then Get (Table, Cap).Valid then
         Result := Slot_Occupied;
         return;
      end if;

      Ensure_Page (Table, P, Result);
      if Result /= Ok then
         return;
      end if;

      Put
        (Table, Cap,
         (Valid  => True,
          Kind   => Kind,
          Object => Object,
          Rights => Rights,
          Badge  => Badge));
      Table.Count (P) := Table.Count (P) + 1;
      Table.Total := Table.Total + 1;
      Result := Ok;
   end Insert_At;

   procedure Lookup
     (Table     : Cap_Table;
      Cap       : Handle;
      Result    : out Status;
      Out_Entry : out Cap_Entry)
   is
      pragma SPARK_Mode (Off);
   begin
      Out_Entry := Get (Table, Cap);
      if Cap = Invalid_Handle or else not Out_Entry.Valid then
         Out_Entry := Null_Cap;
         Result := Invalid_Cap;
         return;
      end if;

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
      pragma SPARK_Mode (Off);
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
      pragma SPARK_Mode (Off);
      P : Page_Index;
   begin
      if Cap = Invalid_Handle
        or else not Get (Table, Cap).Valid
      then
         Result := Invalid_Cap;
         return;
      end if;

      Put (Table, Cap, Null_Cap);
      P := Page_No (Cap);
      Table.Count (P) := Table.Count (P) - 1;
      Table.Total := Table.Total - 1;

      --  Empty page goes back to the PMM: a process that briefly
      --  ballooned its table doesn't hold the frames forever.
      if Table.Count (P) = 0 then
         Release_Page (Table, P);
      end if;
      Result := Ok;
   end Close;

   procedure Reset (Table : out Cap_Table) is
      pragma SPARK_Mode (Off);
   begin
      for P in Page_Index loop
         if Table.Root (P) /= 0 then
            Release_Page (Table, P);
         end if;
      end loop;
      Table.Count := (others => 0);
      Table.Total := 0;
   end Reset;

   function Used_Count (Table : Cap_Table) return Natural is
   begin
      return Table.Total;
   end Used_Count;

end Kernel.Capabilities;
