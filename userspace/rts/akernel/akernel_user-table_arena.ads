with Akernel_User.Syscalls;

--  Shared chunk arena for Akernel_User.Tables (M80d): every table
--  instance maps its chunks out of this one per-process window, so
--  the arena cursor lives here in a NON-generic package (generic
--  package state is per-instance; two instances with private
--  cursors would hand out the same VAs).
--
--  Window: 0x7000_0000..0x7FF0_0000 (255 MiB) — fixed literals
--  per house rule.  This is the hole M83 left between the IPC
--  buffer page (0x6FFF_0000) and the relocated 256 KiB main
--  stack (0x7FF0_0000..0x8000_0000); the ceiling is the stack
--  base.  Tables cap their chunk directories at 60 (15 MiB of
--  table data), a documented sanity bound with 17x headroom
--  below the window ceiling.
package Akernel_User.Table_Arena is
   subtype U64 is Akernel_User.Syscalls.U64;
   use type U64;

   Arena_Base  : constant U64 := 16#7000_0000#;
   Arena_End   : constant U64 := 16#7FF0_0000#;
   Chunk_Bytes : constant U64 := 64 * 4096;

   --  Compile-time window guard: the tables' 60-chunk directory
   --  must fit inside the window — a window or directory change
   --  trips this at compile time, not the stack at run time.
   subtype Must_Fit_In_Arena is U64 range 0 .. Arena_End - Arena_Base;
   Arena_Guard : constant Must_Fit_In_Arena := U64'(60) * Chunk_Bytes;
   pragma Unreferenced (Arena_Guard);

   --  Allocate Pages of zeroed PMM-backed memory, map it RW at the
   --  next arena VA, and return that VA (0 on arena or PMM
   --  exhaustion — callers answer their op with an error, never
   --  silently drop).  The memory-object cap is intentionally
   --  leaked: chunks are a high-water slab, never unmapped.
   function Reserve (Pages : U64) return U64;
end Akernel_User.Table_Arena;
