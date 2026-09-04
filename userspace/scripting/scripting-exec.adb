with Interfaces;
with System;
with System.Storage_Elements;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.CLI;

--  Extracted unchanged from userspace/shell/shell.adb in
--  milestone 70 chunk 1 — see Scripting.Exec's spec for the
--  pipeline/redirection design notes.
package body Scripting.Exec is
   use Akernel_User.Syscalls;
   use type U64;

   Stage_VA      : constant U64 := 16#5400_0000#;
   Args_Stage_VA : constant U64 := 16#5440_0000#;

   --  Foreground pipe pool rotation (Bg pipelines name their
   --  pipes from the job slot instead — see Spawn_Pipeline).
   Pipe_Seq : Natural := 0;

   --  Stage Path through the file server into a fresh memory
   --  object; returns the spawnable object cap or 0.
   function Stage (Path : String) return U64 is
      use System.Storage_Elements;
      --  Cwd-aware resolution (ENV:CWD): the bare Files default
      --  volume is RD0 (the initrd), so an interactive
      --  "System/Edit" qualified to RD0: and never staged.
      --  But fuzz scripts say "run Tests/Teardown" relative
      --  with a BD0: cwd and Tests/ is RD0:-only. Try the
      --  cwd-resolved name first, fall back to the raw name
      --  (RD0 default) — both worlds stage.
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
         --  Fallback: bare Files qualification (RD0: initrd),
         --  the historical behaviour the suite's Tests/ paths
         --  rely on.
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
         Debug_Put_Line ("stage: stat failed path=<" & Path & ">");
         Debug_Put_Line ("st=" & U64'Image (St) & " size=" &
           U64'Image (Size));
         return 0;
      end if;
      Pages := (Size + 4095) / 4096;
      Mem_Cap := Mem_Alloc (Pages);
      if Mem_Cap = Syscall_Failed then
         Debug_Put_Line ("stage: alloc failed");
         return 0;
      end if;
      if Mem_Map (Address_Space_Cap, Mem_Cap, Stage_VA, 0,
                  Pages * 4096, 3) /= 0
      then
         Debug_Put_Line ("stage: map failed");
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;
      St := Akernel_User.Files.Open (Name (1 .. NLen), Size);
      while St = Akernel_User.Files.Status_Ok and then Off < Size loop
         Chunk := U64'Min (Size - Off, 32768);
         St := Akernel_User.Files.Read
           (Name (1 .. NLen), Off,
            System'To_Address (Integer_Address (Stage_VA + Off)),
            Chunk, Count);
         exit when St /= Akernel_User.Files.Status_Ok
           or else Count /= Chunk;
         Off := Off + Count;
      end loop;
      if Mem_Unmap (Address_Space_Cap, Stage_VA, Pages * 4096) /= 0
        or else Off < Size
      then
         Debug_Put_Line ("stage: read/unmap failed");
         Result := Cap_Delete (Mem_Cap);
         return 0;
      end if;
      return Mem_Cap;
   end Stage;

   function Spawn_Cmd
     (Word     : String;
      Args     : String;
      Out_Path : String;
      In_Path  : String) return U64
   is
      use System.Storage_Elements;
      Mem_Cap  : U64 := 0;
      Proc_Cap : U64 := 0;
      Args_Cap : U64 := 0;
      Result   : U64;
      type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;
      Args_Page : Byte_Array (0 .. 4095)
        with Address => To_Address (Integer_Address (Args_Stage_VA));
      type Word_Array is array (0 .. 7) of U64;
      Trailer : Word_Array
        with Address => To_Address
          (Integer_Address
             (Args_Stage_VA
              + Akernel_User.Syscalls.Args_Trailer_Offset));
      Resolved : constant String := Akernel_User.CLI.Resolve_Command (Word);

      procedure Put_Path (Offset : U64; Path : String) is
      begin
         for I in 0 .. U64 (Path'Length) - 1 loop
            Args_Page (Offset + I) :=
              Interfaces.Unsigned_8
                (Character'Pos (Path (Path'First + Natural (I))));
         end loop;
         Args_Page (Offset + U64 (Path'Length)) := 0;
      end Put_Path;
   begin
      if Resolved'Length = 0 then
         Akernel_User.Console.Put_Line ("unknown command: " & Word);
         return 0;
      end if;

      Mem_Cap := Stage (Resolved);
      if Mem_Cap = 0 then
         Akernel_User.Console.Put_Line
           ("cannot find executable: " & Word);
         return 0;
      end if;

      --  Argument string page at handle 4 (always, possibly
      --  empty — the handle layout is uniform).
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
         return 0;
      end if;
      if Args'Length > 0 then
         --  Guard: a bare command ("Sort" as a pipeline stage)
         --  passes an EMPTY arg string — indexing a null
         --  String raises Constraint_Error (m46b burn).
         for I in 0 .. U64 (Args'Length) - 1 loop
            Args_Page (I) :=
              Interfaces.Unsigned_8
                (Character'Pos (Args (Args'First + Natural (I))));
         end loop;
      end if;
      Args_Page (U64 (Args'Length)) := 0;

      --  Redirection trailer (page contents are NOT guaranteed
      --  zeroed by Mem_Alloc — clear the trailer first).
      Trailer := (others => 0);
      if Out_Path'Length > 0 or else In_Path'Length > 0 then
         Trailer (0) := Akernel_User.Syscalls.Args_Trailer_Magic;
         if Out_Path'Length > 0 then
            Put_Path (3800, Out_Path);
            Trailer (1) := 3800;
         end if;
         if In_Path'Length > 0 then
            Put_Path (3900, In_Path);
            Trailer (2) := 3900;
         end if;
      end if;

      Set_Grant (0, Console_EP, Right_Send, 0);
      Set_Grant (1, FS_EP, Right_Send, 0);
      Set_Grant (2, Win_EP, Right_Send, 0);
      Set_Grant (3, Args_Cap, Right_Map + Right_Read, 0);
      Set_Grant (4, Svc_EP, Right_Send, 0);
      --  Handle 6 = the netserv client endpoint (m71c).
      Set_Grant (5, Net_EP, Right_Send, 0);
      if Spawn (Mem_Cap, 6, Proc_Cap) /= Spawn_Ok
        or else Proc_Cap = 0
      then
         Akernel_User.Console.Put_Line ("spawn failed: " & Word);
         Result := Cap_Delete (Mem_Cap);
         Result := Mem_Unmap (Address_Space_Cap, Args_Stage_VA, 4096);
         Result := Cap_Delete (Args_Cap);
         return 0;
      end if;
      Result := Cap_Delete (Mem_Cap);
      Result := Mem_Unmap (Address_Space_Cap, Args_Stage_VA, 4096);
      Result := Cap_Delete (Args_Cap);
      return Proc_Cap;
   end Spawn_Cmd;

   function Reap (Proc_Cap : U64) return U64 is
      Result : U64;
      Code   : U64 := 0;
      Reaped : Boolean := False;
   begin
      while not Reaped loop
         if Reap_Process_Code (Proc_Cap, Code) = 0 then
            Reaped := True;
         else
            Yield;
         end if;
      end loop;
      return Code;
   end Reap;

   function Exec (Word : String; Args : String) return U64 is
      Proc_Cap : constant U64 := Spawn_Cmd (Word, Args, "", "");
   begin
      if Proc_Cap = 0 then
         return Akernel_User.CLI.RC_Error;
      end if;
      return Reap (Proc_Cap);
   end Exec;

   function Has_Metachar (Cmd : String) return Boolean is
      Depth : Natural := 0;
   begin
      --  M85c: glob alternation (a|b) also uses '|' (and patterns
      --  may contain '>' or '<' literally), so operators inside
      --  parentheses are not shell metacharacters.
      for C of Cmd loop
         if C = '(' then
            Depth := Depth + 1;
         elsif C = ')' and then Depth > 0 then
            Depth := Depth - 1;
         elsif Depth = 0
           and then (C = '|' or else C = '>' or else C = '<')
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Metachar;

   procedure Spawn_Pipeline
     (Cmd     : String;
      Bg_Slot : Natural;
      Procs   : out Proc_Set;
      Pipes   : out Pipe_Set;
      PLens   : out Pipe_Len_Set;
      NStage  : out Natural;
      Ok      : out Boolean)
   is
      package Files renames Akernel_User.Files;
      Max_Tok : constant := 32;
      type Tok is record
         F : Natural := 0;
         L : Natural := 0;
      end record;
      Toks : array (1 .. Max_Tok) of Tok;
      NTok : Natural := 0;

      Stage_Cmd : array (1 .. Max_Stages) of String (1 .. 256) :=
        (others => (others => ' '));
      Stage_Len : array (1 .. Max_Stages) of Natural :=
        (others => 0);
      Stage_In  : array (1 .. Max_Stages) of String (1 .. 48) :=
        (others => (others => Character'Val (0)));
      Stage_Il  : array (1 .. Max_Stages) of Natural :=
        (others => 0);
      Stage_Out : array (1 .. Max_Stages) of String (1 .. 48) :=
        (others => (others => Character'Val (0)));
      Stage_Ol  : array (1 .. Max_Stages) of Natural :=
        (others => 0);
       I    : Natural;
       T    : Natural;
       Depth : Natural := 0;
       St   : U64;
       Size : U64;
       Bad  : Boolean := False;

      procedure Set_Path
        (Buf : out String; Len : in out Natural; Value : String)
      is
      begin
         if Value'Length = 0 or else Value'Length > Buf'Length then
            Bad := True;
            return;
         end if;
         Buf := (others => Character'Val (0));
         Buf (Buf'First .. Buf'First + Value'Length - 1) := Value;
         Len := Value'Length;
      end Set_Path;

      procedure Append_Word (Text : String) is
         S : Natural renames Stage_Len (NStage);
      begin
         if S + Text'Length + 1 > 256 then
            Bad := True;
            return;
         end if;
         if S > 0 then
            S := S + 1;
            Stage_Cmd (NStage)(S) := ' ';
         end if;
         Stage_Cmd (NStage)(S + 1 .. S + Text'Length) := Text;
         S := S + Text'Length;
      end Append_Word;
   begin
      Procs  := (others => 0);
      Pipes  := (others => (others => Character'Val (0)));
      PLens  := (others => 0);
      NStage := 1;
      Ok     := False;
      --  Tokenize.
      I := Cmd'First;
      while I <= Cmd'Last loop
         while I <= Cmd'Last and then Cmd (I) = ' ' loop
            I := I + 1;
         end loop;
         exit when I > Cmd'Last;
         if NTok = Max_Tok then
            Bad := True;
            exit;
         end if;
         NTok := NTok + 1;
         Toks (NTok).F := I;
         while I <= Cmd'Last and then Cmd (I) /= ' ' loop
            I := I + 1;
         end loop;
         Toks (NTok).L := I - 1;
      end loop;

      --  Split into stages; lift redirection operators out.
      T := 1;
      while T <= NTok and then not Bad loop
         declare
            Text : constant String :=
              Cmd (Toks (T).F .. Toks (T).L);
         begin
             if Depth = 0 and then Text = "|" then
                if NStage = Max_Stages
                  or else Stage_Len (NStage) = 0
                then
                   Bad := True;
                else
                   NStage := NStage + 1;
                end if;
             elsif Depth = 0
               and then (Text = ">" or else Text = "<")
             then
               if T = NTok then
                  Bad := True;
               else
                  T := T + 1;
                  declare
                     Target : constant String :=
                       Akernel_User.CLI.Resolve_Path
                         (Cmd (Toks (T).F .. Toks (T).L));
                  begin
                     if Text = ">" then
                        Set_Path (Stage_Out (NStage),
                                  Stage_Ol (NStage), Target);
                     else
                        Set_Path (Stage_In (NStage),
                                  Stage_Il (NStage), Target);
                     end if;
                  end;
               end if;
             else
                Append_Word (Text);
                --  M85c: track glob-alternation paren depth so a
                --  spaced (foo | bar) pattern does not split the
                --  pipeline; Has_Metachar applies the same rule.
                for C of Text loop
                   if C = '(' then
                      Depth := Depth + 1;
                   elsif C = ')' and then Depth > 0 then
                      Depth := Depth - 1;
                   end if;
                end loop;
             end if;
         end;
         T := T + 1;
      end loop;

      --  Validate: every stage has a command; `>` is final-
      --  stage-only and `<` first-stage-only (pipes fill the
      --  rest).
      if not Bad then
         for S in 1 .. NStage loop
            if Stage_Len (S) = 0 then
               Bad := True;
            end if;
            if (S < NStage and then Stage_Ol (S) > 0)
              or else (S > 1 and then Stage_Il (S) > 0)
            then
               Bad := True;
            end if;
         end loop;
      end if;

      if Bad then
         Akernel_User.Console.Put_Line
           ("bad pipeline (usage: A | B, > file, < file)");
         return;
      end if;

      --  Wire the pipes between stages.
      for S in 1 .. NStage - 1 loop
         declare
            Img  : constant String := Natural'Image (Pipe_Seq);
            JIm  : constant String := Natural'Image (Bg_Slot);
            SIm  : constant String := Natural'Image (S);
            Name : constant String :=
              (if Bg_Slot = 0
               then "PIPE:SH" & Img (Img'First + 1 .. Img'Last)
               else "PIPE:BG" & JIm (JIm'First + 1 .. JIm'Last)
                    & SIm (SIm'First + 1 .. SIm'Last));
         begin
            if Bg_Slot = 0 then
               Pipe_Seq := (Pipe_Seq + 1) mod 100;
            end if;
            Set_Path (Pipes (S), PLens (S), Name);
            Set_Path (Stage_Out (S), Stage_Ol (S), Name);
            Set_Path (Stage_In (S + 1), Stage_Il (S + 1), Name);
            --  Create-or-reset: a recycled name can hold stale
            --  data and a stale EOF flag.
            St := Files.Open (Name, Size);
            if St = Files.Status_Ok then
               St := Files.Truncate (Name);
            end if;
            if St /= Files.Status_Ok then
               Akernel_User.Console.Put_Line
                 ("cannot create " & Name);
               return;
            end if;
         end;
      end loop;

      --  A `>` target that exists gets truncated (Amiga `>`
      --  semantics); a missing one is created by the first
      --  Write.
      if Stage_Ol (NStage) > 0 then
         St := Files.Stat (Stage_Out (NStage)(1 .. Stage_Ol (NStage)),
                     Size);
         if St = Files.Status_Ok then
            St := Files.Truncate (Stage_Out (NStage)
                            (1 .. Stage_Ol (NStage)));
            if St /= Files.Status_Ok then
               Akernel_User.Console.Put_Line
                 ("cannot truncate redirect target");
               return;
            end if;
         end if;
      end if;

      --  Spawn every stage concurrently.
      for S in 1 .. NStage loop
         declare
            W_Last  : Natural;
            R_First : Natural;
         begin
            Split_Cmd (Stage_Cmd (S)(1 .. Stage_Len (S)),
                       W_Last, R_First);
            Procs (S) := Spawn_Cmd
              (Stage_Cmd (S)(1 .. W_Last),
               (if R_First > Stage_Len (S) then ""
                else Stage_Cmd (S)(R_First .. Stage_Len (S))),
               (if Stage_Ol (S) > 0
                then Stage_Out (S)(1 .. Stage_Ol (S)) else ""),
               (if Stage_Il (S) > 0
                then Stage_In (S)(1 .. Stage_Il (S)) else ""));
         end;
         if Procs (S) = 0 then
            --  Unblock any stage already waiting on a pipe,
            --  then reap what got spawned.
            for P in 1 .. NStage - 1 loop
               if PLens (P) > 0 then
                  St := Files.Close (Pipes (P)(1 .. PLens (P)));
               end if;
            end loop;
            for Q in 1 .. S - 1 loop
               if Procs (Q) /= 0 then
                  St := Reap (Procs (Q));
                  St := Cap_Delete (Procs (Q));
                  Procs (Q) := 0;
               end if;
            end loop;
            for P in 1 .. NStage - 1 loop
               if PLens (P) > 0 then
                  St := Files.Delete (Pipes (P)(1 .. PLens (P)));
               end if;
            end loop;
            return;
         end if;
      end loop;

      Ok := True;
   end Spawn_Pipeline;

   procedure Delete_Pipes (Pipes : Pipe_Set; PLens : Pipe_Len_Set) is
      St : U64;
   begin
      for P in Pipes'Range loop
         if PLens (P) > 0 then
            St := Akernel_User.Files.Delete
              (Pipes (P)(1 .. PLens (P)));
         end if;
      end loop;
   end Delete_Pipes;

   procedure Reap_Pipeline
     (Procs  : in out Proc_Set;
      Pipes  : Pipe_Set;
      PLens  : Pipe_Len_Set;
      NStage : Natural;
      RC     : out U64)
   is
      Dead : U64;
   begin
      RC := 0;
      for S in 1 .. NStage loop
         if Procs (S) /= 0 then
            declare
               Code : constant U64 := Reap (Procs (S));
            begin
               if S = NStage then
                  RC := Code;
               end if;
            end;
            Dead := Cap_Delete (Procs (S));
            Procs (S) := 0;
         end if;
      end loop;
      Delete_Pipes (Pipes, PLens);
   end Reap_Pipeline;

   function Run_Pipeline (Cmd : String) return U64 is
      Procs  : Proc_Set := (others => 0);
      Pipes  : Pipe_Set := (others => (others => Character'Val (0)));
      PLens  : Pipe_Len_Set := (others => 0);
      NStage : Natural := 0;
      Ok     : Boolean;
      RC     : U64;
   begin
      Spawn_Pipeline (Cmd, 0, Procs, Pipes, PLens, NStage, Ok);
      if not Ok then
         return Akernel_User.CLI.RC_Error;
      end if;
      Reap_Pipeline (Procs, Pipes, PLens, NStage, RC);
      return RC;
   end Run_Pipeline;

end Scripting.Exec;
