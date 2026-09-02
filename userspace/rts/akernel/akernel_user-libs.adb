with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Files;
with Akernel_User.Syscalls;
with Akernel_User.Tables;

use System.Storage_Elements;

package body Akernel_User.Libs is

   use Syscalls;
   use type U64;

   Stage_VA : constant U64 := 16#5A00_0000#;
   Args_VA  : constant U64 := 16#5A40_0000#;
   Libman_Handle : constant U64 := 6;

   Bound_Libman : U64 := 0;

   type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;

   --  Per-process open table: needed only so Close_Library knows
   --  whether a handle was obtained through the shared manager or
   --  by a private spawn. m80f: chunk-appended; Cap = 0 is the
   --  free marker (matches the zeroed default).
   Max_Name : constant := 64;

   type Open_Source is (From_Libman, From_Self);

   type Open_Entry is record
      Name_Len : Natural := 0;
      Name     : String (1 .. Max_Name) := (others => Character'Val (0));
      Cap      : U64 := 0;
      Source   : Open_Source := From_Self;
   end record;

   package Open_Tab is new Akernel_User.Tables (Open_Entry);
   function Open_Table (I : Natural) return Open_Tab.Element_Access
     renames Open_Tab.Ref;

   --  Manager request labels (must match userspace/libman).
   Req_Open  : constant U64 := 1;
   Req_Close : constant U64 := 2;

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

   function Manager_Cap return U64 is
   begin
      if Bound_Libman /= 0 then
         return Bound_Libman;
      end if;
      return Libman_Handle;
   end Manager_Cap;

   function Libman_Available return Boolean is
      Probe : constant U64 :=
        Cap_Mint (Manager_Cap, Right_Send + Right_Transfer, 0);
      Result : U64;
   begin
      if Probe = Syscall_Failed then
         return False;
      end if;
      Result := Cap_Delete (Probe);
      return True;
   end Libman_Available;

   function Find_Entry (Cap : U64) return Natural is
   begin
      for I in 1 .. Open_Tab.Last loop
         if Open_Table (I).Cap = Cap then
            return I;
         end if;
      end loop;
      return 0;
   end Find_Entry;

   function Add_Entry
     (Name   : String;
      Cap    : U64;
      Source : Open_Source) return Boolean
   is
      Len : constant Natural := Natural'Min (Name'Length, Max_Name);
   begin
      for I in 1 .. Open_Tab.Last loop
         if Open_Table (I).Cap = 0 then
            Open_Table (I).Name_Len := Len;
            if Len > 0 then
               Open_Table (I).Name (1 .. Len) :=
                 Name (Name'First .. Name'First + Len - 1);
            end if;
            Open_Table (I).Cap := Cap;
            Open_Table (I).Source := Source;
            return True;
         end if;
      end loop;
      declare
         Slot : constant Natural := Open_Tab.Append;  --  0 = OOM
      begin
         if Slot = 0 then
            return False;
         end if;
         Open_Table (Slot).Name_Len := Len;
         if Len > 0 then
            Open_Table (Slot).Name (1 .. Len) :=
              Name (Name'First .. Name'First + Len - 1);
         end if;
         Open_Table (Slot).Cap := Cap;
         Open_Table (Slot).Source := Source;
         return True;
      end;
   end Add_Entry;

   procedure Remove_Entry (Cap : U64) is
   begin
      for I in 1 .. Open_Tab.Last loop
         if Open_Table (I).Cap = Cap then
            Open_Table (I).Cap := 0;
            Open_Table (I).Name_Len := 0;
            return;
         end if;
      end loop;
   end Remove_Entry;

   --  Stage a file from the file server into a fresh memory object
   --  suitable for spawning. Returns the memory-object cap or 0 on
   --  failure.
   function Stage (Path : String) return U64 is
      Name    : String (1 .. 160);
      NLen    : Natural;
      Size    : U64 := 0;
      Pages   : U64;
      Mem_Cap : U64;
      Off     : U64 := 0;
      Chunk   : U64;
      Count   : U64 := 0;
      St      : U64;
      Result  : U64;
   begin
      St := Files.Stat (Path, Size);
      if St /= Files.Status_Ok or else Size = 0 then
         return 0;
      end if;

      NLen := Natural'Min (Path'Length, Name'Length);
      Name (1 .. NLen) := Path (Path'First .. Path'First + NLen - 1);

      Pages := (Size + 4095) / 4096;
      Mem_Cap := Mem_Alloc (Pages);
      if Mem_Cap = Syscall_Failed then
         return 0;
      end if;

      if Mem_Map (Address_Space_Cap, Mem_Cap, Stage_VA, 0,
                  Pages * 4096, 3) /= 0
      then
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;

      St := Files.Open (Name (1 .. NLen), Size);
      while St = Files.Status_Ok and then Off < Size loop
         Chunk := U64'Min (Size - Off, 32768);
         St := Files.Read
           (Name (1 .. NLen), Off,
            System'To_Address (Integer_Address (Stage_VA + Off)),
            Chunk, Count);
         exit when St /= Files.Status_Ok or else Count /= Chunk;
         Off := Off + Count;
      end loop;

      if Mem_Unmap (Address_Space_Cap, Stage_VA, Pages * 4096) /= 0
        or else Off < Size
      then
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;

      return Mem_Cap;
   end Stage;

   --  Create an empty one-page argument object for the uniform ABI.
   function Make_Args_Cap return U64 is
      Page    : Byte_Array (0 .. 4095)
        with Address => System'To_Address (Integer_Address (Args_VA));
      Mem_Cap : U64;
      Result  : U64;
   begin
      Mem_Cap := Mem_Alloc (1);
      if Mem_Cap = Syscall_Failed then
         return 0;
      end if;
      if Mem_Map (Address_Space_Cap, Mem_Cap, Args_VA, 0, 4096, 3) /= 0 then
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;

      Page := (others => 0);  --  empty argument string, NUL at byte 0

      if Mem_Unmap (Address_Space_Cap, Args_VA, 4096) /= 0 then
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;

      return Mem_Cap;
   end Make_Args_Cap;

   procedure Bind (Libman_Cap : U64) is
   begin
      Bound_Libman := Libman_Cap;
   end Bind;

   function Open_Via_Libman
     (Name        : String;
      Min_Version : U64) return U64
   is
      Status  : U64;
      Service : U64;
   begin
      Message.Label := Req_Open;
      Message.Words := Pack_Name_40 (Name);
      Message.Words (5) := Min_Version;
      Message.Caps := (others => 0);
      Message.Badge := 0;

      Status := IPC_Call (Manager_Cap);
      if Status /= IPC_Ok or else Message.Label /= 1 then
         return 0;
      end if;

      Service := Message.Caps (0);
      if Service = 0 then
         return 0;
      end if;

      if Add_Entry (Name, Service, From_Libman) then
         return Service;
      end if;

      --  Table full: clean up and fail.
      Status := Cap_Delete (Service);
      return 0;
   end Open_Via_Libman;

   procedure Close_Via_Libman (Name : String) is
      Status : U64;
      Result : U64;
   begin
      Message.Label := Req_Close;
      Message.Words := Pack_Name_40 (Name);
      Message.Caps := (others => 0);
      Message.Badge := 0;
      Status := IPC_Call (Manager_Cap);
      Result := Status;  --  ignore failures
   end Close_Via_Libman;

   function Open_Via_Self
     (Name        : String;
      Console_Cap : U64;
      FS_Cap      : U64;
      Bureau_Cap  : U64;
      Min_Version : U64) return U64
   is
      Image      : U64;
      Rendezvous : U64;
      Args_Cap   : U64;
      Proc       : U64;
      Service    : U64;
      Status     : U64;
      Reply_H    : U64;
      Result     : U64;
      Version    : U64;
   begin
      Image := Stage (Name);
      if Image = 0 then
         return Invalid_Handle;
      end if;

      Rendezvous := EP_Create;
      if Rendezvous = Syscall_Failed then
         Result := Cap_Delete (Image);
         return Invalid_Handle;
      end if;

      Args_Cap := Make_Args_Cap;
      if Args_Cap = 0 then
         Result := Cap_Delete (Image);
         Result := Cap_Delete (Rendezvous);
         return Invalid_Handle;
      end if;

      Set_Grant (0, Console_Cap, Right_Send, 0);
      Set_Grant (1, FS_Cap, Right_Send, 0);
      Set_Grant (2,
                 (if Bureau_Cap /= 0 then Bureau_Cap else Console_Cap),
                 Right_Send, 0);
      Set_Grant (3, Args_Cap, Right_Read or Right_Map, 0);
      Set_Grant (4, Rendezvous,
                 Right_Send or Right_Receive or Right_Transfer, 0);

      if Spawn (Image, 5, Proc) /= Spawn_Ok then
         Result := Cap_Delete (Args_Cap);
         Result := Cap_Delete (Image);
         Result := Cap_Delete (Rendezvous);
         return Invalid_Handle;
      end if;

      Status := IPC_Recv (Rendezvous, Reply_H);
      if Status /= IPC_Ok then
         Result := Cap_Delete (Args_Cap);
         Result := Cap_Delete (Image);
         Result := Cap_Delete (Rendezvous);
         Result := Cap_Delete (Proc);
         return Invalid_Handle;
      end if;

      Service := Message.Caps (0);
      Version := Message.Words (0);
      if Service = 0 or else Version < Min_Version then
         Result := Cap_Delete (Args_Cap);
         Result := Cap_Delete (Image);
         Result := Cap_Delete (Rendezvous);
         Result := Cap_Delete (Proc);
         if Service /= 0 then
            Result := Cap_Delete (Service);
         end if;
         return Invalid_Handle;
      end if;

      Result := Cap_Delete (Args_Cap);
      Result := Cap_Delete (Image);
      Result := Cap_Delete (Rendezvous);
      Result := Cap_Delete (Proc);

      if Add_Entry (Name, Service, From_Self) then
         return Service;
      end if;
      Result := Cap_Delete (Service);
      return Invalid_Handle;
   end Open_Via_Self;

   ----------------
   -- Open_Library --
   ----------------

   function Open_Library
     (Name        : String;
      Console_Cap : U64 := 1;
      FS_Cap      : U64 := 2;
      Bureau_Cap  : U64 := 3;
      Min_Version : U64 := 0) return U64
   is
      Service : U64;
      Result  : U64;
   begin
      Files.Bind (FS_Cap);

      --  Prefer the shared library manager when available.
      if Libman_Available then
         Service := Open_Via_Libman (Name, Min_Version);
         if Service /= 0 then
            return Service;
         end if;
         --  If the manager is present but unreachable, fall back to
         --  a private copy.  If the manager answered with a clean
         --  failure (e.g. not found), we do NOT fall back.
      end if;

      Service := Open_Via_Self
        (Name, Console_Cap, FS_Cap, Bureau_Cap, Min_Version);
      if Service /= 0 then
         return Service;
      end if;

      return Invalid_Handle;
   end Open_Library;

   -----------------
   -- Close_Library --
   -----------------

   procedure Close_Library (Cap : U64) is
      Result : U64;
      Idx    : constant Natural := Find_Entry (Cap);
   begin
      if Cap = Invalid_Handle then
         return;
      end if;

      --  Delete our mint BEFORE telling the manager (m75): the
      --  library server exits only when the last Send cap on its
      --  service endpoint is gone, and the manager's Expunge polls
      --  the reap before replying to our close call. Deleting
      --  after the call deadlocks all three parties.
      Result := Cap_Delete (Cap);

      if Idx /= 0 and then Open_Table (Idx).Source = From_Libman then
         Close_Via_Libman
           (Open_Table (Idx).Name (1 .. Open_Table (Idx).Name_Len));
      end if;

      Remove_Entry (Cap);
   end Close_Library;

   ----------------------
   -- Opened_Via_Libman --
   ----------------------

   function Opened_Via_Libman (Cap : U64) return Boolean is
      Idx : constant Natural := Find_Entry (Cap);
   begin
      return Idx /= 0 and then Open_Table (Idx).Source = From_Libman;
   end Opened_Via_Libman;

end Akernel_User.Libs;
