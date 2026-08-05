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
--  the session lives. The terminal (a console device, the CON:
--  analog) spawns it with:
--    handle 1 = terminal stream endpoint (Send, badge 1)
--    handle 2 = file server endpoint (Send)
--  Run standalone with handle 1 pointing at the console server and
--  the same binary is a serial shell.
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
--  pattern), spawned with this shell's own console + fs caps, and
--  awaited (reap-poll) before the next prompt. "System/Shell"
--  gives a nested shell on the same channel, Amiga-style.

procedure Shell is
   use Akernel_User.Syscalls;
   use type U64;

   Console_EP : constant U64 := 1;
   FS_EP      : constant U64 := 2;

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

   --  Run Path as a child on this shell's channel: same console
   --  (Send, badge 0) and fs caps, then reap-poll until it exits.
   procedure Exec (Path : String) is
      Mem_Cap  : U64;
      Proc_Cap : U64 := 0;
      Result   : U64;
      Reaped   : Boolean := False;
   begin
      Mem_Cap := Stage (Path);
      if Mem_Cap = 0 then
         Akernel_User.Console.Put_Line ("unknown command: " & Path);
         return;
      end if;
      Set_Grant (0, Console_EP, Right_Send, 0);
      Set_Grant (1, FS_EP, Right_Send, 0);
      if Spawn (Mem_Cap, 2, Proc_Cap) /= Spawn_Ok or else Proc_Cap = 0
      then
         Akernel_User.Console.Put_Line ("spawn failed: " & Path);
         Result := Cap_Delete (Mem_Cap);
         return;
      end if;
      Result := Cap_Delete (Mem_Cap);
      while not Reaped loop
         Reaped := Reap_Process (Proc_Cap) = 0;
         if not Reaped then
            Yield;
         end if;
      end loop;
   end Exec;

   procedure Execute (Cmd : String) is
   begin
      if Cmd = "help" then
         Akernel_User.Console.Put_Line ("akernel shell — commands:");
         Akernel_User.Console.Put_Line ("  help          this text");
         Akernel_User.Console.Put_Line ("  version       system version");
         Akernel_User.Console.Put_Line ("  exit          leave the shell");
         Akernel_User.Console.Put_Line
           ("  <path>        run a program (e.g. System/Shell)");
      elsif Cmd = "version" then
         Akernel_User.Console.Put_Line ("akernel milestone 31 (shell)");
      elsif Cmd = "exit" then
         Process_Exit;
      elsif Cmd'Length > 0 then
         Exec (Cmd);
      end if;
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
