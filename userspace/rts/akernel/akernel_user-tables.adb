with Ada.Unchecked_Conversion;
with System.Storage_Elements;
with Akernel_User.Table_Arena;

package body Akernel_User.Tables is
   use System.Storage_Elements;
   use type U64;

   --  60 chunks of 64 pages exactly fill the arena (the Table_Arena
   --  compile-time guard proves the arithmetic).
   Max_Chunks : constant := 60;

   Chunks : array (1 .. Max_Chunks) of U64 := (others => 0);
   High   : Natural := 0;

   --  Per-instance element geometry, armed on first use (no
   --  library-level elaboration runs in crates; Element'Size is
   --  not static for a formal type anyway).
   Elem_Bytes      : Storage_Count := 0;
   Slots_Per_Chunk : Natural := 0;

   procedure Ensure_Ready is
      Raw : constant Storage_Count :=
        Storage_Count ((Element'Size + 7) / 8);
   begin
      if Elem_Bytes = 0 then
         --  8-byte element stride keeps every element aligned for
         --  any scalar the record can hold.
         Elem_Bytes := (Raw + 7) / 8 * 8;
         Slots_Per_Chunk :=
           Natural (Table_Arena.Chunk_Bytes) / Natural (Elem_Bytes);
      end if;
   end Ensure_Ready;

   function To_Access is new Ada.Unchecked_Conversion
     (System.Address, Element_Access);

   function Append return Index is
      New_Idx : Index;
      C       : Natural;
      VA      : U64;
   begin
      Ensure_Ready;
      if Slots_Per_Chunk = 0 then
         return 0;  --  an element bigger than a chunk: absurd
      end if;

      New_Idx := High + 1;
      C := (New_Idx - 1) / Slots_Per_Chunk + 1;
      if C > Max_Chunks then
         return 0;
      end if;

      if Chunks (C) = 0 then
         VA := Table_Arena.Reserve (Table_Arena.Chunk_Bytes / 4096);
         if VA = 0 then
            return 0;
         end if;
         Chunks (C) := VA;
      end if;

      High := New_Idx;
      return New_Idx;
   end Append;

   function Ref (I : Index) return Element_Access is
      C : Natural;
      S : Natural;
   begin
      if I = 0 or else I > High then
         return null;
      end if;
      Ensure_Ready;
      C := (I - 1) / Slots_Per_Chunk + 1;
      S := (I - 1) mod Slots_Per_Chunk;
      return To_Access
        (System'To_Address
           (Integer_Address (Chunks (C))
            + Integer_Address (S) * Integer_Address (Elem_Bytes)));
   end Ref;

   function Last return Index is
   begin
      return High;
   end Last;
end Akernel_User.Tables;
