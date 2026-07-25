with Interfaces;

package Kernel.Physical_Memory is
   subtype U64 is Interfaces.Unsigned_64;

   Page_Size : constant U64 := 4096;

   type Status is
     (Ok,
      Out_Of_Memory,
      Invalid_Range,
      Not_Initialized);

   procedure Initialize
     (First_Free : U64;
      Last_Byte  : U64;
      Result     : out Status);

   procedure Allocate_Frame
     (Result : out Status;
      Frame  : out U64);

   function Mark return U64;

   procedure Rewind
     (To     : U64;
      Result : out Status);

   function Free_Bytes return U64;
   function Next_Free_Frame return U64;
   function Initialized return Boolean;
end Kernel.Physical_Memory;
