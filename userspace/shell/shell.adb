with Interfaces;
with System;
with System.Storage_Elements;
with Ada.Streams;
with Akernel_User.Syscalls;
with Akernel_User.IPC;
with Akernel_User.Streams;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.CLI;

--  Shell: interactive command line (milestone 31 / 41b). A plain CLI
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
--  Builtins: "help", "exit", "execute <script>" (milestone 42:
--  the script runner — LF-separated command lines, ';' starts a
--  comment, the run stops at the first RC >= 10 Amiga-failat
--  style, nesting capped at 4). Everything else is resolved as a
--  command via the Path variable and the C: search path
--  (milestone 41b) — staged through the file server into a memory
--  object (memstage pattern), spawned with this shell's own
--  console + fs + Bureau svc caps (the uniform namespace — children
--  may open windows), and awaited (reap-poll) before the next prompt.
--  "System/Shell" gives a nested shell on the same channel,
--  Amiga-style. Spawned with args "execute <script>" the shell
--  runs the script and exits with its last RC (batch mode — the
--  fuzz end-to-end path). The prompt shows the cwd (ENV:CWD).

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
      Akernel_User.Console.Put (Akernel_User.CLI.Get_Cwd & "> ");
   end Prompt;

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

   --  Run Word as a child on this shell's channel: same console
   --  (Send, badge 0), fs and Bureau svc caps, plus — when Args
   --  is non-empty — a one-page argument string memory object at
   --  handle 4 (the Amiga command-line analog; milestone 33a).
   --  Then reap-poll until it exits and return its RC (scripts
   --  branch on it).
   Args_Stage_VA : constant U64 := 16#5440_0000#;

   function Exec (Word : String; Args : String) return U64 is
      use System.Storage_Elements;
      Mem_Cap  : U64 := 0;
      Proc_Cap : U64 := 0;
      Args_Cap : U64 := 0;
      Result   : U64;
      Code     : U64 := 0;
      Reaped   : Boolean := False;
      Grant_N  : U64 := 3;
      type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;
      Args_Page : Byte_Array (0 .. 4095)
        with Address => To_Address (Integer_Address (Args_Stage_VA));
      Resolved : constant String := Akernel_User.CLI.Resolve_Command (Word);
   begin
      if Resolved'Length = 0 then
         Akernel_User.Console.Put_Line ("unknown command: " & Word);
         return Akernel_User.CLI.RC_Error;
      end if;

      Mem_Cap := Stage (Resolved);
      if Mem_Cap = 0 then
         Akernel_User.Console.Put_Line
           ("command found but failed to stage: " & Word);
         return Akernel_User.CLI.RC_Error;
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
            return Akernel_User.CLI.RC_Error;
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
         return Akernel_User.CLI.RC_Error;
      end if;
      Result := Cap_Delete (Mem_Cap);
      if Args_Cap /= 0 then
         Result := Mem_Unmap (Address_Space_Cap, Args_Stage_VA, 4096);
         Result := Cap_Delete (Args_Cap);
      end if;
      while not Reaped loop
         if Reap_Process_Code (Proc_Cap, Code) = 0 then
            Reaped := True;
         else
            Yield;
         end if;
      end loop;
      return Code;
   end Exec;

   --  Script runner (milestone 42): LF-separated command lines,
   --  ';' starts a comment, stop at the first RC >= RC_Error
   --  (the Amiga default failat). Nesting (a script executing a
   --  script) is capped. Returns the last RC. Scripts slurp
   --  through the heap — the buffer never rides the user stack.
   Max_Script : constant := 16 * 1024;
   Max_Nest   : constant := 4;
   Nesting    : Natural := 0;

   function Execute (Cmd : String) return U64;

   function Run_Script (Path : String) return U64 is
      subtype Byte is Interfaces.Unsigned_8;
      type Byte_Array is array (U64 range <>) of Byte;
      type Buf_Access is access Byte_Array;

      Full  : constant String := Akernel_User.CLI.Resolve_Path (Path);
      Size  : U64 := 0;
      Count : U64 := 0;
      St    : U64;
      Buf   : Buf_Access;
      RC    : U64 := 0;
   begin
      if Nesting >= Max_Nest then
         Akernel_User.Console.Put_Line ("scripts nested too deep");
         return Akernel_User.CLI.RC_Error;
      end if;
      St := Akernel_User.Files.Open (Full, Size);
      if St /= Akernel_User.Files.Status_Ok then
         Akernel_User.Console.Put_Line ("can't open script " & Full);
         return Akernel_User.CLI.RC_Error;
      end if;
      if Size > Max_Script then
         Akernel_User.Console.Put_Line ("script too big " & Full);
         return Akernel_User.CLI.RC_Error;
      end if;
      Buf := new Byte_Array (0 .. (if Size = 0 then 0 else Size - 1));
      St := Akernel_User.Files.Read
        (Full, 0, Buf.all'Address, Size, Count);
      if St /= Akernel_User.Files.Status_Ok or else Count /= Size then
         Akernel_User.Console.Put_Line ("can't read script " & Full);
         return Akernel_User.CLI.RC_Error;
      end if;

      Nesting := Nesting + 1;
      declare
         Lo : U64 := 0;
         Hi : U64;
         LF : constant Byte := Byte (Character'Pos (ASCII.LF));
         CR : constant Byte := Byte (Character'Pos (ASCII.CR));
         use type Interfaces.Unsigned_8;
      begin
         while Lo < Size loop
            Hi := Lo;
            while Hi < Size and then Buf (Hi) /= LF loop
               Hi := Hi + 1;
            end loop;
            declare
               Last : U64 := Hi;
               Line : String (1 .. 256);
               Len  : Natural;
            begin
               if Last > Lo and then Buf (Last - 1) = CR then
                  Last := Last - 1;
               end if;
               Len := Natural (Last - Lo);
               if Len > 0 and then Len <= Line'Length then
                  for I in 0 .. Len - 1 loop
                     Line (I + 1) :=
                       Character'Val (Natural (Buf (Lo + U64 (I))));
                  end loop;
                  if Line (1) /= ';' then
                     RC := Execute (Line (1 .. Len));
                  end if;
               end if;
            end;
            exit when RC >= Akernel_User.CLI.RC_Error;
            Lo := Hi + 1;
         end loop;
      end;
      Nesting := Nesting - 1;
      return RC;
   end Run_Script;

   function Execute (Cmd : String) return U64 is
      W_Last   : Natural;
      R_First  : Natural;
   begin
      if Cmd'Length = 0 then
         return 0;
      end if;
      Split_Cmd (Cmd, W_Last, R_First);
      declare
         Word : constant String := Cmd (Cmd'First .. W_Last);
         Rest : constant String :=
           (if R_First > Cmd'Last then "" else Cmd (R_First .. Cmd'Last));
      begin
         if Word = "help" then
            Akernel_User.Console.Put_Line ("akernel shell — builtins:");
            Akernel_User.Console.Put_Line ("  help            this text");
            Akernel_User.Console.Put_Line ("  exit            leave the shell");
            Akernel_User.Console.Put_Line
              ("  execute <file>  run a script (';' comments, stop at RC 10)");
            Akernel_User.Console.Put_Line
              ("  <cmd> [args]    run a C: or Sys: command");
            return 0;
         elsif Word = "exit" then
            Process_Exit;
            return 0;  --  unreachable; Process_Exit does not return
         elsif Word = "execute" then
            if Rest'Length = 0 then
               Akernel_User.Console.Put_Line ("usage: execute <script>");
               return Akernel_User.CLI.RC_Error;
            end if;
            return Run_Script (Rest);
         else
            return Exec (Word, Rest);
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
            RC  : U64;
         begin
            Line_Len := 0;
            RC := Execute (Cmd);
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

   --  Batch mode (milestone 42): "Shell execute <script>" runs
   --  the script and exits with its last RC — no prompt, no
   --  console read loop. The fuzz end-to-end path for scripts.
   if Akernel_User.CLI.Arg_Count >= 1
     and then Akernel_User.CLI.Argument (1) = "execute"
   then
      if Akernel_User.CLI.Arg_Count < 2 then
         Akernel_User.CLI.Fail_With ("usage: Shell execute <script>",
                                     Akernel_User.CLI.RC_Error);
      end if;
      Akernel_User.CLI.Exit_With
        (Run_Script (Akernel_User.CLI.Argument (2)));
   end if;

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
