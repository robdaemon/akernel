with System;
with Akernel_User.Syscalls;

--  Grow-on-demand index tables (M80d, docs/LIMIT_FIXES.md).
--  Capacity is policy; the only bound is RAM.  One instance per
--  table: elements live in 64-page chunks Mem_Alloc'd and mapped
--  into the shared Table_Arena window (0x7000_0000..0x7FF0_0000);
--  growth is chunk-APPEND, never realloc-copy, so an index stays
--  valid while its entry lives (sock ids, job numbers, fds and
--  window slots are user-visible indices).
--
--  Indices are 1-based; 0 means "none" (matches the Find idiom).
--  Elements must treat an all-zero bit pattern as the empty state
--  (chunks arrive zeroed from the PMM): Valid Boolean False,
--  counts 0, strings NUL-filled — the existing table records all
--  already satisfy this.
--
--  The chunk directory is a static 60-entry array (documented
--  sanity bound — e.g. 245K file entries, 15 MiB of table data;
--  the 255 MiB arena fits 1020 chunks, so the directory is the
--  real limit).  Exhaustion is reported (0 / Null_Address),
--  never silent.

generic
   type Element is private;
package Akernel_User.Tables is
   subtype U64 is Akernel_User.Syscalls.U64;

   subtype Index is Natural;

   type Element_Access is access all Element;

   --  Append a slot at the high-water mark, growing the chunk
   --  chain as needed.  Returns the new index; 0 on arena/PMM
   --  exhaustion.  The slot is all-zero (see header comment).
   function Append return Index;

   --  Access slot I (1 .. Last).  Null when I is 0 or beyond the
   --  high-water mark.
   function Ref (I : Index) return Element_Access;

   --  High-water mark: allocated indices are 1 .. Last.  Scan
   --  loops that used to run over Max_* run over 1 .. Last now
   --  (elements carry their own Valid flags for recycling).
   function Last return Index;
end Akernel_User.Tables;
