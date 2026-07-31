------------------------------------------------------------------------------
--                                                                          --
--                         GNAT RUN-TIME COMPONENTS                         --
--                                                                          --
--                         S Y S T E M . M E M O R Y                        --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--          Copyright (C) 2001-2025, Free Software Foundation, Inc.         --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.                                     --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
------------------------------------------------------------------------------

--  Akernel userspace implementation: a free-list heap backed by memory
--  objects (mem_alloc/mem_map syscalls).  The heap occupies a VA range
--  below the program text; physical frames are owned by memory objects
--  allocated on demand and mapped page by page as borrowed user pages.
--  All state lives in .bss and initializes lazily on first Alloc, since
--  userspace startup jumps straight to main (no binder elaboration).

with Interfaces;
with System.Storage_Elements;
with System.Address_To_Access_Conversions;

package body System.Memory is
   use System.Storage_Elements;
   use type Interfaces.Unsigned_64;

   subtype U64 is Interfaces.Unsigned_64;

   --  Raw syscall entries (imported directly so this unit does not
   --  depend on Akernel_User.Syscalls, whose root unit drags this
   --  package into every userspace build closure).
   function Raw_Mem_Alloc (Pages : U64) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_mem_alloc";
   function Raw_Mem_Map
     (Address_Space : U64;
      Cap           : U64;
      VA            : U64;
      Offset        : U64;
      Length        : U64;
      Flags         : U64) return U64
     with Import, Convention => C,
          External_Name => "akernel_sys_mem_map";

   AS_Cap       : constant U64 := 255;
   Syscall_Fail : constant U64 := U64'Last;

   Page_Bytes : constant U64 := 4096;

   --  Heap VA range: 0x4000_0000 .. 0x4020_0000 (below the text at
   --  0x4600_0000; stack/IPC/bootinfo pages sit at 0x6FFx_xxxx).
   Heap_Base : constant U64 := 16#4000_0000#;

   Chunk_Pages : constant U64 := 64;
   Max_Chunks  : constant := 8;
   --  8 chunks x 256 KiB = 2 MiB of heap.

   Header_Bytes : constant := 8;
   Min_Payload  : constant := 16;
   --  Free blocks thread the free list through the payload's first
   --  word, so a block must hold at least one address.

   type Header is record
      Size_And_Flag : U64;
      --  Total block size in bytes (header included, multiple of 16);
      --  bit 0 set => block is allocated.
   end record;

   package Header_Conv is new Address_To_Access_Conversions (Header);
   package Address_Conv is new Address_To_Access_Conversions (Address);

   Chunk_Caps  : array (0 .. Max_Chunks - 1) of U64 := (others => 0);
   Mapped_Bytes : U64 := 0;
   Free_Head   : Address := Null_Address;

   Allocated_Flag : constant U64 := 1;

   function Round_16 (Size : U64) return U64 is
     ((Size + 15) and not 15);

   function Header_At (Addr : Address) return Header_Conv.Object_Pointer
   is (Header_Conv.To_Pointer (Addr));

   function Size_Of (H : Header_Conv.Object_Pointer) return U64
   is (H.Size_And_Flag and not Allocated_Flag);

   function Is_Allocated (H : Header_Conv.Object_Pointer) return Boolean
   is ((H.Size_And_Flag and Allocated_Flag) /= 0);

   procedure Set_Header
     (H         : Header_Conv.Object_Pointer;
      Size      : U64;
      Allocated : Boolean);

   procedure Set_Header
     (H         : Header_Conv.Object_Pointer;
      Size      : U64;
      Allocated : Boolean)
   is
   begin
      H.Size_And_Flag :=
        Size or (if Allocated then Allocated_Flag else 0);
   end Set_Header;

   --  The free list is threaded through the free blocks' payload
   --  (after the header), never through the header word itself.
   function Free_Next (Addr : Address) return Address;

   function Free_Next (Addr : Address) return Address
   is (Address_Conv.To_Pointer (Addr + Storage_Offset (Header_Bytes)).all);

   procedure Set_Free_Next (Addr : Address; Next : Address);

   procedure Set_Free_Next (Addr : Address; Next : Address) is
   begin
      Address_Conv.To_Pointer
        (Addr + Storage_Offset (Header_Bytes)).all := Next;
   end Set_Free_Next;

   function To_Addr (Value : U64) return Address
   is (System.Storage_Elements.To_Address (Integer_Address (Value)));

   function To_U64 (Value : Address) return U64
   is (U64 (System.Storage_Elements.To_Integer (Value)));

   ----------------------
   -- Map_Heap_Through --
   ----------------------

   --  Map pages (one mem_map syscall per page, borrowed frames) until
   --  at least Bytes of the heap VA range are backed.  Allocates a new
   --  memory object every Chunk_Pages pages.  Returns False when the
   --  chunk table or the kernel object/frame pools are exhausted.

   function Map_Heap_Through (Bytes : U64) return Boolean;

   function Map_Heap_Through (Bytes : U64) return Boolean is
      Result : U64;
   begin
      while Mapped_Bytes < Bytes loop
         declare
            Page_Index  : constant U64 := Mapped_Bytes / Page_Bytes;
            Chunk_Index : constant Natural :=
              Natural (Page_Index / Chunk_Pages);
            In_Chunk    : constant U64 := Page_Index mod Chunk_Pages;
            VA          : constant U64 := Heap_Base + Mapped_Bytes;
         begin
            if Chunk_Index >= Max_Chunks then
               return False;
            end if;

            if Chunk_Caps (Chunk_Index) = 0 then
               Result := Raw_Mem_Alloc (Chunk_Pages);
               if Result = Syscall_Fail then
                  return False;
               end if;
               Chunk_Caps (Chunk_Index) := Result;
            end if;

            Result := Raw_Mem_Map
              (Address_Space => AS_Cap,
               Cap           => Chunk_Caps (Chunk_Index),
               VA            => VA,
               Offset        => In_Chunk * Page_Bytes,
               Length        => Page_Bytes,
               Flags         => 3);  --  read + write
            if Result /= 0 then
               return False;
            end if;

            Mapped_Bytes := Mapped_Bytes + Page_Bytes;
         end;
      end loop;
      return True;
   end Map_Heap_Through;

   -----------
   -- Alloc --
   -----------

   function Alloc (Size : size_t) return System.Address is
      Total : U64;
      Addr  : Address;
      Prev  : Address;
      Best  : Header_Conv.Object_Pointer;
      Left  : U64;
   begin
      --  Discard requests that are obviously too large (mirrors the
      --  reference implementation) before any rounding can wrap.
      if Size >= size_t (2) ** (Standard'Address_Size - 1) then
         raise Storage_Error;
      end if;

      Total := Header_Bytes
        + Round_16 (U64'Max (U64 (Size), Min_Payload));

      --  First fit in the free list.
      Addr := Free_Head;
      Prev := Null_Address;
      while Addr /= Null_Address loop
         Best := Header_At (Addr);
         if Size_Of (Best) >= Total then
            --  Unlink.
            if Prev = Null_Address then
               Free_Head := Free_Next (Addr);
            else
               Set_Free_Next (Prev, Free_Next (Addr));
            end if;

            --  Split if the remainder can hold a minimal free block.
            Left := Size_Of (Best) - Total;
            if Left >= Header_Bytes + Min_Payload then
               Set_Header (Best, Total, Allocated => True);
               Set_Header
                 (Header_At (Addr + Storage_Offset (Total)),
                  Left, Allocated => False);
               Set_Free_Next
                 (Addr + Storage_Offset (Total), Free_Head);
               Free_Head := Addr + Storage_Offset (Total);
            else
               Set_Header (Best, Size_Of (Best), Allocated => True);
            end if;

            return Addr + Storage_Offset (Header_Bytes);
         end if;
         Prev := Addr;
         Addr := Free_Next (Addr);
      end loop;

      --  Nothing fits: grow the heap, add the new space as one free
      --  block (merged with a free top block when possible), retry.
      declare
         Needed : constant U64 := Round_16 (Total);
         Pages  : constant U64 := (Needed + Page_Bytes - 1) / Page_Bytes;
         Grow   : constant U64 := Pages * Page_Bytes;
         Old_Top_VA : constant U64 := Heap_Base + Mapped_Bytes;
      begin
         if not Map_Heap_Through (Mapped_Bytes + Grow) then
            raise Storage_Error;
         end if;

         --  Merge with the block immediately below when it is free.
         Addr := Free_Head;
         Prev := Null_Address;
         while Addr /= Null_Address loop
            Best := Header_At (Addr);
            if To_U64 (Addr) + Size_Of (Best) = Old_Top_VA then
               Set_Header
                 (Best, Size_Of (Best) + Grow, Allocated => False);
               return Alloc (Size);
            end if;
            Addr := Free_Next (Addr);
         end loop;

         Set_Header (Header_At (To_Addr (Old_Top_VA)), Grow,
                     Allocated => False);
         Set_Free_Next (To_Addr (Old_Top_VA), Free_Head);
         Free_Head := To_Addr (Old_Top_VA);
      end;

      return Alloc (Size);
   end Alloc;

   ----------
   -- Free --
   ----------

   procedure Free (Ptr : System.Address) is
      Addr  : constant Address := Ptr - Storage_Offset (Header_Bytes);
      H     : constant Header_Conv.Object_Pointer := Header_At (Addr);
      Size  : constant U64 := Size_Of (H);
      Scan  : Address;
      ScanH : Header_Conv.Object_Pointer;
   begin
      if Ptr = Null_Address then
         return;
      end if;

      Set_Header (H, Size, Allocated => False);
      Set_Free_Next (Addr, Free_Head);
      Free_Head := Addr;

      --  Coalesce with the physically next block when free.
      declare
         Next_Addr : constant Address := Addr + Storage_Offset (Size);
         Prev      : Address := Null_Address;
      begin
         if To_U64 (Next_Addr) < Heap_Base + Mapped_Bytes then
            ScanH := Header_At (Next_Addr);
            if not Is_Allocated (ScanH) then
               --  Unlink Next_Addr from the free list and absorb it.
               Scan := Free_Head;
               while Scan /= Null_Address loop
                  if Scan = Next_Addr then
                     if Prev = Null_Address then
                        Free_Head := Free_Next (Scan);
                     else
                        Set_Free_Next (Prev, Free_Next (Scan));
                     end if;
                     exit;
                  end if;
                  Prev := Scan;
                  Scan := Free_Next (Scan);
               end loop;
               Set_Header (H, Size + Size_Of (ScanH), Allocated => False);
            end if;
         end if;
      end;

      --  Coalesce with a free block immediately below (linear scan;
      --  free lists are short in userspace workloads).
      declare
         Merged : constant U64 := Size_Of (H);
         Prev   : Address := Null_Address;
      begin
         Scan := Free_Head;
         while Scan /= Null_Address loop
            ScanH := Header_At (Scan);
            if Scan /= Addr
              and then To_U64 (Scan) + Size_Of (ScanH) = To_U64 (Addr)
            then
               if Prev = Null_Address then
                  Free_Head := Free_Next (Scan);
               else
                  Set_Free_Next (Prev, Free_Next (Scan));
               end if;
               Set_Header
                 (ScanH, Size_Of (ScanH) + Merged, Allocated => False);
               Set_Free_Next (Scan, Free_Head);
               Free_Head := Scan;
               exit;
            end if;
            Prev := Scan;
            Scan := Free_Next (Scan);
         end loop;
      end;
   end Free;

end System.Memory;
