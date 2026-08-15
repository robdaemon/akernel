with Interfaces;
with System.Storage_Elements;
with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.IPC;
with Akernel_User.Syscalls;

--  Elevated: the elevation service (milestone 45; the design
--  locked in the NEXT.md milestone 39 entry). Holds the admin
--  bootinfo cap (Manage+Transfer) and serves the init-owned
--  Elevated endpoint. Sys:C/Elevate is a dumb client: it Calls
--  with the command line in a transferred one-page memory
--  object; Elevated resolves the command (through the CLI
--  resolver — the caller's global cwd and Path apply), stages
--  and spawns it with a MINTED admin cap (Manage only, no
--  Transfer — children cannot re-delegate), reaps it, and
--  replies with the exit code. The admin cap never lands in
--  the client's namespace; the child's spawner pid shows the
--  elevation in the Proc: tree. Policy today: allow + log.
--  Revocation = kill Elevated / stop delegating.
--
--  Elevated child ABI (grant indices are dense, and the Bureau
--  svc is not ours to give): 1 = console Send, 2 = fs Send,
--  3 = args page (filler duplicate), 4 = args page, 5 = minted
--  admin (Manage).
--
--  Requests are served one at a time (a Call blocks until its
--  child exits; concurrent Elevates queue on the endpoint).
--
--  Spawned by the device manager with: 1 = console Send
--  (badged), 2 = fs Send, 3 = Elevated EP Receive, 4 = admin
--  (Manage+Transfer).

procedure Elevated is
   use Akernel_User.Syscalls;
   use type U64;
   use type Interfaces.Unsigned_8;

   package Proto is new Akernel_User.IPC (U64, U64);

   Console_EP : constant U64 := 1;
   FS_EP      : constant U64 := 2;
   Svc_EP     : constant U64 := 3;
   Admin_Cap  : constant U64 := 4;

   Op_Elevate : constant U64 := 1;

   --  Staging VAs (own address space; the devmgr-proven
   --  region — an unproven VA can land inside the RTS heap).
   Stage_VA    : constant U64 := 16#5C00_0000#;
   Args_In_VA  : constant U64 := 16#5C40_0000#;
   Args_Out_VA : constant U64 := 16#5C80_0000#;

   type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;

   Next_Badge : U64 := 100;

   --  Stage a file from the fs into a fresh memory object
   --  (the devmgr Stage_From_FS idiom). Returns the cap or 0.
   function Stage (Path : String) return U64 is
      use System.Storage_Elements;
      --  Same resolution contract as the shell's Stage
      --  (milestone 57 burn): the bare Files default volume is
      --  RD0 (initrd), so a relative "c/shutdown" qualified to
      --  RD0: and missed — try the cwd-resolved name first,
      --  fall back to the raw RD0-default name.
      Full    : constant String :=
        Akernel_User.CLI.Resolve_Path (Path);
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
      St := Akernel_User.Files.Stat (Full, Size);
      if St /= Akernel_User.Files.Status_Ok then
         St := Akernel_User.Files.Stat (Path, Size);
         if St = Akernel_User.Files.Status_Ok then
            NLen := Natural'Min (Path'Length, Name'Length);
            Name (1 .. NLen) := Path (Path'First .. Path'First + NLen - 1);
         end if;
      else
         NLen := Natural'Min (Full'Length, Name'Length);
         Name (1 .. NLen) := Full (Full'First .. Full'First + NLen - 1);
      end if;
      if St /= Akernel_User.Files.Status_Ok or else Size = 0 then
         Akernel_User.Console.Put_Line
           ("elevated: cannot find executable: " & Path);
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
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;
      St := Akernel_User.Files.Open (Name (1 .. NLen), Size);
      while St = Akernel_User.Files.Status_Ok and then Off < Size loop
         Chunk := U64'Min (Size - Off, 32768);
         St := Akernel_User.Files.Read
           (Name (1 .. NLen), Off,
            To_Address (Integer_Address (Stage_VA + Off)),
            Chunk, Count);
         if St /= Akernel_User.Files.Status_Ok
           or else Count /= Chunk
         then
            exit;
         end if;
         Off := Off + Chunk;
      end loop;
      Result := Mem_Unmap (Address_Space_Cap, Stage_VA, Pages * 4096);
      if Off < Size then
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;
      return Mem_Cap;
   end Stage;

   Label    : U64;
   Req      : U64;
   Badge    : U64;
   Caps     : Proto.Cap_Array;
   Reply_H  : U64;
   St       : U64;
   Result   : U64;
begin
   Akernel_User.Console.Set_Endpoint (Console_EP);
   Akernel_User.Files.Bind (FS_EP);
   Akernel_User.Console.Put_Line ("elevated: serving");

   loop
      St := Proto.Receive (Svc_EP, Label, Req, Badge, Caps, Reply_H);
      if St /= 0 then
         exit;  --  endpoint gone (teardown) — exit quietly
      end if;

      declare
         Reply_Code : U64 := Akernel_User.CLI.RC_Fail;
      begin
         if Label = Op_Elevate and then Caps (0) /= 0
           and then Mem_Map (Address_Space_Cap, Caps (0),
                             Args_In_VA, 0, 4096, 1) = 0
         then
            declare
               use System.Storage_Elements;
               Line : Byte_Array (0 .. 4095)
                 with Address => To_Address
                   (Integer_Address (Args_In_VA));

               --  Line length up to the NUL.
               Len : Natural := 0;
            begin
               while Len < 4096 and then Line (U64 (Len)) /= 0 loop
                  Len := Len + 1;
               end loop;

               --  Split the first word (the command) from the
               --  rest (its argument string).
               declare
                  W_End : Natural := 0;  --  one past the word
                  R0    : Natural := 0;  --  start of the rest
                  Word  : String (1 .. 64);
                  W_Len : Natural := 0;
               begin
                  while W_End < Len
                    and then Line (U64 (W_End)) /=
                      Interfaces.Unsigned_8 (Character'Pos (' '))
                  loop
                     W_End := W_End + 1;
                  end loop;
                  R0 := W_End;
                  while R0 < Len
                    and then Line (U64 (R0)) =
                      Interfaces.Unsigned_8 (Character'Pos (' '))
                  loop
                     R0 := R0 + 1;
                  end loop;
                  if W_End <= Word'Length then
                     W_Len := W_End;
                     for I in 0 .. W_End - 1 loop
                        Word (I + 1) := Character'Val
                          (Integer (Line (U64 (I))));
                     end loop;
                  end if;

                  if W_Len = 0 then
                     Reply_Code := Akernel_User.CLI.RC_Error;
                  else
                     declare
                        Resolved : constant String :=
                          Akernel_User.CLI.Resolve_Command
                            (Word (1 .. W_Len));
                        Img      : U64 := 0;
                        Args_Cap : U64 := 0;
                        Mint     : U64 := 0;
                        Proc     : U64 := 0;
                        Code     : U64 := 0;
                     begin
                        if Resolved'Length > 0 then
                           Img := Stage (Resolved);
                        end if;
                        if Img /= 0 then
                           Args_Cap := Mem_Alloc (1);
                        end if;
                        if Args_Cap /= 0
                          and then Args_Cap /= Syscall_Failed
                          and then Mem_Map
                            (Address_Space_Cap, Args_Cap,
                             Args_Out_VA, 0, 4096, 3) = 0
                        then
                           declare
                              Out_Page : Byte_Array (0 .. 4095)
                                with Address => To_Address
                                  (Integer_Address (Args_Out_VA));
                           begin
                              if Len > R0 then
                                 for I in 0 .. U64 (Len - R0) - 1
                                 loop
                                    Out_Page (I) :=
                                      Line (U64 (R0) + I);
                                 end loop;
                              end if;
                              Out_Page (U64 (Len - R0)) := 0;
                           end;
                           Result := Mem_Unmap
                             (Address_Space_Cap, Args_Out_VA, 4096);

                           --  Manage-only mint: children cannot
                           --  re-delegate (Transfer stays here).
                           Mint := Cap_Mint
                             (Admin_Cap, Right_Manage, 0);
                           if Mint = Syscall_Failed then
                              Mint := 0;
                           end if;
                           Set_Grant (0, Console_EP, Right_Send,
                                      Next_Badge);
                           Set_Grant (1, FS_EP, Right_Send, 0);
                           Set_Grant (2, Args_Cap,
                                      Right_Map + Right_Read, 0);
                           Set_Grant (3, Args_Cap,
                                      Right_Map + Right_Read, 0);
                           Set_Grant (4, Mint, Right_Manage, 0);
                           if Mint /= 0
                             and then Spawn (Img, 5, Proc) = Spawn_Ok
                             and then Proc /= 0
                           then
                              Next_Badge := Next_Badge + 1;
                              Akernel_User.Console.Put_Line
                                ("elevated: running "
                                 & Word (1 .. W_Len));
                              loop
                                 exit when Reap_Process_Code
                                   (Proc, Code) = 0;
                                 for I in 1 .. 32 loop
                                    Yield;
                                 end loop;
                              end loop;
                              Reply_Code := Code;
                           else
                              Reply_Code := Akernel_User.CLI.RC_Error;
                           end if;
                        else
                           Reply_Code := Akernel_User.CLI.RC_Error;
                        end if;

                        if Mint /= 0 then
                           Result := Cap_Delete (Mint);
                        end if;
                        if Args_Cap /= 0
                          and then Args_Cap /= Syscall_Failed
                        then
                           Result := Cap_Delete (Args_Cap);
                        end if;
                        if Img /= 0 then
                           Result := Cap_Delete (Img);
                        end if;
                     end;
                  end if;
               end;
            end;
            Result := Mem_Unmap (Address_Space_Cap, Args_In_VA, 4096);
         end if;

         --  The transferred client page: servers must delete
         --  per-request caps or leak a table slot per call.
         if Caps (0) /= 0 then
            Result := Cap_Delete (Caps (0));
         end if;
         Result := Proto.Reply (Reply_H, Label, Reply_Code);
      end;
   end loop;

   Process_Exit (0);
end Elevated;
