with Interfaces;

package Kernel.Bootinfo is
   subtype U64 is Interfaces.Unsigned_64;

   --  Bootinfo page (docs/IPC.md): one read-only page mapped into
   --  init's address space at a fixed VA, listing every cap the
   --  kernel handed it as (handle, kind, rights mask, name) entries.
   --  Init discovers its namespace by name instead of hardcoding
   --  handle numbers. Written by the kernel via the physmap before
   --  init enters user mode; mapped read-only to userspace.
   VA         : constant U64 := 16#6FFE_0000#;
   Magic      : constant U64 := 16#4B41_494E_464F_3031#;  --  "AKINFO01"
   Max_Name   : constant := 32;
   Entry_Size : constant := 64;
   Max_Entries : constant := 63;

   type Status is
     (Ok,
      Allocation_Failed,
      Map_Failed,
      Full,
      Not_Installed);

   --  Allocate, zero, and map the bootinfo page into the given user
   --  address space root. Must run before any Add calls.
   procedure Install
     (Root   : U64;
      Result : out Status);

   --  Append one (handle, kind, rights mask, name) entry.
   procedure Add
     (Handle      : U64;
      Kind        : U64;
      Rights_Mask : U64;
      Name        : String;
      Result      : out Status);
end Kernel.Bootinfo;
