------------------------------------------------------------------------------
--                                                                          --
--                       A K E R N E L   (Milestone 53c)                    --
--                                                                          --
--                     System.OS_Constants (akernel)                        --
--                                                                          --
-- Hand-written replacement for the generated s-oscons.ads. The embedded  --
-- pool ships no OS_Constants (it is produced by s-oscons-tmplt.c against  --
-- target headers); the 53c-vendored Ada.Directories chain needs only the --
-- handful of constants below. Values are AKERNEL facts (gloss dirent     --
-- buffer, adaint struct file_attributes layout), not host measurements.  --
--                                                                          --
------------------------------------------------------------------------------

package System.OS_Constants is
   pragma Pure;

   ----------------
   -- Errno bits --
   ----------------

   ENOENT : constant := 2;   --  no such file or directory (gloss)

   ----------------------
   -- C struct buffers --
   ----------------------

   --  Buffer sizes for opaque C structs that GNAT passes to adaint by
   --  pointer. Only need to be >= the real C struct; adaint writes at
   --  most its own layout.

   --  struct file_attributes (adaint.h): int + 7 x uchar + pad +
   --  OS_Time (long long) + __int64 file_length = 32 bytes; 64 with
   --  headroom.
   SIZEOF_struct_file_attributes : constant := 64;

   --  struct dirent allocation for __gnat_readdir's caller buffer:
   --  our akernel_readdir copies a plain NUL-terminated name
   --  (FAT LFN up to 255) into it.
   SIZEOF_struct_dirent_alloc : constant := 280;

end System.OS_Constants;
