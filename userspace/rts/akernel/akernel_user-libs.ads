with Akernel_User.Syscalls;

--  Amiga-style shared-library client API (milestone 58 Tier-1).
--  A library is a server program; clients open it by spawning its
--  ELF image and receiving its service endpoint cap through a
--  rendezvous at handle 4. See docs/IPC.md "Library rendezvous".

package Akernel_User.Libs is
   use type Syscalls.U64;

   subtype U64 is Syscalls.U64;

   Invalid_Handle : constant U64 := 0;

   --  Bind this process to a shared-library manager cap.  When
   --  non-zero, Open_Library contacts the manager instead of
   --  falling back to a private spawn.
   procedure Bind (Libman_Cap : U64);

   --  Open a shared library by name.
   --  Name is the library program path, conventionally
   --  "Sys:Libs/<Name>". Console_Cap, FS_Cap, and Bureau_Cap are the
   --  caller's uniform-ABI endpoint handles (defaults 1, 2, 3); pass
   --  0 for any cap the caller does not hold. On success returns the
   --  library service endpoint cap handle; on failure returns
   --  Invalid_Handle.
   --
   --  Min_Version is an Amiga-style version floor: the open fails if
   --  the library's version is lower.  If Bind was called with a valid
   --  manager cap, Open_Library contacts it; otherwise it falls back
   --  to spawning a private copy of the library server.
   function Open_Library
     (Name        : String;
      Console_Cap : U64 := 1;
      FS_Cap      : U64 := 2;
      Bureau_Cap  : U64 := 3;
      Min_Version : U64 := 0) return U64;

   --  Close a library handle returned by Open_Library.
   procedure Close_Library (Cap : U64);

   --  Test hook (m75): True when the handle was delivered by the
   --  manager's reply cap (shared-library cache), False when it
   --  came from a private-spawn fallback (or is not open here).
   function Opened_Via_Libman (Cap : U64) return Boolean;

end Akernel_User.Libs;
