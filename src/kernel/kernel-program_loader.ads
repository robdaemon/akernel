with Interfaces;

package Kernel.Program_Loader is
   subtype U64 is Interfaces.Unsigned_64;

   type Status is
     (Ok,
      Invalid_Program,
      Not_Found,
      Bad_Image);

   type Program_Image is record
      Base : U64;
      Size : U64;
   end record;

   procedure Find_By_Manifest_Path
     (Path_Offset : U64;
      Path_Length : U64;
      Result      : out Status;
      Image       : out Program_Image);
end Kernel.Program_Loader;
