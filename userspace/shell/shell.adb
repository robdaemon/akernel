with Interfaces;
with System;
with System.Storage_Elements;
with Ada.Streams;
with Akernel_User.Syscalls;
with Akernel_User.IPC;
with Akernel_User.Streams;
with Akernel_User.Console;
with Akernel_User.Files;

--  Shell: interactive command line (milestone 31). A plain CLI
--  program — it opens no window; its console channel decides where
--  the session lives. Spawned with the uniform namespace
--  (milestone 31b):
--    handle 1 = console stream endpoint (Send; the terminal
--               badges it 1 — point it at the console server and
--               the same binary is a serial shell)
--    handle 2 = file server endpoint (Send)
--    handle 3 = Bureau window service (Send) — a child program is
--               GUI only once it calls Surface_Create
--
--  Line discipline (echo, BS erase) lives in the console device —
--  the terminal echoes focused keys as they arrive — so the shell
--  never echoes; it only assembles lines out of Op_Read bytes.
--  Op_Read cannot block (the terminal is a single-threaded
--  receiver), so the shell polls with yields between drains.
--
--  Commands: "help", "version"; anything else is a program path
--  (unqualified names resolve against the default volume BD0:) —
--  staged through the file server into a memory object (memstage
--  pattern), spawned with this shell's own console + fs + Bureau
--  svc caps (the uniform namespace — children may open windows),
--  and awaited (reap-poll) before the next prompt. "System/Shell"
--  gives a nested shell on the same channel, Amiga-style.

procedure Shell is
   use Akernel_User.Syscalls;
   use type U64;

   Console_EP : constant U64 := 1;
   FS_EP      : constant U64 := 2;
   Win_EP     : constant U64 := 3;  --  Bureau svc (uniform ABI)

   Stage_VA : constant U64 := 16#5400_0000#;

   package RPC is new Akernel_User.IPC
     (Akernel_User.Streams.Stream_Request,
      Akernel_User.Streams.Stream_Response);

   Max_Line : constant := 120;
   Line     : String (1 .. Max_Line) := (others => ' ');
   Line_Len : Natural := 0;

   Status   : U64;
   Rlbl     : U64;
   Request  : Akernel_User.Streams.Stream_Request;
   Response : Akernel_User.Streams.Stream_Response;

   procedure Prompt is
   begin
      Akernel_User.Console.Put ("Sys:> ");
   end Prompt;

   ------------------------------------------------------------------
   --  Environment variables are FILES (milestone 33a, the Amiga
   --  ENV:/ENVARC: analog): BD0:Prefs/Env/<NAME> holds the value.
   --  Global by construction — no per-process environment block,
   --  no spawn ABI; nested shells and spawned programs all read
   --  the same files.
   ------------------------------------------------------------------

   Env_Dir : constant String := "BD0:Prefs/Env";
   Env_Buf : String (1 .. 256);  --  value staging (library-level)

   procedure Env_Ensure is
      St : U64;
   begin
      St := Akernel_User.Files.Mkdir ("BD0:Prefs");
      St := Akernel_User.Files.Mkdir (Env_Dir);
   end Env_Ensure;

   --  Read variable Name into Env_Buf; Len = value length.
   function Env_Read (Name : String; Len : out Natural) return U64 is
      Size  : U64 := 0;
      Count : U64 := 0;
      St    : U64;
   begin
      Len := 0;
      St := Akernel_User.Files.Open (Env_Dir & "/" & Name, Size);
      if St /= Akernel_User.Files.Status_Ok then
         return St;
      end if;
      Size := U64'Min (Size, U64 (Env_Buf'Length));
      St := Akernel_User.Files.Read
        (Env_Dir & "/" & Name, 0, Env_Buf'Address, Size, Count);
      if St = Akernel_User.Files.Status_Ok then
         Len := Natural (Count);
      end if;
      return St;
   end Env_Read;

   function Env_Write (Name : String; Value : String) return U64 is
      Count : U64 := 0;
      St    : U64;
   begin
      Env_Ensure;
      St := Akernel_User.Files.Truncate (Env_Dir & "/" & Name);
      for I in Value'Range loop
         Env_Buf (I - Value'First + 1) := Value (I);
      end loop;
      --  Write creates the file when missing.
      St := Akernel_User.Files.Write
        (Env_Dir & "/" & Name, 0, Env_Buf'Address,
         U64 (Value'Length), Count);
      return St;
   end Env_Write;

   --  Split a command line into its first word and the trimmed
   --  remainder: Word = Cmd (Cmd'First .. W_Last), the rest is
   --  Cmd (R_First .. Cmd'Last) (empty when R_First > Cmd'Last).
   procedure Split_Cmd
     (Cmd : String; W_Last : out Natural; R_First : out Natural)
   is
      W : Natural := Cmd'First;
   begin
      while W <= Cmd'Last and then Cmd (W) /= ' ' loop
         W := W + 1;
      end loop;
      W_Last := W - 1;
      while W <= Cmd'Last and then Cmd (W) = ' ' loop
         W := W + 1;
      end loop;
      R_First := W;
   end Split_Cmd;

   --  Stage Path through the file server into a fresh memory
   --  object; returns the spawnable object cap or 0.
   function Stage (Path : String) return U64 is
      use System.Storage_Elements;
      Size    : U64 := 0;
      Pages   : U64;
      Mem_Cap : U64;
      Off     : U64 := 0;
      Chunk   : U64;
      Count   : U64 := 0;
      St      : U64;
      Result  : U64;
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
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;
      St := Akernel_User.Files.Open (Path, Size);
      while St = Akernel_User.Files.Status_Ok and then Off < Size loop
         Chunk := U64'Min (Size - Off, 32768);
         St := Akernel_User.Files.Read
           (Path, Off,
            System'To_Address (Integer_Address (Stage_VA + Off)),
            Chunk, Count);
         exit when St /= Akernel_User.Files.Status_Ok
           or else Count /= Chunk;
         Off := Off + Chunk;
      end loop;
      if Mem_Unmap (Address_Space_Cap, Stage_VA, Pages * 4096) /= 0
        or else Off < Size
      then
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;
      return Mem_Cap;
   end Stage;

   --  Run Word as a child on this shell's channel: same console
   --  (Send, badge 0), fs and Bureau svc caps, plus — when Args
   --  is non-empty — a one-page argument string memory object at
   --  handle 4 (the Amiga command-line analog; milestone 33a).
   --  Then reap-poll until it exits.
   --  Bare names (no ':' and no '/') resolve Amiga-style against
   --  the command search path: ';'-separated directory prefixes
   --  from the Path variable (BD0:Prefs/Env/Path), defaulting to
   --  the volume root and C/ (Sys:C).
   Args_Stage_VA : constant U64 := 16#5440_0000#;

   procedure Exec (Word : String; Args : String) is
      use System.Storage_Elements;
      Mem_Cap  : U64 := 0;
      Proc_Cap : U64 := 0;
      Args_Cap : U64 := 0;
      Result   : U64;
      Reaped   : Boolean := False;
      Bare     : Boolean := True;
      Path_Len : Natural := 0;
      Grant_N  : U64 := 3;
      type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;
      Args_Page : Byte_Array (0 .. 4095)
        with Address => To_Address (Integer_Address (Args_Stage_VA));
   begin
      for C of Word loop
         if C = ':' or else C = '/' then
            Bare := False;
            exit;
         end if;
      end loop;

      if not Bare then
         Mem_Cap := Stage (Word);
      else
         --  Search path: the Path variable when set, else the
         --  built-in default (volume root, then C/).
         if Env_Read ("Path", Path_Len) = Akernel_User.Files.Status_Ok
           and then Path_Len > 0
         then
            declare
               P0 : Natural := 1;
            begin
               for I in 1 .. Path_Len + 1 loop
                  if I > Path_Len or else Env_Buf (I) = ';' then
                     if I > P0 and then Mem_Cap = 0 then
                        Mem_Cap := Stage (Env_Buf (P0 .. I - 1) & Word);
                     end if;
                     P0 := I + 1;
                  end if;
               end loop;
            end;
         else
            Mem_Cap := Stage (Word);
            if Mem_Cap = 0 then
               Mem_Cap := Stage ("C/" & Word);
            end if;
         end if;
      end if;

      if Mem_Cap = 0 then
         Akernel_User.Console.Put_Line ("unknown command: " & Word);
         return;
      end if;

      --  Argument string page at handle 4 (optional).
      if Args'Length > 0 then
         Args_Cap := Mem_Alloc (1);
         if Args_Cap = Syscall_Failed
           or else Mem_Map (Address_Space_Cap, Args_Cap,
                            Args_Stage_VA, 0, 4096, 3) /= 0
         then
            Akernel_User.Console.Put_Line ("args staging failed");
            if Args_Cap /= Syscall_Failed then
               Result := Cap_Delete (Args_Cap);
            end if;
            Result := Cap_Delete (Mem_Cap);
            return;
         end if;
         for I in 0 .. U64 (Args'Length) - 1 loop
            Args_Page (I) :=
              Interfaces.Unsigned_8
                (Character'Pos (Args (Args'First + Natural (I))));
         end loop;
         Args_Page (U64 (Args'Length)) := 0;
         Grant_N := 4;
      end if;

      Set_Grant (0, Console_EP, Right_Send, 0);
      Set_Grant (1, FS_EP, Right_Send, 0);
      Set_Grant (2, Win_EP, Right_Send, 0);
      if Grant_N = 4 then
         Set_Grant (3, Args_Cap, Right_Map + Right_Read, 0);
      end if;
      if Spawn (Mem_Cap, Grant_N, Proc_Cap) /= Spawn_Ok
        or else Proc_Cap = 0
      then
         Akernel_User.Console.Put_Line ("spawn failed: " & Word);
         Result := Cap_Delete (Mem_Cap);
         if Args_Cap /= 0 then
            Result := Mem_Unmap (Address_Space_Cap, Args_Stage_VA, 4096);
            Result := Cap_Delete (Args_Cap);
         end if;
         return;
      end if;
      Result := Cap_Delete (Mem_Cap);
      if Args_Cap /= 0 then
         Result := Mem_Unmap (Address_Space_Cap, Args_Stage_VA, 4096);
         Result := Cap_Delete (Args_Cap);
      end if;
      while not Reaped loop
         Reaped := Reap_Process (Proc_Cap) = 0;
         if not Reaped then
            Yield;
         end if;
      end loop;
   end Exec;

   procedure Execute (Cmd : String) is
      W_Last   : Natural;
      R_First  : Natural;
      V_Len    : Natural := 0;
      St       : U64;
      Name     : String (1 .. 24);
      Name_Len : Natural;
      Is_Dir   : Boolean;
      Size     : U64;
      Idx      : U64;
   begin
      if Cmd'Length = 0 then
         return;
      end if;
      Split_Cmd (Cmd, W_Last, R_First);
      declare
         Word : constant String := Cmd (Cmd'First .. W_Last);
         Rest : constant String :=
           (if R_First > Cmd'Last then "" else Cmd (R_First .. Cmd'Last));
      begin
         if Word = "help" then
            Akernel_User.Console.Put_Line ("akernel shell — commands:");
            Akernel_User.Console.Put_Line ("  help          this text");
            Akernel_User.Console.Put_Line ("  version       system version");
            Akernel_User.Console.Put_Line ("  exit          leave the shell");
            Akernel_User.Console.Put_Line
              ("  set [N=V]     set/list variables (files in Prefs/Env)");
            Akernel_User.Console.Put_Line
              ("  get N         print a variable");
            Akernel_User.Console.Put_Line
              ("  unset N       delete a variable");
            Akernel_User.Console.Put_Line
              ("  path          show the command search path");
            Akernel_User.Console.Put_Line
              ("  <cmd> [args]  run a program (Dir, Type, System/Shell)");
         elsif Word = "version" then
            Akernel_User.Console.Put_Line
              ("akernel milestone 33a (shell)");
         elsif Word = "exit" then
            Process_Exit;
         elsif Word = "set" then
            if Rest'Length = 0 then
               --  List all variables (NAME=value).
               Idx := 0;
               loop
                  St := Akernel_User.Files.Read_Dir
                    (Env_Dir, Idx, Name, Name_Len, Is_Dir, Size);
                  exit when St /= Akernel_User.Files.Status_Ok;
                  if not Is_Dir then
                     St := Env_Read (Name (1 .. Name_Len), V_Len);
                     Akernel_User.Console.Put_Line
                       (Name (1 .. Name_Len) & "="
                        & Env_Buf (1 .. V_Len));
                  end if;
                  Idx := Idx + 1;
               end loop;
            else
               --  set NAME=VALUE (or set NAME VALUE).
               declare
                  Eq : Natural := 0;
               begin
                  for I in Rest'Range loop
                     if Rest (I) = '=' then
                        Eq := I;
                        exit;
                     end if;
                  end loop;
                  if Eq > Rest'First then
                     St := Env_Write
                       (Rest (Rest'First .. Eq - 1),
                        Rest (Eq + 1 .. Rest'Last));
                  else
                     declare
                        NW : Natural;
                        NR : Natural;
                     begin
                        Split_Cmd (Rest, NW, NR);
                        if NR <= Rest'Last then
                           St := Env_Write
                             (Rest (Rest'First .. NW),
                              Rest (NR .. Rest'Last));
                        else
                           Akernel_User.Console.Put_Line
                             ("usage: set NAME=VALUE");
                           return;
                        end if;
                     end;
                  end if;
                  if St /= Akernel_User.Files.Status_Ok then
                     Akernel_User.Console.Put_Line ("set failed");
                  end if;
               end;
            end if;
         elsif Word = "get" then
            if Rest'Length = 0 then
               Akernel_User.Console.Put_Line ("usage: get NAME");
            elsif Env_Read (Rest, V_Len) =
                    Akernel_User.Files.Status_Ok
            then
               Akernel_User.Console.Put_Line (Env_Buf (1 .. V_Len));
            else
               Akernel_User.Console.Put_Line (Rest & ": not set");
            end if;
         elsif Word = "unset" then
            if Rest'Length = 0 then
               Akernel_User.Console.Put_Line ("usage: unset NAME");
            else
               St := Akernel_User.Files.Delete (Env_Dir & "/" & Rest);
            end if;
         elsif Word = "path" then
            if Env_Read ("Path", V_Len) =
                 Akernel_User.Files.Status_Ok
              and then V_Len > 0
            then
               Akernel_User.Console.Put_Line
                 ("search path: " & Env_Buf (1 .. V_Len));
            else
               Akernel_User.Console.Put_Line
                 ("search path: <root>;C/ (built-in default)");
            end if;
         else
            Exec (Word, Rest);
         end if;
      end;
   end Execute;

   --  Feed one input byte into the line buffer; execute on
   --  CR/LF. Echo is the console device's job, not ours.
   procedure Input_Byte (Ch : Character) is
      Code : constant Natural := Character'Pos (Ch);
   begin
      if Code = 10 or else Code = 13 then
         declare
            Cmd : constant String := Line (1 .. Line_Len);
         begin
            Line_Len := 0;
            Execute (Cmd);
         end;
         Prompt;
      elsif Code = 8 or else Code = 127 then
         if Line_Len > 0 then
            Line_Len := Line_Len - 1;
         end if;
      elsif Code >= 32 and then Code < 127 then
         if Line_Len < Max_Line then
            Line_Len := Line_Len + 1;
            Line (Line_Len) := Ch;
         end if;
      end if;
   end Input_Byte;

begin
   Akernel_User.Console.Set_Endpoint (Console_EP);
   Akernel_User.Files.Bind (FS_EP);
   Akernel_User.Files.Set_Default_Volume ("BD0");
   --  Allocate the files-package buffer up front: variable
   --  writes (Files.Write) need it even before any staging.
   declare
      Boot_Size : U64 := 0;
   begin
      Status := Akernel_User.Files.Open ("BD0:System/Startup",
                                         Boot_Size);
   end;
   Debug_Put_Line ("shell online");
   Akernel_User.Console.Put_Line ("akernel shell — 'help' for commands");
   Prompt;

   loop
      Request.Count := Akernel_User.Streams.Max_Chunk;
      Request.Data := (others => 0);
      Status := RPC.Call
        (Console_EP, Akernel_User.Streams.Op_Read, Request,
         RPC.No_Caps, Rlbl, Response);
      if Status /= IPC_Ok then
         --  Console channel gone: no point continuing.
         Debug_Put_Line ("shell read failed");
         Process_Exit;
      end if;
      if Response.Count = 0 then
         Yield;
      else
         for I in 1 .. Ada.Streams.Stream_Element_Offset
           (Response.Count)
         loop
            Input_Byte (Character'Val (Natural (Response.Data (I))));
         end loop;
      end if;
   end loop;
end Shell;
