--  akernel BeFS server (milestone 82c read, 82e journaled write):
--  pure-Ada BeFS (Bfs_Engine) over the partition endpoint, behind
--  the file server's VFS. This unit is the wire-protocol front —
--  console, block RPC bounce buffer, fs protocol dispatch — in
--  the same shape as fat32.adb.
--
--  Handles: 1 = console endpoint, 2 = partN endpoint (badged
--  partition send cap), 3 = svc EP.

with Akernel_User.Console;
with Akernel_User.Syscalls;
with Bfs_Engine;
with Interfaces;
with System;
with System.Storage_Elements;

procedure Bfs is
   package Syscalls renames Akernel_User.Syscalls;
   use type Syscalls.U64;
   use type Interfaces.Unsigned_8;
   use System.Storage_Elements;

   subtype U64 is Syscalls.U64;

   --  Byte overlay for the client buffer window (attr header).
   type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;

   function Shl (Value : U64; Amount : Natural) return U64
     renames Interfaces.Shift_Left;

   Console_Cap : constant U64 := 1;
   Blk_EP      : constant U64 := 2;
   Svc_EP      : constant U64 := 3;

   Blk_Info  : constant U64 := 0;
   Blk_Flush : constant U64 := 4;

   Op_Stat        : constant U64 := 1;
   Op_Open        : constant U64 := 2;
   Op_Read        : constant U64 := 3;
   Op_Write       : constant U64 := 7;
   Op_Delete      : constant U64 := 8;
   Op_Truncate    : constant U64 := 9;
   Op_Mkdir       : constant U64 := 10;
   Op_Rmdir       : constant U64 := 11;
   Op_Sync        : constant U64 := 12;
   Op_ReadDir     : constant U64 := 13;
   Op_Rename      : constant U64 := 16;
    Op_Volume_Info : constant U64 := 17;
    Op_Attr_List   : constant U64 := 19;
    Op_Attr_Read   : constant U64 := 20;
    Op_Attr_Write  : constant U64 := 25;
     Op_Query       : constant U64 := 21;
     Op_Query_Open  : constant U64 := 22;
     Op_Query_Poll  : constant U64 := 23;
     Op_Query_Close : constant U64 := 24;

   Status_Ok           : constant U64 := 0;
   Status_Not_Found    : constant U64 := 1;
   Status_Bad_Args     : constant U64 := 3;
   Status_Out_Of_Range : constant U64 := 4;

   --  Bounce page for block RPCs (shared with the engine).
   Blk_Buf_VA  : constant U64 := 16#5380_0000#;
   Blk_Buf_Cap : U64 := 0;

   --  Mapping window for the client's read buffer mem object.
   Buf_Pages  : constant U64 := 4;
   Buf_Win_VA : constant U64 := 16#5400_0000#;
   Buf_Bytes  : constant U64 := Buf_Pages * Syscalls.Page_Size;

   Reply_H : U64 := 0;

   procedure Fail (Msg : String) is
   begin
      Akernel_User.Console.Put_Line (Msg);
      loop
         null;
      end loop;
   end Fail;

   procedure Reply2 (Status : U64; Value : U64) is
   begin
      Syscalls.Message.Words (0) := Status;
      Syscalls.Message.Words (1) := Value;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
         Fail ("bfs reply failed");
      end if;
   end Reply2;

   --  Unpack the path from message words First .. (First + 3).
   function Path_Of (First : Natural) return String is
      Name : String (1 .. 32) := (others => Character'Val (0));
      Len  : Natural := 0;
   begin
      for P in 0 .. 31 loop
         declare
            Ch : constant Character :=
              Character'Val (Natural
                ((Syscalls.Message.Words (First + P / 8)
                    / Shl (1, (P mod 8) * 8)) and 16#FF#));
         begin
            exit when Ch = Character'Val (0);
            Len := Len + 1;
            Name (Len) := Ch;
         end;
      end loop;
      return Name (1 .. Len);
   end Path_Of;

   ------------------------------------------------------------------
   --  Handlers
   ------------------------------------------------------------------

   procedure Handle_Stat_Or_Open is
      --  Capture the op BEFORE any engine call: block RPCs
      --  overwrite Syscalls.Message.
      Is_Open : constant Boolean :=
        Syscalls.Message.Label = Op_Open;
      Size   : U64;
      Is_Dir : Boolean;
      RC     : U64;
   begin
      declare
         Path : constant String := Path_Of (0);
      begin
         if Path'Length = 0 then
            Reply2 (Status_Bad_Args, 0);
            return;
         end if;
         RC := Bfs_Engine.Stat (Path, Size, Is_Dir);
      end;
      if RC /= Status_Ok then
         Reply2 (Status_Not_Found, 0);
         return;
      end if;
      if Is_Dir and then Is_Open then
         Reply2 (Status_Bad_Args, 0);  --  no dir open
         return;
      end if;
      Syscalls.Message.Words (4) := (if Is_Dir then 1 else 0);
      Reply2 (Status_Ok, Size);
   end Handle_Stat_Or_Open;

   procedure Handle_Read is
      Offset : constant U64 := Syscalls.Message.Words (0);
      Length : constant U64 := Syscalls.Message.Words (1);
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      Count  : U64 := 0;
      Status : U64 := Status_Ok;
      Mapped : Boolean := False;
   begin
      if Buf = 0 or else Length = 0 then
         Status := Status_Bad_Args;
      else
         declare
            Path : constant String := Path_Of (2);
            Len  : U64;
         begin
            if Path'Length = 0 then
               Status := Status_Bad_Args;
            elsif Syscalls.Mem_Map
              (Address_Space => Syscalls.Address_Space_Cap,
               Cap           => Buf,
               VA            => Buf_Win_VA,
               Offset        => 0,
               Length        => Buf_Bytes,
               Flags         => 3) /= 0
            then
               Status := Status_Not_Found;
            else
               Mapped := True;
               Len := U64'Min (Length, Buf_Bytes);
               Status := Bfs_Engine.Read
                 (Path, Offset,
                  To_Address (Integer_Address (Buf_Win_VA)), Len);
               if Status = Status_Ok then
                  Count := Len;
               end if;
            end if;
         end;
      end if;

      if Buf /= 0 then
         if Mapped
           and then Syscalls.Mem_Unmap
             (Address_Space => Syscalls.Address_Space_Cap,
              VA            => Buf_Win_VA,
              Length        => Buf_Bytes) /= 0
         then
            Akernel_User.Console.Put_Line ("bfs: buffer unmap failed");
         end if;
         if Syscalls.Cap_Delete (Buf) /= 0 then
            Akernel_User.Console.Put_Line ("bfs: buffer cap delete failed");
         end if;
      end if;
      Reply2 (Status, Count);
   end Handle_Read;

   --  Op_ReadDir: words 0..3 = path ("" = root), word 4 = index.
   --  Reply: w0 = status, w1 = size, w2 = is_dir, w3..5 = name.
   procedure Handle_Read_Dir is
      Idx      : constant U64 := Syscalls.Message.Words (4);
      Name     : String (1 .. 24) := (others => Character'Val (0));
      Name_Len : Natural;
      Size     : U64;
      Is_Dir   : Boolean;
      RC       : U64;
   begin
      declare
         Path : constant String := Path_Of (0);
      begin
         RC := Bfs_Engine.Read_Dir (Path, Idx, Name, Name_Len,
                                    Size, Is_Dir);
      end;
      if RC /= Status_Ok then
         Reply2 (Status_Not_Found, 0);
         return;
      end if;

      Syscalls.Message.Words (0) := Status_Ok;
      Syscalls.Message.Words (1) := Size;
      Syscalls.Message.Words (2) := (if Is_Dir then 1 else 0);
      for W in 3 .. 5 loop
         Syscalls.Message.Words (W) := 0;
      end loop;
      for P in 1 .. Name_Len loop
         Syscalls.Message.Words (3 + (P - 1) / 8) :=
           Syscalls.Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Name (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
         Fail ("bfs readdir reply failed");
      end if;
   end Handle_Read_Dir;

   --  Op_Attr_List (m82d): words 0..3 = path ("" = root), word 4
   --  = attribute index. Reply: w0 = status, w1 = type code,
   --  w2 = data size, w3..5 = attr name (24 chars).
   procedure Handle_Attr_List is
      Idx      : constant U64 := Syscalls.Message.Words (4);
      Name     : String (1 .. 24) := (others => Character'Val (0));
      Name_Len : Natural;
      AType    : U64;
      DSize    : U64;
      RC       : U64;
   begin
      declare
         Path : constant String := Path_Of (0);
      begin
         RC := Bfs_Engine.Attr_List (Path, Idx, Name, Name_Len,
                                     AType, DSize);
      end;
      if RC /= Status_Ok then
         Reply2 (Status_Not_Found, 0);
         return;
      end if;

      Syscalls.Message.Words (0) := Status_Ok;
      Syscalls.Message.Words (1) := AType;
      Syscalls.Message.Words (2) := DSize;
      for W in 3 .. 5 loop
         Syscalls.Message.Words (W) := 0;
      end loop;
      for P in 1 .. Name_Len loop
         Syscalls.Message.Words (3 + (P - 1) / 8) :=
           Syscalls.Message.Words (3 + (P - 1) / 8)
             or Shl (U64 (Character'Pos (Name (P))),
                     ((P - 1) mod 8) * 8);
      end loop;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
         Fail ("bfs attrlist reply failed");
      end if;
   end Handle_Attr_List;

   --  Op_Attr_Read (m82d): words 0..3 = path, words 4..5 = attr
   --  name (16 chars), cap slot 0 = buffer memobj. Reply: w0 =
   --  status, w1 = count copied, w2 = attr total size, w3 = type
   --  code.
   procedure Handle_Attr_Read is
      Buf    : constant U64 := Syscalls.Message.Caps (0);
      Count  : U64 := 0;
      DSize  : U64 := 0;
      AType  : U64 := 0;
      Status : U64 := Status_Ok;
      Mapped : Boolean := False;
   begin
      if Buf = 0 then
         Status := Status_Bad_Args;
      else
         declare
            Path : constant String := Path_Of (0);
            Attr : String (1 .. 16) := (others => Character'Val (0));
            ALen : Natural := 0;
         begin
            for P in 0 .. 15 loop
               declare
                  Ch : constant Character :=
                    Character'Val (Natural
                      ((Syscalls.Message.Words (4 + P / 8)
                          / Shl (1, (P mod 8) * 8)) and 16#FF#));
               begin
                  exit when Ch = Character'Val (0);
                  ALen := ALen + 1;
                  Attr (ALen) := Ch;
               end;
            end loop;
            if ALen = 0 then  --  path "" = volume root, like ReadDir
               Status := Status_Bad_Args;
            elsif Syscalls.Mem_Map
              (Address_Space => Syscalls.Address_Space_Cap,
               Cap           => Buf,
               VA            => Buf_Win_VA,
               Offset        => 0,
               Length        => Buf_Bytes,
               Flags         => 3) /= 0
            then
               Status := Status_Not_Found;
            else
               Mapped := True;
               Status := Bfs_Engine.Attr_Read
                 (Path, Attr (1 .. ALen),
                  To_Address (Integer_Address (Buf_Win_VA)), Buf_Bytes,
                  Count, DSize, AType);
            end if;
         end;
      end if;

      if Buf /= 0 then
         if Mapped
           and then Syscalls.Mem_Unmap
             (Address_Space => Syscalls.Address_Space_Cap,
              VA            => Buf_Win_VA,
              Length        => Buf_Bytes) /= 0
         then
            Akernel_User.Console.Put_Line
              ("bfs: attr buffer unmap failed");
         end if;
         if Syscalls.Cap_Delete (Buf) /= 0 then
            Akernel_User.Console.Put_Line
              ("bfs: attr buffer cap delete failed");
         end if;
      end if;

      Syscalls.Message.Words (0) := Status;
      Syscalls.Message.Words (1) := Count;
      Syscalls.Message.Words (2) := DSize;
      Syscalls.Message.Words (3) := AType;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
         Fail ("bfs attrread reply failed");
      end if;
   end Handle_Attr_Read;

    ------------------------------------------------------------------
    --  Write path (m82e)
    ------------------------------------------------------------------

    --  Op_Write: word 0 = offset, word 1 = length, words 2..5 =
    --  path, cap slot 0 = buffer mem object (the bytes move FROM
    --  it). Creates missing files when the parent resolves.
    procedure Handle_Write is
       Offset : constant U64 := Syscalls.Message.Words (0);
       Length : constant U64 := Syscalls.Message.Words (1);
       Buf    : constant U64 := Syscalls.Message.Caps (0);
       Count  : U64 := 0;
       Status : U64 := Status_Ok;
       Mapped : Boolean := False;
    begin
       if Buf = 0 or else Length = 0 then
          Status := Status_Bad_Args;
       else
          declare
             Path : constant String := Path_Of (2);
             Len  : U64;
          begin
             if Path'Length = 0 then
                Status := Status_Bad_Args;
             elsif Syscalls.Mem_Map
               (Address_Space => Syscalls.Address_Space_Cap,
                Cap           => Buf,
                VA            => Buf_Win_VA,
                Offset        => 0,
                Length        => Buf_Bytes,
                Flags         => 3) /= 0
             then
                Status := Status_Not_Found;
             else
                Mapped := True;
                Len := U64'Min (Length, Buf_Bytes);
                Status := Bfs_Engine.Write
                  (Path, Offset,
                   To_Address (Integer_Address (Buf_Win_VA)), Len);
                if Status = Status_Ok then
                   Count := Len;
                end if;
             end if;
          end;
       end if;

       if Buf /= 0 then
          if Mapped
            and then Syscalls.Mem_Unmap
              (Address_Space => Syscalls.Address_Space_Cap,
               VA            => Buf_Win_VA,
               Length        => Buf_Bytes) /= 0
          then
             Akernel_User.Console.Put_Line ("bfs: buffer unmap failed");
          end if;
          if Syscalls.Cap_Delete (Buf) /= 0 then
             Akernel_User.Console.Put_Line ("bfs: buffer cap delete failed");
          end if;
       end if;
       Reply2 (Status, Count);
    end Handle_Write;

    --  Op_Attr_Write (m82h): words 0..3 = path, words 4..5 = attr
    --  name (16 chars), cap slot 0 = buffer mem object holding
    --  le64 type fourcc @0, le64 data length @8, then the data
    --  bytes. Length 0 removes the attribute. Reply: w0 = status.
    procedure Handle_Attr_Write is
       Buf    : constant U64 := Syscalls.Message.Caps (0);
       Status : U64 := Status_Ok;
       Mapped : Boolean := False;
    begin
       if Buf = 0 then
          Status := Status_Bad_Args;
       else
          declare
             Path : constant String := Path_Of (0);
             Attr : String (1 .. 16) := (others => Character'Val (0));
             ALen  : Natural := 0;
             AType : U64 := 0;
             DLen  : U64 := 0;
          begin
             for P in 0 .. 15 loop
                declare
                   Ch : constant Character :=
                     Character'Val (Natural
                       ((Syscalls.Message.Words (4 + P / 8)
                           / Shl (1, (P mod 8) * 8)) and 16#FF#));
                begin
                   exit when Ch = Character'Val (0);
                   ALen := ALen + 1;
                   Attr (ALen) := Ch;
                end;
             end loop;
             if ALen = 0 then
                Status := Status_Bad_Args;
             elsif Syscalls.Mem_Map
               (Address_Space => Syscalls.Address_Space_Cap,
                Cap           => Buf,
                VA            => Buf_Win_VA,
                Offset        => 0,
                Length        => Buf_Bytes,
                Flags         => 3) /= 0
             then
                Status := Status_Not_Found;
             else
                Mapped := True;
                declare
                   Win : Byte_Array (0 .. 15)
                     with Address =>
                       To_Address (Integer_Address (Buf_Win_VA));
                begin
                   for I in 0 .. 7 loop
                      AType := AType
                        or Shl (U64 (Win (U64 (I))), I * 8);
                      DLen := DLen
                        or Shl (U64 (Win (U64 (8 + I))), I * 8);
                   end loop;
                end;
                if DLen > Buf_Bytes - 16 then
                   Status := Status_Bad_Args;
                else
                   Status := Bfs_Engine.Attr_Write
                     (Path, Attr (1 .. ALen), AType,
                      To_Address (Integer_Address (Buf_Win_VA + 16)),
                      DLen);
                end if;
             end if;
          end;
       end if;

       if Buf /= 0 then
          if Mapped
            and then Syscalls.Mem_Unmap
              (Address_Space => Syscalls.Address_Space_Cap,
               VA            => Buf_Win_VA,
               Length        => Buf_Bytes) /= 0
          then
             Akernel_User.Console.Put_Line
               ("bfs: attr buffer unmap failed");
          end if;
          if Syscalls.Cap_Delete (Buf) /= 0 then
             Akernel_User.Console.Put_Line
               ("bfs: attr buffer cap delete failed");
          end if;
       end if;
       Reply2 (Status, 0);
    end Handle_Attr_Write;

    --  Path-only mutating ops: Delete, Truncate, Mkdir, Rmdir.
    procedure Handle_Path_Op is
       Op : constant U64 := Syscalls.Message.Label;
       RC : U64;
    begin
       declare
          Path : constant String := Path_Of (0);
       begin
          if Path'Length = 0 then
             Reply2 (Status_Bad_Args, 0);
             return;
          end if;
          if Op = Op_Delete then
             RC := Bfs_Engine.Delete (Path);
          elsif Op = Op_Truncate then
             RC := Bfs_Engine.Truncate (Path);
          elsif Op = Op_Mkdir then
             RC := Bfs_Engine.Mkdir (Path);
          else
             RC := Bfs_Engine.Rmdir (Path);
          end if;
       end;
       Reply2 (RC, 0);
    end Handle_Path_Op;

    --  Op_Rename: FROM path in words 0..5, bare TO path NUL-
    --  terminated in the buffer (cap slot 0), same as fat32.
    procedure Handle_Rename is
       Buf    : constant U64 := Syscalls.Message.Caps (0);
       Status : U64 := Status_Ok;
       Mapped : Boolean := False;
       Win    : array (0 .. 47) of Interfaces.Unsigned_8
         with Address => To_Address (Integer_Address (Buf_Win_VA));
    begin
       declare
          From   : constant String := Path_Of (0);
          To     : String (1 .. 32);
          To_Len : Natural := 0;
       begin
          if From'Length = 0 or else Buf = 0 then
             Status := Status_Bad_Args;
          elsif Syscalls.Mem_Map
            (Address_Space => Syscalls.Address_Space_Cap,
             Cap           => Buf,
             VA            => Buf_Win_VA,
             Offset        => 0,
             Length        => Buf_Bytes,
             Flags         => 3) /= 0
          then
             Status := Status_Not_Found;
          else
             Mapped := True;
             for I in 0 .. 31 loop
                exit when Win (I) = Interfaces.Unsigned_8 (0);
                To_Len := To_Len + 1;
                To (To_Len) := Character'Val (Natural (Win (I)));
             end loop;
             if To_Len = 0 then
                Status := Status_Bad_Args;
             else
                Status := Bfs_Engine.Rename (From, To (1 .. To_Len));
             end if;
          end if;
       end;

       if Buf /= 0 then
          if Mapped
            and then Syscalls.Mem_Unmap
              (Address_Space => Syscalls.Address_Space_Cap,
               VA            => Buf_Win_VA,
               Length        => Buf_Bytes) /= 0
          then
             Akernel_User.Console.Put_Line ("bfs: buffer unmap failed");
          end if;
          if Syscalls.Cap_Delete (Buf) /= 0 then
             Akernel_User.Console.Put_Line ("bfs: buffer cap delete failed");
          end if;
       end if;
       Reply2 (Status, 0);
    end Handle_Rename;

    --  Op_Query (m82f, buffer path in m82g): words 0..3 = path
    --  (the volume root ""), word 4 = match index, cap slot 0 =
    --  buffer holding the NUL-terminated predicate. Reply: w0 =
    --  status, w1 = size, w2 = is_dir, w3 = path length; the
    --  volume-relative path is written back into the buffer.
    procedure Handle_Query is
       Idx    : constant U64 := Syscalls.Message.Words (4);
       Buf    : constant U64 := Syscalls.Message.Caps (0);
       Status : U64 := Status_Ok;
       Mapped : Boolean := False;
       Win    : array (0 .. 255) of Interfaces.Unsigned_8
         with Address => To_Address (Integer_Address (Buf_Win_VA));
       Path     : String (1 .. 255) := (others => Character'Val (0));
       Path_Len : Natural := 0;
       Size     : U64;
       Is_Dir   : Boolean;
     begin
        declare
           Vol_Path : constant String := Path_Of (0);
           Pred     : String (1 .. 255);
           Pred_Len : Natural := 0;
        begin
           if Vol_Path'Length /= 0 or else Buf = 0 then
              Status := Status_Bad_Args;  --  queries are volume-wide
           elsif Syscalls.Mem_Map
             (Address_Space => Syscalls.Address_Space_Cap,
              Cap           => Buf,
              VA            => Buf_Win_VA,
              Offset        => 0,
              Length        => Buf_Bytes,
              Flags         => 3) /= 0
           then
              Status := Status_Not_Found;
           else
              Mapped := True;
              for I in 0 .. 254 loop
                 exit when Win (I) = Interfaces.Unsigned_8 (0);
                 Pred_Len := Pred_Len + 1;
                 Pred (Pred_Len) := Character'Val (Natural (Win (I)));
              end loop;
              if Pred_Len = 0 then
                 Status := Status_Bad_Args;
              else
                 Status := Bfs_Engine.Query
                   (Pred (1 .. Pred_Len), Idx, Path, Path_Len,
                    Size, Is_Dir);
                 if Status = Status_Ok then
                    for I in 1 .. Path_Len loop
                       Win (I - 1) :=
                         Interfaces.Unsigned_8 (Character'Pos (Path (I)));
                    end loop;
                 end if;
              end if;
           end if;
        end;

       if Buf /= 0 then
          if Mapped
            and then Syscalls.Mem_Unmap
              (Address_Space => Syscalls.Address_Space_Cap,
               VA            => Buf_Win_VA,
               Length        => Buf_Bytes) /= 0
          then
             Akernel_User.Console.Put_Line
               ("bfs: query buffer unmap failed");
          end if;
          if Syscalls.Cap_Delete (Buf) /= 0 then
             Akernel_User.Console.Put_Line
               ("bfs: query buffer cap delete failed");
          end if;
       end if;

       if Status /= Status_Ok then
          Reply2 (Status, 0);
          return;
       end if;
        Syscalls.Message.Words (0) := Status_Ok;
        Syscalls.Message.Words (1) := Size;
        Syscalls.Message.Words (2) := (if Is_Dir then 1 else 0);
        Syscalls.Message.Words (3) := U64 (Path_Len);
        Syscalls.Message.Caps := (others => 0);
       if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
          Fail ("bfs query reply failed");
       end if;
    end Handle_Query;

    --  Op_Query_Open (m82g): words 0..3 = path (the volume root
    --  ""), cap 0 = buffer with the NUL-terminated predicate,
    --  cap 1 = the client's notification cap (on success the
    --  engine keeps it and rings bit 0 on queued events; on
    --  failure it is deleted here). Reply: w0 = status, w1 =
    --  live-query handle (1-based).
    procedure Handle_Query_Open is
       Buf    : constant U64 := Syscalls.Message.Caps (0);
       Ntfn   : constant U64 := Syscalls.Message.Caps (1);
       Status : U64 := Status_Bad_Args;
       Mapped : Boolean := False;
       Handle : U64 := 0;
       Win    : array (0 .. 255) of Interfaces.Unsigned_8
         with Address => To_Address (Integer_Address (Buf_Win_VA));
    begin
       declare
          Vol_Path : constant String := Path_Of (0);
          Pred     : String (1 .. 255);
          Pred_Len : Natural := 0;
       begin
          if Vol_Path'Length /= 0 or else Buf = 0 or else Ntfn = 0
          then
             Status := Status_Bad_Args;
          elsif Syscalls.Mem_Map
            (Address_Space => Syscalls.Address_Space_Cap,
             Cap           => Buf,
             VA            => Buf_Win_VA,
             Offset        => 0,
             Length        => Buf_Bytes,
             Flags         => 3) /= 0
          then
             Status := Status_Not_Found;
          else
             Mapped := True;
             for I in 0 .. 254 loop
                exit when Win (I) = Interfaces.Unsigned_8 (0);
                Pred_Len := Pred_Len + 1;
                Pred (Pred_Len) := Character'Val (Natural (Win (I)));
             end loop;
             if Pred_Len = 0 then
                Status := Status_Bad_Args;
             else
                Status := Bfs_Engine.Live_Open
                  (Pred (1 .. Pred_Len), Ntfn, Handle);
             end if;
          end if;
       end;

       if Buf /= 0 then
          if Mapped
            and then Syscalls.Mem_Unmap
              (Address_Space => Syscalls.Address_Space_Cap,
               VA            => Buf_Win_VA,
               Length        => Buf_Bytes) /= 0
          then
             Akernel_User.Console.Put_Line
               ("bfs: query open buffer unmap failed");
          end if;
          if Syscalls.Cap_Delete (Buf) /= 0 then
             Akernel_User.Console.Put_Line
               ("bfs: query open buffer cap delete failed");
          end if;
       end if;
       if Status /= Status_Ok and then Ntfn /= 0 then
          --  The engine did not take the notification cap.
          if Syscalls.Cap_Delete (Ntfn) /= 0 then
             Akernel_User.Console.Put_Line
               ("bfs: query open ntfn cap delete failed");
          end if;
       end if;
       Reply2 (Status, Handle);
    end Handle_Query_Open;

    --  Op_Query_Poll (m82g): word 4 = handle, cap 0 = buffer for
    --  the reply path. Reply: w0 = status, w1 = event kind
    --  (1 = added, 2 = removed, 3 = resync), w2 = path length,
    --  path bytes in the buffer.
    procedure Handle_Query_Poll is
       Handle : constant U64 := Syscalls.Message.Words (4);
       Buf    : constant U64 := Syscalls.Message.Caps (0);
       Status : U64 := Status_Bad_Args;
       Mapped : Boolean := False;
       Kind   : U64 := 0;
       Path   : String (1 .. 255);
       P_Len  : Natural := 0;
       Win    : array (0 .. 255) of Interfaces.Unsigned_8
         with Address => To_Address (Integer_Address (Buf_Win_VA));
    begin
       if Buf = 0 then
          Status := Status_Bad_Args;
       elsif Syscalls.Mem_Map
         (Address_Space => Syscalls.Address_Space_Cap,
          Cap           => Buf,
          VA            => Buf_Win_VA,
          Offset        => 0,
          Length        => Buf_Bytes,
          Flags         => 3) /= 0
       then
          Status := Status_Not_Found;
       else
          Mapped := True;
          Status := Bfs_Engine.Live_Poll (Handle, Kind, Path, P_Len);
          if Status = Status_Ok then
             for I in 1 .. P_Len loop
                Win (I - 1) :=
                  Interfaces.Unsigned_8 (Character'Pos (Path (I)));
             end loop;
          end if;
          if Syscalls.Mem_Unmap
            (Address_Space => Syscalls.Address_Space_Cap,
             VA            => Buf_Win_VA,
             Length        => Buf_Bytes) /= 0
          then
             Akernel_User.Console.Put_Line
               ("bfs: query poll buffer unmap failed");
          end if;
          if Syscalls.Cap_Delete (Buf) /= 0 then
             Akernel_User.Console.Put_Line
               ("bfs: query poll buffer cap delete failed");
          end if;
       end if;
       Syscalls.Message.Words (0) := Status;
       Syscalls.Message.Words (1) := Kind;
       Syscalls.Message.Words (2) := U64 (P_Len);
       Syscalls.Message.Caps := (others => 0);
       if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
          Fail ("bfs query poll reply failed");
       end if;
    end Handle_Query_Poll;

    --  Op_Query_Close (m82g): word 4 = handle. The subscription
    --  and its notification cap copy are released.
    procedure Handle_Query_Close is
    begin
       Bfs_Engine.Live_Close (Syscalls.Message.Words (4));
       Reply2 (Status_Ok, 0);
    end Handle_Query_Close;

    procedure Handle_Volume_Info is
      Total : U64;
      Free  : U64;
      Block : U64;
   begin
      Bfs_Engine.Volume_Info (Total, Free, Block);
      if not Bfs_Engine.Mounted then
         Reply2 (Status_Not_Found, 0);
         return;
      end if;
      Syscalls.Message.Words (0) := Status_Ok;
      Syscalls.Message.Words (1) := Total;
      Syscalls.Message.Words (2) := Free;
      Syscalls.Message.Words (3) := Block;
      Syscalls.Message.Caps := (others => 0);
      if Syscalls.IPC_Reply (Reply_H) /= Syscalls.IPC_Ok then
         Fail ("bfs volume info reply failed");
      end if;
   end Handle_Volume_Info;

begin
   Akernel_User.Console.Set_Endpoint (Console_Cap);
   Akernel_User.Console.Put_Line ("bfs starting");

   Blk_Buf_Cap := Syscalls.Mem_Alloc (1);
   if Blk_Buf_Cap = Syscalls.Syscall_Failed
     or else Syscalls.Mem_Map
       (Address_Space => Syscalls.Address_Space_Cap,
        Cap           => Blk_Buf_Cap,
        VA            => Blk_Buf_VA,
        Offset        => 0,
        Length        => Syscalls.Page_Size,
        Flags         => 3) /= 0
   then
      Fail ("bfs bounce alloc failed");
   end if;

   --  Partition probe (proves the endpoint is live), then mount.
   Syscalls.Message.Label := Blk_Info;
   Syscalls.Message.Caps := (others => 0);
   if Syscalls.IPC_Call (Blk_EP) /= Syscalls.IPC_Ok
     or else Syscalls.Message.Words (0) /= 0
   then
      Fail ("bfs blk probe failed");
   end if;

   Bfs_Engine.Init (Blk_EP, Blk_Buf_Cap);
   if not Bfs_Engine.Mounted then
      Fail ("bfs no filesystem on partition");
   end if;

   Akernel_User.Console.Put_Line ("bfs online");

   loop
      if Syscalls.IPC_Recv (Svc_EP, Reply_H) /= Syscalls.IPC_Ok then
         Fail ("bfs recv failed");
      end if;

      if Syscalls.Message.Label = Op_Stat
        or else Syscalls.Message.Label = Op_Open
      then
         Handle_Stat_Or_Open;
      elsif Syscalls.Message.Label = Op_Read then
         Handle_Read;
      elsif Syscalls.Message.Label = Op_ReadDir then
         Handle_Read_Dir;
      elsif Syscalls.Message.Label = Op_Attr_List then
         Handle_Attr_List;
      elsif Syscalls.Message.Label = Op_Attr_Read then
         Handle_Attr_Read;
      elsif Syscalls.Message.Label = Op_Attr_Write then
         Handle_Attr_Write;
      elsif Syscalls.Message.Label = Op_Volume_Info then
         Handle_Volume_Info;
      elsif Syscalls.Message.Label = Op_Sync then
         Syscalls.Message.Label := Blk_Flush;
         Syscalls.Message.Caps := (others => 0);
         if Syscalls.IPC_Call (Blk_EP) = Syscalls.IPC_Ok
           and then Syscalls.Message.Words (0) = 0
         then
            Reply2 (Status_Ok, 0);
         else
            Reply2 (Status_Bad_Args, 0);
         end if;
      elsif Syscalls.Message.Label = Op_Write then
         Handle_Write;
      elsif Syscalls.Message.Label = Op_Delete
        or else Syscalls.Message.Label = Op_Truncate
        or else Syscalls.Message.Label = Op_Mkdir
        or else Syscalls.Message.Label = Op_Rmdir
      then
         Handle_Path_Op;
      elsif Syscalls.Message.Label = Op_Rename then
         Handle_Rename;
       elsif Syscalls.Message.Label = Op_Query then
          Handle_Query;
       elsif Syscalls.Message.Label = Op_Query_Open then
          Handle_Query_Open;
       elsif Syscalls.Message.Label = Op_Query_Poll then
          Handle_Query_Poll;
       elsif Syscalls.Message.Label = Op_Query_Close then
          Handle_Query_Close;
      else
         Reply2 (Status_Bad_Args, 0);
      end if;
   end loop;
end Bfs;
