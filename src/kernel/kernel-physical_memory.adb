package body Kernel.Physical_Memory is
   use type Interfaces.Unsigned_64;

   Next_Frame : U64 := 0;
   Limit      : U64 := 0;
   Is_Ready   : Boolean := False;

   function Align_Up (Value : U64; Alignment : U64) return U64 is
   begin
      return ((Value + Alignment - 1) / Alignment) * Alignment;
   end Align_Up;

   procedure Initialize
     (First_Free : U64;
      Last_Byte  : U64;
      Result     : out Status)
   is
   begin
      Next_Frame := Align_Up (First_Free, Page_Size);
      Limit := Last_Byte - Last_Byte mod Page_Size;

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
   begin
      Frame := 0;

      if not Is_Ready then
         Result := Not_Initialized;
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

   function Mark return U64 is
   begin
      return Next_Frame;
   end Mark;

   procedure Rewind
     (To     : U64;
      Result : out Status)
   is
   begin
      if not Is_Ready then
         Result := Not_Initialized;
      elsif To > Next_Frame or else To mod Page_Size /= 0 then
         Result := Invalid_Range;
      else
         Next_Frame := To;
         Result := Ok;
      end if;
   end Rewind;

   function Free_Bytes return U64 is
   begin
      if not Is_Ready or else Next_Frame >= Limit then
         return 0;
      end if;

      return Limit - Next_Frame;
   end Free_Bytes;

   function Next_Free_Frame return U64 is
   begin
      return Next_Frame;
   end Next_Free_Frame;

   function Initialized return Boolean is
   begin
      return Is_Ready;
   end Initialized;
end Kernel.Physical_Memory;
