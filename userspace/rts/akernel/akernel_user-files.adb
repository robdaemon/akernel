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
               S (S'First .. S'First + Name'Length - 1) :=
        Name (Name'First .. Name'Last);
               Len := Name'Length;
            end if;
            return;
         end if;
      end loop;

      if Default_Volume_Len + 1 + Name'Length <= S'Length then
         S (S'First .. S'First + Default_Volume_Len - 1) :=
           Default_Volume
             (Default_Volume'First
              .. Default_Volume'First + Default_Volume_Len - 1);
         S (S'First + Default_Volume_Len) := ':';
         S (S'First + Default_Volume_Len + 1
            .. S'First + Default_Volume_Len + Name'Length) :=
           Name (Name'First .. Name'Last);
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

   --  M82i: one-page path buffer for requests whose qualified
   --  path outgrows the inline words. Lazily allocated like the
   --  read buffer and reused across calls (the kernel duplicates
   --  a transferred cap into the receiver's table, so the
   --  original stays ours; receivers delete their copies).
   Path_Cap : U64 := 0;

   function Ensure_Path_Buffer return Boolean is
   begin
      if Path_Cap /= 0 then
         return True;
      end if;
      Path_Cap := Syscalls.Mem_Alloc (Path_Buf_Pages);
      if Path_Cap = Syscalls.Syscall_Failed
        or else Syscalls.Mem_Map
          (Address_Space => Syscalls.Address_Space_Cap,
           Cap           => Path_Cap,
           VA            => Path_Buf_VA,
           Offset        => 0,
           Length        => Path_Buf_Pages * Syscalls.Page_Size,
           Flags         => 3) /= 0
      then
         Path_Cap := 0;
         return False;
      end if;
      return True;
   end Ensure_Path_Buffer;

   --  Stage the qualified path Q (1 .. Len): packed inline when
   --  it fits words First .. Last, otherwise written NUL-
   --  terminated into the path buffer with the Path_In_Buf
   --  marker at word First and the buffer cap in slot Slot.
   --  Call AFTER any other Message.Caps assignments (Stage_Path
   --  only touches slot Slot). False = allocation failure.
   function Stage_Path
     (Q     : String;
      Len   : Natural;
      First : Natural;
      Last  : Natural;
      Slot  : Natural) return Boolean
   is
      Win : Byte_Array (0 .. Path_Buf_Pages * Syscalls.Page_Size - 1)
        with Address => To_Address (Integer_Address (Path_Buf_VA));
   begin
      if Len <= (Last - First + 1) * 8 then
         Pack_Name (Q (Q'First .. Q'First + Len - 1), First, Last);
         return True;
      end if;
      if Len > Max_Path or else not Ensure_Path_Buffer then
         return False;
      end if;
      for W in First .. Last loop
         Syscalls.Message.Words (W) := 0;
      end loop;
      for I in 1 .. Len loop
         Win (U64 (I - 1)) := Byte (Character'Pos (Q (Q'First + I - 1)));
      end loop;
      Win (U64 (Len)) := 0;
      Syscalls.Message.Words (First) := Path_In_Buf;
      Syscalls.Message.Caps (Slot) := Path_Cap;
      return True;
   end Stage_Path;

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
      Q   : String (1 .. Max_Path);
      Len : Natural;
   begin
      Size := 0;
      Qualified (Name, Q, Len);
      if FS_Cap = 0 or else Len = 0 then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_Stat;
      Syscalls.Message.Caps := (others => 0);
      if not Stage_Path (Q, Len, 0, 5, 0) then
         return Status_Not_Found;
      end if;

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      if Syscalls.Message.Words (0) = Status_Ok then
         Size := Syscalls.Message.Words (1);
      end if;
      return Syscalls.Message.Words (0);
   end Stat;

   function Stat_Ex
     (Name       : String;
      Size       : out U64;
      Write_Date : out U64;
      Write_Time : out U64;
      Is_Dir     : out Boolean) return U64 is
      Q   : String (1 .. Max_Path);
      Len : Natural;
   begin
      Size := 0;
      Write_Date := 0;
      Write_Time := 0;
      Is_Dir := False;
      Qualified (Name, Q, Len);
      if FS_Cap = 0 or else Len = 0 then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_Stat;
      Syscalls.Message.Caps := (others => 0);
      if not Stage_Path (Q, Len, 0, 5, 0) then
         return Status_Not_Found;
      end if;

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      if Syscalls.Message.Words (0) = Status_Ok then
         Size       := Syscalls.Message.Words (1);
         Write_Date := Syscalls.Message.Words (2);
         Write_Time := Syscalls.Message.Words (3);
         Is_Dir     := Syscalls.Message.Words (4) = 1;
      end if;
      return Syscalls.Message.Words (0);
   end Stat_Ex;

   function Read_Dir
     (Name         : String;
      Index        : U64;
      Out_Name     : out String;
      Out_Name_Len : out Natural;
      Is_Dir     : out Boolean;
      Size         : out U64) return U64
   is
      Q   : String (1 .. Max_Path);
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
      Syscalls.Message.Caps := (others => 0);
      if not Stage_Path (Q, Len, 0, 3, 0) then
         return Status_Not_Found;
      end if;
      Syscalls.Message.Words (4) := Index;

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

   function Attr_List
     (Name         : String;
      Index        : U64;
      Out_Name     : out String;
      Out_Name_Len : out Natural;
      Attr_Type    : out U64;
      Attr_Size    : out U64) return U64
   is
      Q   : String (1 .. Max_Path);
      Len : Natural;
      Ch  : Character;
   begin
      Out_Name_Len := 0;
      Attr_Type := 0;
      Attr_Size := 0;
      Qualified (Name, Q, Len);
      if FS_Cap = 0 or else Len = 0 then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_Attr_List;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Caps := (others => 0);
      if not Stage_Path (Q, Len, 0, 3, 0) then
         return Status_Not_Found;
      end if;
      Syscalls.Message.Words (4) := Index;

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      if Syscalls.Message.Words (0) = Status_Ok then
         Attr_Type := Syscalls.Message.Words (1);
         Attr_Size := Syscalls.Message.Words (2);
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
   end Attr_List;

   function Attr_Read
     (Name      : String;
      Attr      : String;
      Dest      : System.Address;
      Length    : U64;
      Count     : out U64;
      Attr_Size : out U64;
      Attr_Type : out U64) return U64
   is
      Status : U64;
      Q      : String (1 .. Max_Path);
      Len    : Natural;
      Src    : Byte_Array (0 .. Buf_Bytes - 1)
        with Address => To_Address (Integer_Address (Buffer_VA));
      Dst    : Byte_Array (0 .. Length - 1)
        with Address => Dest;
   begin
      Count := 0;
      Attr_Size := 0;
      Attr_Type := 0;
      Qualified (Name, Q, Len);
      if FS_Cap = 0
        or else Len = 0
        or else Attr'Length = 0
        or else Attr'Length > 16  --  words 4..5 on the wire
        or else Length = 0
      then
         return Status_Bad_Args;
      end if;

      if not Ensure_Buffer then
         return Status_Not_Found;
      end if;

      Syscalls.Message.Label := Op_Attr_Read;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);
      if not Stage_Path (Q, Len, 0, 3, 1) then
         return Status_Not_Found;
      end if;
      Pack_Name (Attr, 4, 5);

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      Status := Syscalls.Message.Words (0);
      if Status /= Status_Ok then
         return Status;
      end if;

      Count := Syscalls.Message.Words (1);
      Attr_Size := Syscalls.Message.Words (2);
      Attr_Type := Syscalls.Message.Words (3);
      if Count > 0 then
         for I in 0 .. Count - 1 loop
            Dst (I) := Src (I);
         end loop;
      end if;
       return Status_Ok;
    end Attr_Read;

    function Attr_Write
      (Name           : String;
       Attr           : String;
       Attr_Type      : U64;
       Buffer_Address : System.Address;
       Length         : U64) return U64
    is
       Q   : String (1 .. Max_Path);
       Len : Natural;
       Dst : Byte_Array (0 .. Buf_Bytes - 1)
         with Address => To_Address (Integer_Address (Buffer_VA));
    begin
       Qualified (Name, Q, Len);
       if FS_Cap = 0
         or else Len = 0
         or else Attr'Length = 0
         or else Attr'Length > 16  --  words 4..5 on the wire
         or else Length > Buf_Bytes - 16
       then
          return Status_Bad_Args;
       end if;

       if not Ensure_Buffer then
          return Status_Not_Found;
       end if;

       --  Buffer header: le64 type fourcc @0, le64 length @8,
       --  then the data bytes.
       for I in 0 .. 7 loop
          Dst (U64 (I)) := Interfaces.Unsigned_8
            (Interfaces.Shift_Right (Attr_Type, 8 * I) and 16#FF#);
          Dst (U64 (8 + I)) := Interfaces.Unsigned_8
            (Interfaces.Shift_Right (Length, 8 * I) and 16#FF#);
       end loop;
       if Length > 0 then
          declare
             Src : Byte_Array (0 .. Length - 1)
               with Address => Buffer_Address;
          begin
             for I in 0 .. Length - 1 loop
                Dst (16 + I) := Src (I);
             end loop;
          end;
       end if;

       Syscalls.Message.Label := Op_Attr_Write;
       Syscalls.Message.Words := (others => 0);
       Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);
       if not Stage_Path (Q, Len, 0, 3, 1) then
          return Status_Not_Found;
       end if;
       Pack_Name (Attr, 4, 5);

       if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
          return Status_Not_Found;
       end if;

       return Syscalls.Message.Words (0);
    end Attr_Write;

   function Open (Name : String; Size : out U64) return U64 is
      Q   : String (1 .. Max_Path);
      Len : Natural;
   begin
      Size := 0;
      Qualified (Name, Q, Len);
      if FS_Cap = 0 or else Len = 0 then
         return Status_Bad_Args;
      end if;

      --  Op_Open (not Op_Stat): identical on ordinary volumes,
      --  but on PIPE: Open ATTACHES, creating the pipe on first
      --  use (Amiga semantics), while Stat stays a pure
      --  existence probe.
      Syscalls.Message.Label := Op_Open;
      Syscalls.Message.Caps := (others => 0);
      if not Stage_Path (Q, Len, 0, 5, 0) then
         return Status_Not_Found;
      end if;

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      if Syscalls.Message.Words (0) = Status_Ok then
         Size := Syscalls.Message.Words (1);
      else
         return Syscalls.Message.Words (0);
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
      Q      : String (1 .. Max_Path);
      Len    : Natural;
      Src    : Byte_Array (0 .. Buf_Bytes - 1)
        with Address => To_Address (Integer_Address (Buffer_VA));
      Dst    : Byte_Array (0 .. Length - 1)
        with Address => Dest;
   begin
      Count := 0;
      Qualified (Name, Q, Len);
      if FS_Cap = 0
        or else Len = 0
        or else Length = 0
      then
         return Status_Bad_Args;
      end if;

      --  Allocate the shared client buffer on first use (the
      --  Write side already does; a reader that never Opens —
      --  e.g. CLI.Get_Line on a pipe, m46b — burned Bad_Args
      --  here).
      if not Ensure_Buffer then
         return Status_Not_Found;
      end if;

      Syscalls.Message.Label := Op_Read;
      Syscalls.Message.Words (0) := Offset;
      Syscalls.Message.Words (1) := U64'Min (Length, Buf_Bytes);
      Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);
      if not Stage_Path (Q, Len, 2, 5, 1) then
         return Status_Not_Found;
      end if;

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      Status := Syscalls.Message.Words (0);
      if Status /= Status_Ok then
         return Status;
      end if;

      Count := Syscalls.Message.Words (1);
      if Count > 0 then
         --  Guard: pipes and NIL: answer Ok+0 at EOF (m46a) —
         --  0 .. Count - 1 on a U64 wraps (LCH burn).
         for I in 0 .. Count - 1 loop
            Dst (I) := Src (I);
         end loop;
      end if;
      return Status_Ok;
   end Read;

   --  One-shot query (m82f): the predicate rides in the shared
   --  client buffer (NUL-terminated), the match index in word 4.
   function Query
     (Name      : String;
      Predicate : String;
      Index     : U64;
      Path      : out String;
      Path_Len  : out Natural;
      Size      : out U64;
      Is_Dir    : out Boolean) return U64
   is
      Status : U64;
      Q      : String (1 .. Max_Path);
      Len    : Natural;
      Dst    : Byte_Array (0 .. Buf_Bytes - 1)
        with Address => To_Address (Integer_Address (Buffer_VA));
   begin
      Path_Len := 0;
      Size := 0;
      Is_Dir := False;
      Qualified (Name, Q, Len);
      if FS_Cap = 0
        or else Len = 0
        or else Predicate'Length = 0
        or else Predicate'Length > 255
      then
         return Status_Bad_Args;
      end if;

      if not Ensure_Buffer then
         return Status_Not_Found;
      end if;

      for I in 1 .. Predicate'Length loop
         Dst (U64 (I - 1)) :=
           Interfaces.Unsigned_8 (Character'Pos (Predicate (I)));
      end loop;
      Dst (U64 (Predicate'Length)) := 0;

      Syscalls.Message.Label := Op_Query;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);
      if not Stage_Path (Q, Len, 0, 3, 1) then
         return Status_Not_Found;
      end if;
      Syscalls.Message.Words (4) := Index;

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      Status := Syscalls.Message.Words (0);
      if Status /= Status_Ok then
         return Status;
      end if;

       Size := Syscalls.Message.Words (1);
       Is_Dir := Syscalls.Message.Words (2) /= 0;
       declare
          N : constant Natural := Natural (Syscalls.Message.Words (3));
          P : Natural := 0;
       begin
          while P < Path'Length and then P < N loop
             P := P + 1;
             Path (P) := Character'Val (Natural (Dst (U64 (P - 1))));
          end loop;
          Path_Len := P;
       end;
       return Status_Ok;
    end Query;

    function Query_Open
      (Name      : String;
       Predicate : String;
       Ntfn      : U64;
       Handle    : out U64) return U64
    is
       Q      : String (1 .. Max_Path);
       Len    : Natural;
       Dst    : Byte_Array (0 .. Buf_Bytes - 1)
         with Address => To_Address (Integer_Address (Buffer_VA));
    begin
       Handle := 0;
       Qualified (Name, Q, Len);
       if FS_Cap = 0
         or else Len = 0
         or else Predicate'Length = 0
         or else Predicate'Length > 255
         or else Ntfn = 0
       then
          return Status_Bad_Args;
       end if;

       if not Ensure_Buffer then
          return Status_Not_Found;
       end if;

       for I in 1 .. Predicate'Length loop
          Dst (U64 (I - 1)) :=
            Interfaces.Unsigned_8 (Character'Pos (Predicate (I)));
       end loop;
       Dst (U64 (Predicate'Length)) := 0;

       Syscalls.Message.Label := Op_Query_Open;
       Syscalls.Message.Words := (others => 0);
       Syscalls.Message.Caps := (0 => Buf_Cap, 1 => Ntfn,
                                 others => 0);
       if not Stage_Path (Q, Len, 0, 3, 2) then
          return Status_Not_Found;
       end if;

       if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
          return Status_Not_Found;
       end if;

       if Syscalls.Message.Words (0) = Status_Ok then
          Handle := Syscalls.Message.Words (1);
       end if;
       return Syscalls.Message.Words (0);
    end Query_Open;

    function Query_Poll
      (Name      : String;
       Handle    : U64;
       Kind      : out U64;
       Path      : out String;
       Path_Len  : out Natural) return U64
    is
       Status : U64;
       Q      : String (1 .. Max_Path);
       Len    : Natural;
       Dst    : Byte_Array (0 .. Buf_Bytes - 1)
         with Address => To_Address (Integer_Address (Buffer_VA));
    begin
       Kind := 0;
       Path_Len := 0;
       Qualified (Name, Q, Len);
       if FS_Cap = 0 or else Len = 0 or else Handle = 0 then
          return Status_Bad_Args;
       end if;

       if not Ensure_Buffer then
          return Status_Not_Found;
       end if;

       Syscalls.Message.Label := Op_Query_Poll;
       Syscalls.Message.Words := (others => 0);
       Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);
       if not Stage_Path (Q, Len, 0, 3, 1) then
          return Status_Not_Found;
       end if;
       Syscalls.Message.Words (4) := Handle;

       if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
          return Status_Not_Found;
       end if;

       Status := Syscalls.Message.Words (0);
       if Status /= Status_Ok then
          return Status;
       end if;

       Kind := Syscalls.Message.Words (1);
       declare
          N : constant Natural := Natural (Syscalls.Message.Words (2));
          P : Natural := 0;
       begin
          while P < Path'Length and then P < N loop
             P := P + 1;
             Path (P) := Character'Val (Natural (Dst (U64 (P - 1))));
          end loop;
          Path_Len := P;
       end;
       return Status_Ok;
    end Query_Poll;

    function Query_Close (Name : String; Handle : U64) return U64
    is
       Q   : String (1 .. Max_Path);
       Len : Natural;
    begin
       Qualified (Name, Q, Len);
       if FS_Cap = 0 or else Len = 0 or else Handle = 0 then
          return Status_Bad_Args;
       end if;
       Syscalls.Message.Label := Op_Query_Close;
       Syscalls.Message.Words := (others => 0);
       Syscalls.Message.Caps := (others => 0);
       if not Stage_Path (Q, Len, 0, 3, 0) then
          return Status_Not_Found;
       end if;
       Syscalls.Message.Words (4) := Handle;
       if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
          return Status_Not_Found;
       end if;
       return Syscalls.Message.Words (0);
    end Query_Close;

   function Write
     (Name           : String;
      Offset         : U64;
      Buffer_Address : System.Address;
      Length         : U64;
      Count          : out U64) return U64
   is
      Status : U64;
      Q      : String (1 .. Max_Path);
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
      Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);
      if not Stage_Path (Q, Len, 2, 5, 1) then
         return Status_Not_Found;
      end if;

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
      Q   : String (1 .. Max_Path);
      Len : Natural;
   begin
      Qualified (Name, Q, Len);
      if FS_Cap = 0 or else Len = 0 then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op;
      Syscalls.Message.Caps := (others => 0);
      if not Stage_Path (Q, Len, 0, 5, 0) then
         return Status_Not_Found;
      end if;

      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;
      return Syscalls.Message.Words (0);
   end Path_Op;

   function Delete (Name : String) return U64 is
     (Path_Op (Op_Delete, Name));

   function Close (Name : String) return U64 is
     (Path_Op (Op_Close, Name));

   function Rename (From, To : String) return U64 is
      QF : String (1 .. Max_Path);
      QT : String (1 .. Max_Path);
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

      --  TO path NUL-terminated at offset 0 of the shared buffer
      --  (m82i: up to Max_Path chars now).
      for I in 0 .. U64 (LT) loop
         Dst (I) :=
           (if I < U64 (LT)
            then Byte (Character'Pos (QT (Natural (I) + 1)))
            else 0);
      end loop;

      Syscalls.Message.Label := Op_Rename;
      Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);
      if not Stage_Path (QF, LF, 0, 5, 1) then
         return Status_Not_Found;
      end if;

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
      Q   : String (1 .. Max_Path);
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
      Syscalls.Message.Caps := (others => 0);
      if not Stage_Path (Q, Len, 0, 5, 0) then
         return Status_Not_Found;
      end if;

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

   function Volume_List
     (Index : U64; Name : out String; Name_Len : out Natural;
      Kind : out U64) return U64
   is
      Ch : Character;
   begin
      Name_Len := 0;
      Kind := Vol_Kind_Boot;
      if FS_Cap = 0 then
         return Status_Bad_Args;
      end if;

      Syscalls.Message.Label := Op_List_Volumes;
      Syscalls.Message.Words := (others => 0);
      Syscalls.Message.Words (0) := Index;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Call (FS_Cap) /= Syscalls.IPC_Ok then
         return Status_Not_Found;
      end if;

      if Syscalls.Message.Words (0) = Status_Ok then
         Kind := Syscalls.Message.Words (1);
         for P in 0 .. 31 loop
            exit when P >= Name'Length;
            Ch := Character'Val (Natural
              ((Syscalls.Message.Words (2 + P / 8)
                  / Shift_Left (1, (P mod 8) * 8)) and 16#FF#));
            exit when Ch = Character'Val (0);
            Name_Len := Name_Len + 1;
            Name (Name'First + Name_Len - 1) := Ch;
         end loop;
      end if;
      return Syscalls.Message.Words (0);
   end Volume_List;

end Akernel_User.Files;
