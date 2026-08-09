with System.Storage_Elements;
with Interfaces;

package body Akernel_User.Files is
   use System.Storage_Elements;

   FS_Cap    : U64 := 0;
   Buf_Cap   : U64 := 0;
   Buf_Bytes : constant U64 := Buf_Pages * Syscalls.Page_Size;

   Default_Volume : String (1 .. 16) :=
     "RD0" & (1 .. 13 => Character'Val (0));
   Default_Volume_Len : Natural := 3;

   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of Byte;

   function Shift_Left (Value : U64; Amount : Natural) return U64
     renames Interfaces.Shift_Left;

   --  Effective wire name: Name unchanged when already qualified
   --  (contains ':'), otherwise the default volume is prepended.
   procedure Qualified
     (Name : String;
      S    : out String;
      Len  : out Natural)
   is
   begin
      Len := 0;
      S := (others => Character'Val (0));
      for C of Name loop
         if C = ':' then
            if Name'Length <= S'Length then
               S (1 .. Name'Length) := Name;
               Len := Name'Length;
            end if;
            return;
         end if;
      end loop;

      if Default_Volume_Len + 1 + Name'Length <= S'Length then
         S (1 .. Default_Volume_Len) :=
           Default_Volume (1 .. Default_Volume_Len);
         S (Default_Volume_Len + 1) := ':';
         S (Default_Volume_Len + 2
            .. Default_Volume_Len + 1 + Name'Length) := Name;
         Len := Default_Volume_Len + 1 + Name'Length;
      end if;
   end Qualified;

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

   function Endpoint return U64 is (FS_Cap);

   procedure Set_Default_Volume (Name : String) is
   begin
      if Name'Length > 0 and then Name'Length <= 16 then
         Default_Volume := (others => Character'Val (0));
         Default_Volume (1 .. Name'Length) := Name;
         Default_Volume_Len := Name'Length;
      end if;
   end Set_Default_Volume;

   function Stat (Name : String; Size : out U64) return U64 is
      Q   : String (1 .. 48);
      Len : Natural;
   begin
      Size := 0;
      Qualified (Name, Q, Len);
      if FS_Cap = 0 or else Len = 0 then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_Stat;
      Pack_Name (Q (1 .. Len), 0, 5);
      Syscalls.Message.Caps := (others => 0);

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      if Syscalls.Message.Words (0) = Status_Ok then
         Size := Syscalls.Message.Words (1);
      end if;
      return Syscalls.Message.Words (0);
   end Stat;

   function Read_Dir
     (Name         : String;
      Index        : U64;
      Out_Name     : out String;
      Out_Name_Len : out Natural;
      Is_Dir       : out Boolean;
      Size         : out U64) return U64
   is
      Q   : String (1 .. 32);
      Len : Natural;
      Ch  : Character;
   begin
      Out_Name_Len := 0;
      Is_Dir := False;
      Size := 0;
      Qualified (Name, Q, Len);
      if FS_Cap = 0 or else Len = 0 then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_ReadDir;
      Syscalls.Message.Words := (others => 0);
      Pack_Name (Q (1 .. Len), 0, 3);
      Syscalls.Message.Words (4) := Index;
      Syscalls.Message.Caps := (others => 0);

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      if Syscalls.Message.Words (0) = Status_Ok then
         Size := Syscalls.Message.Words (1);
         Is_Dir := Syscalls.Message.Words (2) /= 0;
         for P in 0 .. 23 loop
            exit when P >= Out_Name'Length;
            Ch := Character'Val (Natural
              ((Syscalls.Message.Words (3 + P / 8)
                  / Shift_Left (1, (P mod 8) * 8)) and 16#FF#));
            exit when Ch = Character'Val (0);
            Out_Name_Len := Out_Name_Len + 1;
            Out_Name (Out_Name'First + Out_Name_Len - 1) := Ch;
         end loop;
      end if;

      return Syscalls.Message.Words (0);
   end Read_Dir;

   --  Allocate + map the shared client buffer on first use.
   function Ensure_Buffer return Boolean is
   begin
      if Buf_Cap /= 0 then
         return True;
      end if;
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
         return False;
      end if;
      return True;
   end Ensure_Buffer;

   function Open (Name : String; Size : out U64) return U64 is
      Status : constant U64 := Stat (Name, Size);
   begin
      if Status /= Status_Ok then
         return Status;
      end if;

      if not Ensure_Buffer then
         return Status_Not_Found;
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
      Q      : String (1 .. 32);
      Len    : Natural;
      Src    : Byte_Array (0 .. Buf_Bytes - 1)
        with Address => To_Address (Integer_Address (Buffer_VA));
      Dst    : Byte_Array (0 .. Length - 1)
        with Address => Dest;
   begin
      Count := 0;
      Qualified (Name, Q, Len);
      if Buf_Cap = 0
        or else FS_Cap = 0
        or else Len = 0
        or else Length = 0
      then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_Read;
      Syscalls.Message.Words (0) := Offset;
      Syscalls.Message.Words (1) := U64'Min (Length, Buf_Bytes);
      Pack_Name (Q (1 .. Len), 2, 5);
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

   function Write
     (Name           : String;
      Offset         : U64;
      Buffer_Address : System.Address;
      Length         : U64;
      Count          : out U64) return U64
   is
      Status : U64;
      Q      : String (1 .. 32);
      Len    : Natural;
      N      : U64;
   begin
      Count := 0;
      Qualified (Name, Q, Len);
      if FS_Cap = 0
        or else Len = 0
        or else Length = 0
      then
         return Status_Bad_Args;
      end if;

      if not Ensure_Buffer then
         return Status_Not_Found;
      end if;

      N := U64'Min (Length, Buf_Bytes);

      declare
         Src : Byte_Array (0 .. N - 1) with Address => Buffer_Address;
         Dst : Byte_Array (0 .. Buf_Bytes - 1)
           with Address => To_Address (Integer_Address (Buffer_VA));
      begin
         for I in 0 .. N - 1 loop
            Dst (I) := Src (I);
         end loop;
      end;

      Syscalls.Message.Label := Op_Write;
      Syscalls.Message.Words (0) := Offset;
      Syscalls.Message.Words (1) := N;
      Pack_Name (Q (1 .. Len), 2, 5);
      Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      Status := Syscalls.Message.Words (0);
      if Status /= Status_Ok then
         return Status;
      end if;

      Count := Syscalls.Message.Words (1);
      return Status_Ok;
   end Write;

   --  Shared body for the path-only mutating ops.
   function Path_Op (Op : U64; Name : String) return U64 is
      Q   : String (1 .. 48);
      Len : Natural;
   begin
      Qualified (Name, Q, Len);
      if FS_Cap = 0 or else Len = 0 then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op;
      Pack_Name (Q (1 .. Len), 0, 5);
      Syscalls.Message.Caps := (others => 0);

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;
      return Syscalls.Message.Words (0);
   end Path_Op;

   function Delete (Name : String) return U64 is
     (Path_Op (Op_Delete, Name));

   function Rename (From, To : String) return U64 is
      QF : String (1 .. 48);
      QT : String (1 .. 48);
      LF : Natural;
      LT : Natural;
      Dst : Byte_Array (0 .. Buf_Bytes - 1)
        with Address => To_Address (Integer_Address (Buffer_VA));
   begin
      Qualified (From, QF, LF);
      Qualified (To, QT, LT);
      if FS_Cap = 0 or else LF = 0 or else LT = 0 then
         return Status_Bad_Args;
      end if;
      if not Ensure_Buffer then
         return Status_Not_Found;
      end if;

      --  TO path NUL-terminated at offset 0 of the shared buffer.
      for I in 0 .. U64 (LT) loop
         Dst (I) :=
           (if I < U64 (LT)
            then Byte (Character'Pos (QT (Natural (I) + 1)))
            else 0);
      end loop;

      Syscalls.Message.Label := Op_Rename;
      Pack_Name (QF (1 .. LF), 0, 5);
      Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;
      return Syscalls.Message.Words (0);
   end Rename;

   function Volume_Info
     (Name    : String;
      Total   : out U64;
      Free    : out U64;
      Cluster : out U64) return U64
   is
      Q   : String (1 .. 48);
      Len : Natural;
   begin
      Total := 0;
      Free := 0;
      Cluster := 0;
      Qualified (Name, Q, Len);
      if FS_Cap = 0 or else Len = 0 then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_Volume_Info;
      Pack_Name (Q (1 .. Len), 0, 5);
      Syscalls.Message.Caps := (others => 0);

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;
      if Syscalls.Message.Words (0) = Status_Ok then
         Total := Syscalls.Message.Words (1);
         Free := Syscalls.Message.Words (2);
         Cluster := Syscalls.Message.Words (3);
      end if;
      return Syscalls.Message.Words (0);
   end Volume_Info;

   function Truncate (Name : String) return U64 is
     (Path_Op (Op_Truncate, Name));

   function Mkdir (Name : String) return U64 is
     (Path_Op (Op_Mkdir, Name));

   function Rmdir (Name : String) return U64 is
     (Path_Op (Op_Rmdir, Name));

   function Sync return U64 is
   begin
      Syscalls.Message.Label := Op_Sync;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;
      return Syscalls.Message.Words (0);
   end Sync;

   function Assign_Set (Name : String; Target : String) return U64 is
   begin
      if FS_Cap = 0 or else Name'Length = 0
        or else Name'Length > 15 or else Target'Length > 31
      then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_Assign;
      Syscalls.Message.Words := (others => 0);
      Pack_Name (Name, 0, 1);
      Pack_Name (Target, 2, 5);
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;
      return Syscalls.Message.Words (0);
   end Assign_Set;

   function Assign_List
     (Index : U64; Text : out String; Text_Len : out Natural)
      return U64
   is
      Ch : Character;
   begin
      Text_Len := 0;
      if FS_Cap = 0 then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_Assign_List;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Words (0) := Index;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      if Syscalls.Message.Words (0) = Status_Ok then
         for P in 0 .. 39 loop
            exit when P >= Text'Length;
            Ch := Character'Val (Natural
              ((Syscalls.Message.Words (1 + P / 8)
                  / Shift_Left (1, (P mod 8) * 8)) and 16#FF#));
            exit when Ch = Character'Val (0);
            Text_Len := Text_Len + 1;
            Text (Text'First + Text_Len - 1) := Ch;
         end loop;
      end if;
      return Syscalls.Message.Words (0);
   end Assign_List;

end Akernel_User.Files;
