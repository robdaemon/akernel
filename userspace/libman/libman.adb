with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Syscalls;
with Akernel_User.Files;
with Akernel_User.Tables;

--  Library manager (milestone 65 Tier-1 follow-up).
--  Amiga-style shared-library list: a single library server is
--  loaded per name, version-checked, and its service endpoint is
--  minted out to multiple clients.  Open/Close messages maintain the
--  reference count; at zero the manager closes its service cap and
--  the library server exits.

procedure Libman is
   use Akernel_User.Syscalls;
   use type U64;

   Console_Cap : constant U64 := 1;
   FS_Cap      : constant U64 := 2;
   Service_EP  : constant U64 := 3;  --  3rd manifest token
   --  (console fs libman_server). Was 6 ("uniform ABI") — handle 6
   --  is the CLIENT-side libman handle; the server's own Receive
   --  side landed at 3, so libman's first IPC_Recv failed and the
   --  manager never served a request (m75 found this).

   Max_Name      : constant := 64;

   type Library_Entry is record
      Name_Len    : Natural := 0;
      Name        : String (1 .. Max_Name) := (others => Character'Val (0));
      Version     : U64 := 0;
      Revision    : U64 := 0;
      Open_Count  : Natural := 0;
      Service_Cap : U64 := 0;  --  cap received from library server
      Process_Cap : U64 := 0;  --  to reap after expunge
   end record;

   --  m80f: chunk-appended (Akernel_User.Tables); Name_Len = 0 is
   --  the free marker (matches the zeroed default).
   package Ent_Tab is new Akernel_User.Tables (Library_Entry);
   function Entries (I : Natural) return Ent_Tab.Element_Access
     renames Ent_Tab.Ref;

   --  Request labels on the manager's service endpoint.
   Label_Req_Open  : constant U64 := 1;
   Label_Req_Close : constant U64 := 2;

   --  Reply labels.
   Label_Reply_Ok  : constant U64 := 1;
   Label_Reply_Fail : constant U64 := 0;

   Result : U64;

   function Pack_Name_40 (S : String) return IPC_Word_Array is
      W   : IPC_Word_Array := (others => 0);
      Len : constant Natural := Natural'Min (S'Length, 40);
   begin
      for I in 1 .. Len loop
         declare
            Word_Idx : constant Natural := (I - 1) / 8;
            Byte_Idx : constant Natural := (I - 1) mod 8;
         begin
            W (Word_Idx) := W (Word_Idx) or
              (U64 (Character'Pos (S (S'First + I - 1))) *
               U64 (2 ** (Byte_Idx * 8)));
         end;
      end loop;
      return W;
   end Pack_Name_40;

   function Entry_By_Name (Name : String) return Natural is
   begin
      for I in 1 .. Ent_Tab.Last loop
         if Entries (I).Name_Len = Name'Length
           and then Entries (I).Name_Len > 0
           and then Entries (I).Name (1 .. Entries (I).Name_Len) = Name
         then
            return I;
         end if;
      end loop;
      return 0;
   end Entry_By_Name;

   function Free_Entry return Natural is
   begin
      for I in 1 .. Ent_Tab.Last loop
         if Entries (I).Name_Len = 0 then
            return I;
         end if;
      end loop;
      return Ent_Tab.Append;   --  0 = arena OOM
   end Free_Entry;

   procedure Expunge (Index : Natural) is
      E : Library_Entry renames Entries (Index).all;
      Code : U64 := 0;
      Discard : U64;
   begin
      if E.Service_Cap /= 0 then
         --  m75: ask the library server to shut down first
         --  (libserv management label 0). Without it the reap poll
         --  below spins forever: the server's own endpoint cap
         --  keeps the refcount above zero, so the "last client
         --  closed -> Endpoint_Gone" exit can never fire. If the
         --  call fails the server is already gone; reap anyway.
         Message.Label := 0;  --  Libserv.Shutdown_Label
         Message.Words := (others => 0);
         Message.Caps := (others => 0);
         Message.Badge := 0;
         Discard := IPC_Call (E.Service_Cap);
         Result := Cap_Delete (E.Service_Cap);
      end if;
      if E.Process_Cap /= 0 then
         while Reap_Process_Code (E.Process_Cap, Code) /= 0 loop
            Yield;
         end loop;
         Result := Cap_Delete (E.Process_Cap);
      end if;
      E.Name_Len := 0;
      E.Version := 0;
      E.Revision := 0;
      E.Open_Count := 0;
      E.Service_Cap := 0;
      E.Process_Cap := 0;
   end Expunge;

   function Make_Args_Cap return U64 is
      Page_VA : constant U64 := 16#5A40_0000#;
      type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;
      Page : Byte_Array (0 .. 4095)
        with Address => System'To_Address
          (System.Storage_Elements.Integer_Address (Page_VA));
      Mem_Cap : U64;
      Discard : U64;
   begin
      Mem_Cap := Mem_Alloc (1);
      if Mem_Cap = Syscall_Failed then
         return 0;
      end if;
      if Mem_Map (Address_Space_Cap, Mem_Cap, Page_VA, 0, 4096, 3) /= 0
      then
         Discard := Cap_Delete (Mem_Cap);
         return 0;
      end if;
      Page := (others => 0);
      if Mem_Unmap (Address_Space_Cap, Page_VA, 4096) /= 0 then
         Discard := Cap_Delete (Mem_Cap);
         return 0;
      end if;
      return Mem_Cap;
   end Make_Args_Cap;

   function Stage (Path : String) return U64 is
      Stage_VA : constant U64 := 16#5A00_0000#;
      type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;
      Size    : U64 := 0;
      Pages   : U64;
      Mem_Cap : U64;
      Off     : U64 := 0;
      Chunk   : U64;
      Count   : U64 := 0;
      St      : U64;
      Discard : U64;
   begin
      St := Akernel_User.Files.Stat (Path, Size);
      if St /= Akernel_User.Files.Status_Ok or else Size = 0 then
         return 0;
      end if;

      Pages := (Size + 4095) / 4096;
      Mem_Cap := Mem_Alloc (Pages);
      if Mem_Cap = Syscall_Failed then
         return 0;
      end if;

      if Mem_Map (Address_Space_Cap, Mem_Cap, Stage_VA, 0,
                  Pages * 4096, 3) /= 0
      then
         Discard := Cap_Delete (Mem_Cap);
         return 0;
      end if;

      St := Akernel_User.Files.Open (Path, Size);
      while St = Akernel_User.Files.Status_Ok and then Off < Size loop
         Chunk := U64'Min (Size - Off, 32768);
         St := Akernel_User.Files.Read
           (Path, Off,
            System'To_Address
              (System.Storage_Elements.Integer_Address (Stage_VA + Off)),
            Chunk, Count);
         exit when St /= Akernel_User.Files.Status_Ok or else Count /= Chunk;
         Off := Off + Count;
      end loop;

      if Mem_Unmap (Address_Space_Cap, Stage_VA, Pages * 4096) /= 0
        or else Off < Size
      then
         Discard := Cap_Delete (Mem_Cap);
         return 0;
      end if;

      return Mem_Cap;
   end Stage;

   procedure Reply_Fail (Reply_H : U64) is
   begin
      Message.Label := Label_Reply_Fail;
      Message.Words := (others => 0);
      Message.Caps := (others => 0);
      Result := IPC_Reply (Reply_H);
   end Reply_Fail;

   procedure Load_And_Open
     (Name        : String;
      Min_Version : U64;
      Reply_H     : U64)
   is
      Idx     : constant Natural := Free_Entry;
      Image   : U64;
      Rendez  : U64;
      Args    : U64;
      Proc    : U64;
      Status  : U64;
      Client  : U64;
      Discard : U64;
      Lib_Reply_H : U64;
   begin
      if Idx = 0 then
         Reply_Fail (Reply_H);
         return;
      end if;

      Image := Stage (Name);
      if Image = 0 then
         Reply_Fail (Reply_H);
         return;
      end if;

      Rendez := EP_Create;
      if Rendez = Syscall_Failed then
         Discard := Cap_Delete (Image);
         Reply_Fail (Reply_H);
         return;
      end if;

      Args := Make_Args_Cap;
      if Args = 0 then
         Discard := Cap_Delete (Image);
         Discard := Cap_Delete (Rendez);
         Reply_Fail (Reply_H);
         return;
      end if;

      Set_Grant (0, Console_Cap, Right_Send, 0);
      Set_Grant (1, FS_Cap, Right_Send, 0);
      Set_Grant (2, Console_Cap, Right_Send, 0);
      Set_Grant (3, Args, Right_Map + Right_Read, 0);
      Set_Grant (4, Rendez,
                 Right_Send + Right_Receive + Right_Transfer, 0);

      if Spawn (Image, 5, Proc) /= Spawn_Ok then
         Discard := Cap_Delete (Args);
         Discard := Cap_Delete (Image);
         Discard := Cap_Delete (Rendez);
         Reply_Fail (Reply_H);
         return;
      end if;

      Discard := Cap_Delete (Image);
      Discard := Cap_Delete (Args);

      Status := IPC_Recv (Rendez, Lib_Reply_H);
      Discard := Cap_Delete (Rendez);

      if Status /= IPC_Ok or else Message.Caps (0) = 0 then
         if Proc /= 0 then
            Discard := Cap_Delete (Proc);
         end if;
         Reply_Fail (Reply_H);
         return;
      end if;

      declare
         Version  : constant U64 := Message.Words (0);
         Revision : constant U64 := Message.Words (1);
      begin
         if Version < Min_Version then
            Discard := Cap_Delete (Message.Caps (0));
            Discard := Cap_Delete (Proc);
            Reply_Fail (Reply_H);
            return;
         end if;

         --  m75: the mint needs Right_Transfer — the kernel's
         --  reply path (Transfer_Message) requires it.
         Client := Cap_Mint
           (Message.Caps (0), Right_Send + Right_Transfer, 0);
         if Client = Syscall_Failed then
            Discard := Cap_Delete (Message.Caps (0));
            Discard := Cap_Delete (Proc);
            Reply_Fail (Reply_H);
            return;
         end if;

         Entries (Idx).Name_Len := Name'Length;
         Entries (Idx).Name (1 .. Name'Length) := Name;
         Entries (Idx).Version := Version;
         Entries (Idx).Revision := Revision;
         Entries (Idx).Open_Count := 1;
         Entries (Idx).Service_Cap := Message.Caps (0);
         Entries (Idx).Process_Cap := Proc;

         Message.Label := Label_Reply_Ok;
         Message.Words := (others => 0);
         Message.Words (0) := Version;
         Message.Words (1) := Revision;
         Message.Caps := (0 => Client, others => 0);
         Result := IPC_Reply (Reply_H);
         --  Minted copies are deleted after the transfer (m75:
         --  the reply actually delivers the cap now).
         Discard := Cap_Delete (Client);
      end;
   end Load_And_Open;

   procedure Handle_Open
     (Name        : String;
      Min_Version : U64;
      Reply_H     : U64)
   is
      Idx     : constant Natural := Entry_By_Name (Name);
      Client  : U64;
      Discard : U64;
   begin
      if Idx /= 0 then
         if Entries (Idx).Version < Min_Version then
            Reply_Fail (Reply_H);
            return;
         end if;
         --  m75: Right_Transfer so the reply path can transfer.
         Client := Cap_Mint
           (Entries (Idx).Service_Cap, Right_Send + Right_Transfer, 0);
         if Client = Syscall_Failed then
            Reply_Fail (Reply_H);
            return;
         end if;
         Entries (Idx).Open_Count := Entries (Idx).Open_Count + 1;
         Message.Label := Label_Reply_Ok;
         Message.Words := (others => 0);
         Message.Words (0) := Entries (Idx).Version;
         Message.Words (1) := Entries (Idx).Revision;
         Message.Caps := (0 => Client, others => 0);
         Result := IPC_Reply (Reply_H);
         Discard := Cap_Delete (Client);  --  m75: transferred now
         return;
      end if;

      Load_And_Open (Name, Min_Version, Reply_H);
   end Handle_Open;

   procedure Handle_Close
     (Name    : String;
      Reply_H : U64)
   is
      Idx : constant Natural := Entry_By_Name (Name);
   begin
      if Idx = 0 then
         Message.Label := Label_Reply_Ok;
         Message.Words := (others => 0);
         Message.Caps := (others => 0);
         Result := IPC_Reply (Reply_H);
         return;
      end if;

      if Entries (Idx).Open_Count > 0 then
         Entries (Idx).Open_Count := Entries (Idx).Open_Count - 1;
      end if;

      if Entries (Idx).Open_Count = 0 then
         Expunge (Idx);
      end if;

      Message.Label := Label_Reply_Ok;
      Message.Words := (others => 0);
      Message.Caps := (others => 0);
      Result := IPC_Reply (Reply_H);
   end Handle_Close;

   Shutdown : Boolean := False;
   Status   : U64;
   Reply_H  : U64;
   Name     : String (1 .. 40);
   Name_Len : Natural;
begin
   Akernel_User.Files.Bind (FS_Cap);

   --  Wait for the Sys filesystem before accepting any library
   --  requests; FAT32 mounts are pushed asynchronously by init.
   declare
      Size   : U64 := 0;
      Status : U64;
   begin
      for Try in 1 .. 100_000 loop
         Status := Akernel_User.Files.Stat ("Sys:Libs", Size);
         if Status = Akernel_User.Files.Status_Ok then
            exit;
         end if;
         Yield;
      end loop;
   end;

   loop
      Status := IPC_Recv (Service_EP, Reply_H);
      if Status = IPC_Endpoint_Gone then
         exit;
      elsif Status /= IPC_Ok then
         exit;
      end if;

      Name_Len := 0;
      for I in 1 .. 40 loop
         declare
            Word_Idx : constant Natural := (I - 1) / 8;
            Byte_Idx : constant Natural := (I - 1) mod 8;
            Byte     : constant U64 :=
              (Message.Words (Word_Idx) /
                 U64 (2 ** (Byte_Idx * 8))) mod 256;
         begin
            exit when Byte = 0;
            Name (I) := Character'Val (Natural (Byte));
            Name_Len := I;
         end;
      end loop;

      case Message.Label is
         when Label_Req_Open =>
            if Name_Len > 0 then
               Handle_Open (Name (1 .. Name_Len), Message.Words (5), Reply_H);
            else
               Reply_Fail (Reply_H);
            end if;
         when Label_Req_Close =>
            if Name_Len > 0 then
               Handle_Close (Name (1 .. Name_Len), Reply_H);
            else
               Reply_Fail (Reply_H);
            end if;
         when others =>
            Reply_Fail (Reply_H);
      end case;

      exit when Shutdown;
   end loop;
end Libman;
