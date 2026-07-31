with System.Storage_Elements;
with Interfaces;

package body Akernel_User.Files is
   use System.Storage_Elements;

   FS_Cap    : U64 := 0;
   Buf_Cap   : U64 := 0;
   Buf_Bytes : constant U64 := Buf_Pages * Syscalls.Page_Size;

   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of Byte;

   function Shift_Left (Value : U64; Amount : Natural) return U64
     renames Interfaces.Shift_Left;

   --  Pack Name (NUL-padded) into message words First .. Last.
   procedure Pack_Name
     (Name  : String;
      First : Natural;
      Last  : Natural)
   is
      Pos   : Natural := 0;
      Shift : Natural;
   begin
      for W in First .. Last loop
         Syscalls.Message.Words (W) := 0;
      end loop;

      for C of Name loop
         exit when Pos >= (Last - First + 1) * 8;
         Shift := (Pos mod 8) * 8;
         Syscalls.Message.Words (First + Pos / 8) :=
           Syscalls.Message.Words (First + Pos / 8)
             or Shift_Left (U64 (Character'Pos (C)), Shift);
         Pos := Pos + 1;
      end loop;
   end Pack_Name;

   procedure Bind (FS_Cap : U64) is
   begin
      Akernel_User.Files.FS_Cap := FS_Cap;
   end Bind;

   function Stat (Name : String; Size : out U64) return U64 is
   begin
      Size := 0;
      if FS_Cap = 0 or else Name'Length = 0 or else Name'Length > 48 then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_Stat;
      Pack_Name (Name, 0, 5);
      Syscalls.Message.Caps := (others => 0);

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      if Syscalls.Message.Words (0) = Status_Ok then
         Size := Syscalls.Message.Words (1);
      end if;
      return Syscalls.Message.Words (0);
   end Stat;

   function Open (Name : String; Size : out U64) return U64 is
      Status : constant U64 := Stat (Name, Size);
   begin
      if Status /= Status_Ok then
         return Status;
      end if;

      if Buf_Cap = 0 then
         Buf_Cap := Syscalls.Mem_Alloc (Buf_Pages);
         if Buf_Cap = Syscalls.Syscall_Failed
           or else Syscalls.Mem_Map
             (Address_Space => Syscalls.Address_Space_Cap,
              Cap           => Buf_Cap,
              VA            => Buffer_VA,
              Offset        => 0,
              Length        => Buf_Bytes,
              Flags         => 3) /= 0
         then
            Buf_Cap := 0;
            return Status_Not_Found;
         end if;
      end if;

      return Status_Ok;
   end Open;

   function Read
     (Name   : String;
      Offset : U64;
      Dest   : System.Address;
      Length : U64;
      Count  : out U64) return U64
   is
      Status : U64;
      Src    : Byte_Array (0 .. Buf_Bytes - 1)
        with Address => To_Address (Integer_Address (Buffer_VA));
      Dst    : Byte_Array (0 .. Length - 1)
        with Address => Dest;
   begin
      Count := 0;
      if Buf_Cap = 0
        or else FS_Cap = 0
        or else Name'Length = 0
        or else Name'Length > Max_Name
        or else Length = 0
      then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_Read;
      Syscalls.Message.Words (0) := Offset;
      Syscalls.Message.Words (1) := U64'Min (Length, Buf_Bytes);
      Pack_Name (Name, 2, 5);
      Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      Status := Syscalls.Message.Words (0);
      if Status /= Status_Ok then
         return Status;
      end if;

      Count := Syscalls.Message.Words (1);
      for I in 0 .. Count - 1 loop
         Dst (I) := Src (I);
      end loop;
      return Status_Ok;
   end Read;

end Akernel_User.Files;
