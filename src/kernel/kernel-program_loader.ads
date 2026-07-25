with Interfaces;

package Kernel.Program_Loader is
   subtype U64 is Interfaces.Unsigned_64;

   type Status is
     (Ok,
      Invalid_Program,
      Not_Found,
      Bad_Image);

   Serial_Driver_Program : constant U64 := 1;

   type Program_Image is record
      Base : U64;
      Size : U64;
   end record;

   type Grant_Kind is
     (No_Grant,
      UART_MMIO_Grant,
      UART_IRQ_Grant);

   Max_Grants : constant := 8;
   type Grant_Index is range 0 .. Max_Grants - 1;
   type Grant_Array is array (Grant_Index) of Grant_Kind;

   type Program_Manifest is record
      Image       : Program_Image;
      Grant_Count : Natural range 0 .. Max_Grants;
      Grants      : Grant_Array;
   end record;

   Null_Manifest : constant Program_Manifest :=
     (Image       => (Base => 0, Size => 0),
      Grant_Count => 0,
      Grants      => (others => No_Grant));

   procedure Find
     (Program_Id : U64;
      Result     : out Status;
      Manifest   : out Program_Manifest);
end Kernel.Program_Loader;
