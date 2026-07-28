with Ada.Unchecked_Conversion;
with System;
with System.Storage_Elements;
with Kernel.Physical_Memory;

package body Arch.MMU is
   use type Kernel.Physical_Memory.Status;

   PTE_V : constant U64 := 16#001#;
   PTE_R : constant U64 := 16#002#;
   PTE_W : constant U64 := 16#004#;
   PTE_X : constant U64 := 16#008#;
   PTE_U : constant U64 := 16#010#;
   PTE_G : constant U64 := 16#020#;
   PTE_A : constant U64 := 16#040#;
   PTE_D : constant U64 := 16#080#;

   type Page_Table_Index is range 0 .. 511;
   type Page_Table is array (Page_Table_Index) of U64;
   type Page_Table_Access is access all Page_Table;

   Early_Root : Page_Table
     with Import, Convention => C, External_Name => "early_l2_page_table";

   Rx_Start_Sym : Interfaces.Unsigned_8
     with Import, Convention => C, External_Name => "__rx_start";
   Rx_End_Sym : Interfaces.Unsigned_8
     with Import, Convention => C, External_Name => "__rx_end";

   Kernel_Satp_Slot : aliased U64
     with Import, Convention => C, External_Name => "kernel_satp_slot";

   Kernel_End_Sym : Interfaces.Unsigned_8
     with Import, Convention => C, External_Name => "_end";

   Trampoline_Start : Interfaces.Unsigned_8
     with Import, Convention => C, External_Name => "trampoline_start";
   Trampoline_End : Interfaces.Unsigned_8
     with Import, Convention => C, External_Name => "trampoline_end";

   Current_Kernel_Root : U64 := 0;

   procedure Raw_Activate (Root : U64)
     with Import, Convention => C, External_Name => "riscv_activate_satp";

   function To_Table is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Page_Table_Access);

   function To_Address (Value : U64) return System.Address is
   begin
      --  Page tables are physical frames; reach them through the
      --  physmap.
      return System'To_Address
        (System.Storage_Elements.Integer_Address (Arch.Phys_To_Virt (Value)));
   end To_Address;

   function Index_For
     (Virtual : U64;
      Level   : Natural) return Page_Table_Index
   is
      Shift : constant Natural := 12 + Level * 9;
   begin
      return Page_Table_Index
        (Interfaces.Shift_Right (Virtual, Shift) and 16#1ff#);
   end Index_For;

   function PTE_To_Physical (PTE_Value : U64) return U64 is
   begin
      return Interfaces.Shift_Right (PTE_Value, 10) * Page_Size;
   end PTE_To_Physical;

   function Is_Leaf (PTE_Value : U64) return Boolean is
   begin
      return (PTE_Value and (PTE_R or PTE_W or PTE_X)) /= 0;
   end Is_Leaf;

   function Physical_To_PTE (Physical : U64) return U64 is
   begin
      return Interfaces.Shift_Left (Physical / Page_Size, 10);
   end Physical_To_PTE;

   function Leaf_Flags (Flags : Page_Flags) return U64 is
      Value : U64 := PTE_V or PTE_A or PTE_D;
   begin
      if Flags.Read then
         Value := Value or PTE_R;
      end if;
      if Flags.Write then
         Value := Value or PTE_W;
      end if;
      if Flags.Execute then
         Value := Value or PTE_X;
      end if;
      if Flags.User then
         Value := Value or PTE_U;
      end if;
      if Flags.Global then
         Value := Value or PTE_G;
      end if;

      return Value;
   end Leaf_Flags;

   procedure Zero_Page (Physical : U64) is
      Table : constant Page_Table_Access := To_Table (To_Address (Physical));
   begin
      for Index in Page_Table_Index loop
         Table (Index) := 0;
      end loop;
   end Zero_Page;

   procedure Allocate_Table
     (Result   : out Status;
      Physical : out U64)
   is
      Alloc_Result : Kernel.Physical_Memory.Status;
   begin
      Kernel.Physical_Memory.Allocate_Frame (Alloc_Result, Physical);
      if Alloc_Result /= Kernel.Physical_Memory.Ok then
         Physical := 0;
         Result := Allocation_Failed;
         return;
      end if;

      Zero_Page (Physical);
      Result := Ok;
   end Allocate_Table;

   procedure New_Address_Space
     (Result : out Status;
      Root   : out U64)
   is
   begin
      Allocate_Table (Result, Root);
   end New_Address_Space;

   procedure New_User_Address_Space
     (Result : out Status;
      Root   : out U64)
   is
      --  Map only the trap trampoline page(s) into user address
      --  spaces, at the trampoline's kernel VMA (supervisor RX,
      --  global).  The trampoline switches satp to the kernel root on
      --  trap entry and back on return, so no other kernel or device
      --  mapping is needed here.  Per-thread kernel stacks are mapped
      --  separately by the spawn/boot code.
      Trampoline_First : constant U64 :=
        U64 (System.Storage_Elements.To_Integer (Trampoline_Start'Address));
      Trampoline_Last : constant U64 :=
        U64 (System.Storage_Elements.To_Integer (Trampoline_End'Address));
      Map_Result : Status;
      Destroy_Result : Status;
      Page : U64;
   begin
      Allocate_Table (Result, Root);
      if Result /= Ok then
         return;
      end if;

      Page := Trampoline_First - Trampoline_First mod Page_Size;
      while Page < Trampoline_Last loop
         Map_Page
           (Root     => Root,
            Virtual  => Page,
            Physical => Arch.Kernel_Virt_To_Phys (Page),
            Flags    => Kernel_RX,
            Result   => Map_Result);

         if Map_Result /= Ok then
            --  Global trampoline leaves are skipped by destroy; the
            --  root and intermediate tables are reclaimed.
            Destroy_User_Address_Space (Root, Destroy_Result);
            Root := 0;
            Result := Allocation_Failed;
            return;
         end if;

         Page := Page + Page_Size;
      end loop;
   end New_User_Address_Space;

   function Satp_Value (Root : U64) return U64 is
      Mode_Sv39 : constant U64 := 16#8000_0000_0000_0000#;
   begin
      return Mode_Sv39 or (Root / Page_Size);
   end Satp_Value;

   function Kernel_Root return U64 is
   begin
      if Current_Kernel_Root /= 0 then
         return Current_Kernel_Root;
      end if;

      return U64
        (System.Storage_Elements.To_Integer (Early_Root'Address));
   end Kernel_Root;

   procedure Activate (Root : U64) is
   begin
      Raw_Activate (Root);
   end Activate;

   procedure Map_Page
     (Root     : U64;
      Virtual  : U64;
      Physical : U64;
      Flags    : Page_Flags;
      Result   : out Status)
   is
      Table_Physical : U64 := Root;
      Table          : Page_Table_Access;
      PTE_Value      : U64;
      New_Table      : U64;
      Index          : Page_Table_Index;
   begin
      if Root mod Page_Size /= 0
        or else Virtual mod Page_Size /= 0
        or else Physical mod Page_Size /= 0
      then
         Result := Invalid_Address;
         return;
      end if;

      for Level in reverse 1 .. 2 loop
         Table := To_Table (To_Address (Table_Physical));
         Index := Index_For (Virtual, Level);
         PTE_Value := Table (Index);

         if (PTE_Value and PTE_V) = 0 then
            Allocate_Table (Result, New_Table);
            if Result /= Ok then
               return;
            end if;

            Table (Index) := Physical_To_PTE (New_Table) or PTE_V;
            Table_Physical := New_Table;
         elsif (PTE_Value and (PTE_R or PTE_W or PTE_X)) /= 0 then
            Result := Already_Mapped;
            return;
         else
            Table_Physical := PTE_To_Physical (PTE_Value);
         end if;
      end loop;

      Table := To_Table (To_Address (Table_Physical));
      Index := Index_For (Virtual, 0);
      if (Table (Index) and PTE_V) /= 0 then
         Result := Already_Mapped;
         return;
      end if;

      Table (Index) := Physical_To_PTE (Physical) or Leaf_Flags (Flags);
      Result := Ok;
   end Map_Page;

   procedure Map_Gigapage
     (Root     : U64;
      Virtual  : U64;
      Physical : U64;
      Flags    : Page_Flags;
      Result   : out Status)
   is
      Table : constant Page_Table_Access := To_Table (To_Address (Root));
      Index : constant Page_Table_Index := Index_For (Virtual, 2);
   begin
      if Root mod Page_Size /= 0
        or else Virtual mod Gigapage_Size /= 0
        or else Physical mod Gigapage_Size /= 0
      then
         Result := Invalid_Address;
         return;
      end if;

      if (Table (Index) and PTE_V) /= 0 then
         Result := Already_Mapped;
         return;
      end if;

      Table (Index) := Physical_To_PTE (Physical) or Leaf_Flags (Flags);
      Result := Ok;
   end Map_Gigapage;

   procedure Enter_Kernel_Address_Space
     (Ram_Last : U64;
      Result   : out Status)
   is
      --  Dedicated high-half kernel address space:
      --  - kernel image at kernel VAs: text/rodata RX, data/bss RW
      --  - physmap gigapage leaves for all of PA space up to RAM end,
      --    RW: page tables, PMM frames, initrd, DTB, MMIO devices
      --  No identity mappings; the early boot root is abandoned.
      Rx_Start : constant U64 :=
        U64 (System.Storage_Elements.To_Integer (Rx_Start_Sym'Address));
      Rx_End   : constant U64 :=
        U64 (System.Storage_Elements.To_Integer (Rx_End_Sym'Address));
      Kernel_End : constant U64 :=
        U64 (System.Storage_Elements.To_Integer (Kernel_End_Sym'Address));
      Rw_End   : constant U64 :=
        Kernel_End + (Page_Size - Kernel_End mod Page_Size);
      Physmap_Last : constant U64 :=
        Arch.Physmap_Base + Ram_Last
        + (Gigapage_Size - Ram_Last mod Gigapage_Size);

      Root         : U64;
      Map_Result   : Status;
      Destroy_Result : Status;
      Page         : U64;
      Failed       : Boolean := False;
   begin
      Allocate_Table (Result, Root);
      if Result /= Ok then
         Root := 0;
         return;
      end if;

      --  Kernel image text/rodata at kernel VAs: read-execute only.
      Page := Rx_Start;
      while Page < Rx_End and then not Failed loop
         Map_Page
           (Root, Page, Arch.Kernel_Virt_To_Phys (Page), Kernel_RX,
            Map_Result);
         Failed := Map_Result /= Ok;
         Page := Page + Page_Size;
      end loop;

      --  Kernel data/bss/stacks: read-write, not executable.
      Page := Rx_End;
      while Page < Rw_End and then not Failed loop
         Map_Page
           (Root, Page, Arch.Kernel_Virt_To_Phys (Page), Kernel_RW,
            Map_Result);
         Failed := Map_Result /= Ok;
         Page := Page + Page_Size;
      end loop;

      --  Physmap: whole PA space up to RAM end as RW gigapage leaves.
      Page := Arch.Physmap_Base;
      while Page < Physmap_Last and then not Failed loop
         Map_Gigapage
           (Root, Page, Page - Arch.Physmap_Base, Kernel_RW, Map_Result);
         Failed := Map_Result /= Ok;
         Page := Page + Gigapage_Size;
      end loop;

      if Failed then
         Destroy_User_Address_Space (Root, Destroy_Result);
         Result := Allocation_Failed;
         return;
      end if;

      --  Publish for the trap trampoline, then switch.  The slot sits
      --  in the RX trampoline page, so it must be written before the
      --  new root is active (the early root maps the kernel gigapage
      --  RWX).
      Kernel_Satp_Slot := Satp_Value (Root);
      Current_Kernel_Root := Root;
      Raw_Activate (Root);
      Result := Ok;
   end Enter_Kernel_Address_Space;

   procedure Destroy_Table
     (Table_Physical : U64;
      Level          : Natural)
   is
      Table       : constant Page_Table_Access :=
        To_Table (To_Address (Table_Physical));
      PTE_Value   : U64;
      Child_Frame : U64;
      Free_Result : Kernel.Physical_Memory.Status;
   begin
      for Index in Page_Table_Index loop
         PTE_Value := Table (Index);
         if (PTE_Value and PTE_V) /= 0 then
            Child_Frame := PTE_To_Physical (PTE_Value);

            if Is_Leaf (PTE_Value) then
               if (PTE_Value and PTE_G) = 0 then
                  Kernel.Physical_Memory.Deallocate_Frame
                    (Frame  => Child_Frame,
                     Result => Free_Result);
               end if;
            elsif Level > 0 then
               Destroy_Table (Child_Frame, Level - 1);
               Kernel.Physical_Memory.Deallocate_Frame
                 (Frame  => Child_Frame,
                  Result => Free_Result);
            end if;

            Table (Index) := 0;
         end if;
      end loop;
   end Destroy_Table;

   procedure Destroy_User_Address_Space
     (Root   : U64;
      Result : out Status)
   is
      Free_Result : Kernel.Physical_Memory.Status;
   begin
      if Root = 0 or else Root mod Page_Size /= 0 then
         Result := Invalid_Address;
         return;
      end if;

      Destroy_Table (Root, 2);
      Kernel.Physical_Memory.Deallocate_Frame
        (Frame  => Root,
         Result => Free_Result);

      if Free_Result = Kernel.Physical_Memory.Ok
        or else Free_Result = Kernel.Physical_Memory.Invalid_Range
      then
         Result := Ok;
      else
         Result := Allocation_Failed;
      end if;
   end Destroy_User_Address_Space;
end Arch.MMU;
