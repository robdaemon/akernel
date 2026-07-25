with Interfaces;
with System;

package Kernel.Capabilities is
   subtype U64 is Interfaces.Unsigned_64;

   Max_Caps : constant := 256;

   type Handle is range 0 .. Max_Caps - 1;
   Invalid_Handle : constant Handle := 0;

   type Object_Kind is
     (Null_Object,
      Frame_Object,
      Address_Space_Object,
      Thread_Object,
      Endpoint_Object,
      IRQ_Object,
      MMIO_Object,
      DMA_Object,
      Kernel_Object);

   type Rights is record
      Read     : Boolean;
      Write    : Boolean;
      Execute  : Boolean;
      Map      : Boolean;
      Send     : Boolean;
      Receive  : Boolean;
      Wait     : Boolean;
      Ack      : Boolean;
      Transfer : Boolean;
      Manage   : Boolean;
   end record;

   No_Rights : constant Rights :=
     (Read     => False,
      Write    => False,
      Execute  => False,
      Map      => False,
      Send     => False,
      Receive  => False,
      Wait     => False,
      Ack      => False,
      Transfer => False,
      Manage   => False);

   All_Rights : constant Rights :=
     (Read     => True,
      Write    => True,
      Execute  => True,
      Map      => True,
      Send     => True,
      Receive  => True,
      Wait     => True,
      Ack      => True,
      Transfer => True,
      Manage   => True);

   type Cap_Entry is record
      Valid  : Boolean;
      Kind   : Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : U64;
   end record;

   Null_Cap : constant Cap_Entry :=
     (Valid  => False,
      Kind   => Null_Object,
      Object => System.Null_Address,
      Rights => No_Rights,
      Badge  => 0);

   type Cap_Table is private;

   type Status is
     (Ok,
      Invalid_Cap,
      Invalid_Object,
      Rights_Denied,
      Table_Full,
      Slot_Occupied);

   procedure Initialize (Table : out Cap_Table);

   function Has_Rights (Have : Rights; Need : Rights) return Boolean;

   procedure Insert
     (Table  : in out Cap_Table;
      Kind   : Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : U64;
      Result : out Status;
      Cap    : out Handle);

   procedure Insert_At
     (Table  : in out Cap_Table;
      Cap    : Handle;
      Kind   : Object_Kind;
      Object : System.Address;
      Rights : Kernel.Capabilities.Rights;
      Badge  : U64;
      Result : out Status);

   procedure Lookup
     (Table     : Cap_Table;
      Cap       : Handle;
      Result    : out Status;
      Out_Entry : out Cap_Entry);

   procedure Duplicate
     (Table     : in out Cap_Table;
      Source    : Handle;
      New_Rights : Kernel.Capabilities.Rights;
      New_Badge  : U64;
      Result    : out Status;
      New_Cap   : out Handle);

   procedure Close
     (Table  : in out Cap_Table;
      Cap    : Handle;
      Result : out Status);

private
   type Cap_Array is array (Handle) of Cap_Entry;

   type Cap_Table is record
      Entries : Cap_Array;
   end record;
end Kernel.Capabilities;
