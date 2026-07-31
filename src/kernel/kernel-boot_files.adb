with Ada.Unchecked_Conversion;
with System.Storage_Elements;
with Kernel.Initrd;
with Kernel.Objects;

package body Kernel.Boot_Files is
   use type Interfaces.Unsigned_64;
   use type Kernel.Capabilities.Object_Kind;
   use type Kernel.Initrd.Status;

   subtype U8 is Interfaces.Unsigned_8;
   type U8_Access is access all U8;

   function To_U8_Access is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => U8_Access);

   type Boot_File_Access is access all Kernel.Objects.Boot_File;

   function To_Boot_File is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Boot_File_Access);

   type File_Entry is record
      Valid       : Boolean := False;
      Name        : String (1 .. Max_Name_Length);
      Name_Length : Natural := 0;
      Object      : aliased Kernel.Objects.Boot_File;
   end record;

   type File_Table is array (1 .. Max_Files) of File_Entry;

   Files : File_Table;
   Count : Natural := 0;

   procedure Enumerate
     (Result : out Status;
      Count  : out Natural)
   is
      Init_Result : Kernel.Initrd.Status;
      Name        : String (1 .. Max_Name_Length);
      Name_Length : Natural;
      Base        : U64;
      Size        : U64;
   begin
      Files := (others => (Valid => False,
                           Name => (others => Character'Val (0)),
                           Name_Length => 0,
                           Object => (Base => 0, Length => 0)));
      Boot_Files.Count := 0;
      Count := 0;
      Result := Ok;

      Kernel.Initrd.Reset_Iteration;
      loop
         Kernel.Initrd.Next
           (Result      => Init_Result,
            Name        => Name,
            Name_Length => Name_Length,
            Base        => Base,
            Size        => Size);

         exit when Init_Result = Kernel.Initrd.Not_Found;

         if Init_Result /= Kernel.Initrd.Ok then
            Result := Bad_Image;
            return;
         end if;

         --  Skip zero-length entries (cpio directories).
         if Size > 0 and then Name_Length > 0 then
            if Boot_Files.Count = Max_Files then
               Result := Bad_Image;
               return;
            end if;

            Boot_Files.Count := Boot_Files.Count + 1;
            Files (Boot_Files.Count).Valid := True;
            Files (Boot_Files.Count).Name_Length := Name_Length;
            Files (Boot_Files.Count).Name (1 .. Name_Length) :=
              Name (1 .. Name_Length);
            Files (Boot_Files.Count).Object :=
              (Base => Base, Length => Size);
         end if;
      end loop;

      Count := Boot_Files.Count;
   end Enumerate;

   function File_Count return Natural is
   begin
      return Count;
   end File_Count;

   function File_Name (Index : Natural) return String is
   begin
      if Index < 1 or else Index > Count then
         return "";
      end if;

      return Files (Index).Name (1 .. Files (Index).Name_Length);
   end File_Name;

   function File_Object (Index : Natural) return System.Address is
   begin
      if Index < 1 or else Index > Count then
         return System.Null_Address;
      end if;

      return Files (Index).Object'Address;
   end File_Object;

   procedure Locate
     (Cap    : Kernel.Capabilities.Cap_Entry;
      Result : out Status;
      File   : out Boot_File_Access)
   is
   begin
      File := null;

      if not Cap.Valid
        or else Cap.Kind /= Kernel.Capabilities.Boot_File_Object
        or else not Cap.Rights.Read
      then
         Result := Invalid_File;
         return;
      end if;

      File := To_Boot_File (Cap.Object);
      if File = null then
         Result := Invalid_File;
         return;
      end if;

      Result := Ok;
   end Locate;

   procedure Size
     (Cap     : Kernel.Capabilities.Cap_Entry;
      Result  : out Status;
      Length  : out U64)
   is
      File : Boot_File_Access;
   begin
      Length := 0;
      Locate (Cap, Result, File);
      if Result = Ok then
         Length := File.Length;
      end if;
   end Size;

   procedure Bounds
     (Cap     : Kernel.Capabilities.Cap_Entry;
      Result  : out Status;
      Base    : out U64;
      Length  : out U64)
   is
      File : Boot_File_Access;
   begin
      Base := 0;
      Length := 0;
      Locate (Cap, Result, File);
      if Result = Ok then
         Base := File.Base;
         Length := File.Length;
      end if;
   end Bounds;

   procedure Read_Byte
     (Cap     : Kernel.Capabilities.Cap_Entry;
      Offset  : U64;
      Result  : out Status;
      Value   : out U64)
   is
      File : Boot_File_Access;
      Addr : System.Address;
      Ptr  : U8_Access;
   begin
      Value := 0;
      Locate (Cap, Result, File);
      if Result /= Ok then
         return;
      end if;

      if Offset >= File.Length then
         Result := Out_Of_Range;
         return;
      end if;

      Addr := System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address (File.Base + Offset));
      Ptr := To_U8_Access (Addr);
      Value := U64 (Ptr.all);
      Result := Ok;
   end Read_Byte;
end Kernel.Boot_Files;
