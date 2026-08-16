with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Files;
with Akernel_User.Syscalls;

use System.Storage_Elements;

package body Akernel_User.Libs is

   use Syscalls;
   use type U64;

   Stage_VA : constant U64 := 16#5A00_0000#;
   Args_VA  : constant U64 := 16#5A40_0000#;

   type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;

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

   ----------------
   -- Open_Library --
   ----------------

   function Open_Library
     (Name        : String;
      Console_Cap : U64 := 1;
      FS_Cap      : U64 := 2;
      Bureau_Cap  : U64 := 3) return U64
   is
      Image      : U64;
      Rendezvous : U64;
      Args_Cap   : U64;
      Proc       : U64;
      Service    : U64;
      Status     : U64;
      Reply_H    : U64;
      Result     : U64;
      FS_EP      : constant U64 := FS_Cap;
   begin
      Files.Bind (FS_EP);

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

      --  Uniform ABI for the library server: console, fs, bureau,
      --  empty args page, and the rendezvous cap at handle 5.
      Set_Grant (0, Console_Cap, Right_Send, 0);
      Set_Grant (1, FS_Cap, Right_Send, 0);
      --  If the caller has no Bureau cap, reuse the console cap in
      --  the bureau slot so the grant list stays valid. The library
      --  reads its actual bureau handle only if it needs windows.
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
      if Service = 0 then
         Result := Cap_Delete (Args_Cap);
         Result := Cap_Delete (Image);
         Result := Cap_Delete (Rendezvous);
         Result := Cap_Delete (Proc);
         return Invalid_Handle;
      end if;

      Result := Cap_Delete (Args_Cap);
      Result := Cap_Delete (Image);
      Result := Cap_Delete (Rendezvous);
      Result := Cap_Delete (Proc);

      return Service;
   end Open_Library;

   -----------------
   -- Close_Library --
   -----------------

   procedure Close_Library (Cap : U64) is
      Result : U64;
   begin
      if Cap /= Invalid_Handle then
         Result := Cap_Delete (Cap);
      end if;
   end Close_Library;

end Akernel_User.Libs;
