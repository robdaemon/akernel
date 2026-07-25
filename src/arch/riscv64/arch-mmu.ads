with Interfaces;

package Arch.MMU is
   subtype U64 is Interfaces.Unsigned_64;

   Page_Size : constant U64 := 4096;

   type Status is
     (Ok,
      Allocation_Failed,
      Invalid_Address,
      Already_Mapped);

   type Page_Flags is record
      Read    : Boolean;
      Write   : Boolean;
      Execute : Boolean;
      User    : Boolean;
      Global  : Boolean;
   end record;

   Kernel_RW : constant Page_Flags :=
     (Read => True, Write => True, Execute => False, User => False,
      Global => True);

   Kernel_RX : constant Page_Flags :=
     (Read => True, Write => False, Execute => True, User => False,
      Global => True);

   User_RW : constant Page_Flags :=
     (Read => True, Write => True, Execute => False, User => True,
      Global => False);

   User_RX : constant Page_Flags :=
     (Read => True, Write => False, Execute => True, User => True,
      Global => False);

   procedure New_Address_Space
     (Result : out Status;
      Root   : out U64);

   procedure New_User_Address_Space
     (Result : out Status;
      Root   : out U64);

   procedure Activate (Root : U64);

   procedure Map_Page
     (Root     : U64;
      Virtual  : U64;
      Physical : U64;
      Flags    : Page_Flags;
      Result   : out Status);

   procedure Destroy_User_Address_Space
     (Root   : U64;
      Result : out Status);
end Arch.MMU;
