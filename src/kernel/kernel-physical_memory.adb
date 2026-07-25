with System;
with System.Storage_Elements;
with Ada.Unchecked_Conversion;

package body Kernel.Physical_Memory is
   use type Interfaces.Unsigned_64;

   type Frame_Link is access all U64;

   function To_Frame_Link is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Frame_Link);

   Base_Frame      : U64 := 0;
   Next_Frame      : U64 := 0;
   Limit           : U64 := 0;
   Free_List_Head  : U64 := 0;
   Free_List_Count : U64 := 0;
   Is_Ready        : Boolean := False;

   function Align_Up (Value : U64; Alignment : U64) return U64 is
   begin
      return ((Value + Alignment - 1) / Alignment) * Alignment;
   end Align_Up;

   function To_Address (Value : U64) return System.Address is
   begin
      return System'To_Address
        (System.Storage_Elements.Integer_Address (Value));
   end To_Address;

   function Link_At (Frame : U64) return Frame_Link is
   begin
      return To_Frame_Link (To_Address (Frame));
   end Link_At;

   function Valid_Frame (Frame : U64) return Boolean is
   begin
      return Frame >= Base_Frame
        and then Frame < Next_Frame
        and then Frame mod Page_Size = 0;
   end Valid_Frame;

   function Is_In_Free_List (Frame : U64) return Boolean is
      Current : U64 := Free_List_Head;
   begin
      while Current /= 0 loop
         if Current = Frame then
            return True;
         end if;

         Current := Link_At (Current).all;
      end loop;

      return False;
   end Is_In_Free_List;

   procedure Initialize
     (First_Free : U64;
      Last_Byte  : U64;
      Result     : out Status)
   is
   begin
      Base_Frame := Align_Up (First_Free, Page_Size);
      Next_Frame := Base_Frame;
      Limit := Last_Byte - Last_Byte mod Page_Size;
      Free_List_Head := 0;
      Free_List_Count := 0;

      if Next_Frame >= Limit then
         Is_Ready := False;
         Result := Invalid_Range;
         return;
      end if;

      Is_Ready := True;
      Result := Ok;
   end Initialize;

   procedure Allocate_Frame
     (Result : out Status;
      Frame  : out U64)
   is
      Link : Frame_Link;
   begin
      Frame := 0;

      if not Is_Ready then
         Result := Not_Initialized;
         return;
      end if;

      if Free_List_Head /= 0 then
         Frame := Free_List_Head;
         Link := Link_At (Frame);
         Free_List_Head := Link.all;
         Free_List_Count := Free_List_Count - 1;
         Link.all := 0;
         Result := Ok;
         return;
      end if;

      if Next_Frame + Page_Size > Limit then
         Result := Out_Of_Memory;
         return;
      end if;

      Frame := Next_Frame;
      Next_Frame := Next_Frame + Page_Size;
      Result := Ok;
   end Allocate_Frame;

   procedure Deallocate_Frame
     (Frame  : U64;
      Result : out Status)
   is
      Link : Frame_Link;
   begin
      if not Is_Ready then
         Result := Not_Initialized;
         return;
      end if;

      if not Valid_Frame (Frame) or else Is_In_Free_List (Frame) then
         Result := Invalid_Range;
         return;
      end if;

      --  If the most recent bump frame is freed, shrink bump pointer.
      --  This keeps mark/rewind useful for all-or-nothing early paths.
      if Frame + Page_Size = Next_Frame then
         Next_Frame := Frame;
         Result := Ok;
         return;
      end if;

      Link := Link_At (Frame);
      Link.all := Free_List_Head;
      Free_List_Head := Frame;
      Free_List_Count := Free_List_Count + 1;
      Result := Ok;
   end Deallocate_Frame;

   function Mark return U64 is
   begin
      return Next_Frame;
   end Mark;

   procedure Rewind
     (To     : U64;
      Result : out Status)
   is
      Old_Head : U64;
      New_Head : U64 := 0;
      New_Count : U64 := 0;
      Link : Frame_Link;
      Next : U64;
   begin
      if not Is_Ready then
         Result := Not_Initialized;
      elsif To > Next_Frame or else To mod Page_Size /= 0 then
         Result := Invalid_Range;
      else
         Old_Head := Free_List_Head;
         while Old_Head /= 0 loop
            Link := Link_At (Old_Head);
            Next := Link.all;

            if Old_Head < To then
               Link.all := New_Head;
               New_Head := Old_Head;
               New_Count := New_Count + 1;
            else
               Link.all := 0;
            end if;

            Old_Head := Next;
         end loop;

         Free_List_Head := New_Head;
         Free_List_Count := New_Count;
         Next_Frame := To;
         Result := Ok;
      end if;
   end Rewind;

   function Free_Bytes return U64 is
      Bump_Free : U64 := 0;
   begin
      if not Is_Ready then
         return 0;
      end if;

      if Next_Frame < Limit then
         Bump_Free := Limit - Next_Frame;
      end if;

      return Bump_Free + Free_List_Count * Page_Size;
   end Free_Bytes;

   function Free_Frame_Count return U64 is
   begin
      if not Is_Ready then
         return 0;
      end if;

      return Free_Bytes / Page_Size;
   end Free_Frame_Count;

   function Next_Free_Frame return U64 is
   begin
      if Free_List_Head /= 0 then
         return Free_List_Head;
      end if;

      return Next_Frame;
   end Next_Free_Frame;

   function Initialized return Boolean is
   begin
      return Is_Ready;
   end Initialized;
end Kernel.Physical_Memory;
