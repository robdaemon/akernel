with Ada.Unchecked_Conversion;
with System;
with System.Storage_Elements;
with Kernel.Physical_Memory;

package body Arch.MMU is
   use type Interfaces.Unsigned_64;
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

   procedure Raw_Activate (Root : U64)
     with Import, Convention => C, External_Name => "riscv_activate_satp";

   function To_Table is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Page_Table_Access);

   function To_Address (Value : U64) return System.Address is
   begin
      return System'To_Address
        (System.Storage_Elements.Integer_Address (Value));
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
      Root_Table : Page_Table_Access;

      --  Narrow supervisor device windows the kernel trap path needs
      --  while running on a user address space (QEMU virt layout).
      --  These replace the old broad 1 GiB low-MMIO gigapage copy.
      --  PLIC context pages cover contexts 0..3 (harts 0..1).
      UART_Page          : constant U64 := 16#1000_0000#;
      PLIC_Bank_Base     : constant U64 := 16#0c00_0000#;
      PLIC_Bank_Pages    : constant U64 := 2;
      PLIC_Context_Base  : constant U64 := 16#0c20_0000#;
      PLIC_Context_Pages : constant U64 := 4;

      Map_Result : Status;
      Destroy_Result : Status;
      Failed     : Boolean := False;
   begin
      Allocate_Table (Result, Root);
      if Result /= Ok then
         return;
      end if;

      Root_Table := To_Table (To_Address (Root));

      --  Keep supervisor RAM identity mappings shared in every user
      --  address space.  Do not copy early root[1], the temporary broad
      --  U-mode alias, or early root[0], the broad low-MMIO gigapage;
      --  device access is narrowed to the windows mapped below.
      Root_Table (2) := Early_Root (2); -- RAM 0x8000_0000..0xbfff_ffff
      Root_Table (3) := Early_Root (3);
      Root_Table (4) := Early_Root (4);
      Root_Table (5) := Early_Root (5);

      Map_Page
        (Root     => Root,
         Virtual  => UART_Page,
         Physical => UART_Page,
         Flags    => Kernel_RW,
         Result   => Map_Result);
      Failed := Map_Result /= Ok;

      for Page in U64 range 0 .. PLIC_Bank_Pages - 1 loop
         exit when Failed;
         Map_Page
           (Root     => Root,
            Virtual  => PLIC_Bank_Base + Page * Page_Size,
            Physical => PLIC_Bank_Base + Page * Page_Size,
            Flags    => Kernel_RW,
            Result   => Map_Result);
         Failed := Map_Result /= Ok;
      end loop;

      for Page in U64 range 0 .. PLIC_Context_Pages - 1 loop
         exit when Failed;
         Map_Page
           (Root     => Root,
            Virtual  => PLIC_Context_Base + Page * Page_Size,
            Physical => PLIC_Context_Base + Page * Page_Size,
            Flags    => Kernel_RW,
            Result   => Map_Result);
         Failed := Map_Result /= Ok;
      end loop;

      if Failed then
         --  Global device leaves are skipped by destroy; intermediate
         --  page tables and the root are reclaimed.
         Destroy_User_Address_Space (Root, Destroy_Result);
         Root := 0;
         Result := Allocation_Failed;
      end if;
   end New_User_Address_Space;

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
