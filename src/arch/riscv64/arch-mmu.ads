with Interfaces;

package Arch.MMU is
   subtype U64 is Interfaces.Unsigned_64;

   Page_Size : constant U64 := 4096;
   Gigapage_Size : constant U64 := 16#4000_0000#;

   type Status is
     (Ok,
      Allocation_Failed,
      Invalid_Address,
      Already_Mapped,
      Not_Mapped);

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

   User_RO : constant Page_Flags :=
     (Read => True, Write => False, Execute => False, User => True,
      Global => False);

   procedure New_Address_Space
     (Result : out Status;
      Root   : out U64);

   procedure New_User_Address_Space
     (Result : out Status;
      Root   : out U64);

   --  satp CSR value (Sv39 mode + PPN) for a root page table.
   function Satp_Value (Root : U64) return U64;

   --  Kernel root page table physical address: the dedicated kernel
   --  root after Enter_Kernel_Address_Space, the early boot root
   --  before it.  The kernel always runs on this root; user roots map
   --  only the trampoline page and their own pages.
   function Kernel_Root return U64;

   procedure Activate (Root : U64);

   --  Borrowed => leaf marked frame-not-owned (memory-object
   --  mappings): AS teardown and Unmap_Borrowed_Page never return
   --  the frame to the PMM; the owning object does.
   procedure Map_Page
     (Root     : U64;
      Virtual  : U64;
      Physical : U64;
      Flags    : Page_Flags;
      Result   : out Status;
      Borrowed : Boolean := False);

   --  Removes one borrowed (memory-object) mapping; the frame stays
   --  with its owning object. Refuses pages owned by the address
   --  space itself (image/stack/IPC buffer) with Not_Mapped.
   procedure Unmap_Borrowed_Page
     (Root     : U64;
      Virtual  : U64;
      Result   : out Status);

   --  Maps a 1 GiB leaf at level 2 of the given root.
   procedure Map_Gigapage
     (Root     : U64;
      Virtual  : U64;
      Physical : U64;
      Flags    : Page_Flags;
      Result   : out Status);

   --  Builds the dedicated kernel address space (identity VAs, W^X:
   --  kernel image RX, all other managed RAM RW, narrow UART/PLIC
   --  device pages), publishes its satp value for the trap
   --  trampoline, and activates it, abandoning the early boot root.
   --  Ram_Last is the first byte past RAM.  On failure the kernel
   --  keeps running on the early root.
   procedure Enter_Kernel_Address_Space
     (Ram_Last : U64;
      Result   : out Status);

   procedure Destroy_User_Address_Space
     (Root   : U64;
      Result : out Status);
end Arch.MMU;
