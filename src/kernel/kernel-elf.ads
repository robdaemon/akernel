with Interfaces;

package Kernel.ELF is
   subtype U64 is Interfaces.Unsigned_64;

   User_Alias_Delta : constant U64 := 16#4000_0000#;

   type Status is
     (Ok,
      Bad_Magic,
      Unsupported,
      Bad_Image);

   procedure Load_User_Alias
     (Image_Base  : U64;
      Image_Size  : U64;
      Result      : out Status;
      Entry_Point : out U64);

   procedure Load_Into_Address_Space
     (Image_Base  : U64;
      Image_Size  : U64;
      Root        : U64;
      Result      : out Status;
      Entry_Point : out U64);
end Kernel.ELF;
