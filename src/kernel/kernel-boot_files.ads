with Interfaces;

package Kernel.Boot_Files is
   subtype U64 is Interfaces.Unsigned_64;

   Manifest_File : constant U64 := 1;

   type Status is
     (Ok,
      Invalid_File,
      Not_Found,
      Bad_Image,
      Out_Of_Range);

   procedure Size
     (File_Id : U64;
      Result  : out Status;
      Length  : out U64);

   procedure Read_Byte
     (File_Id : U64;
      Offset  : U64;
      Result  : out Status;
      Value   : out U64);
end Kernel.Boot_Files;
