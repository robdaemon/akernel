with Interfaces;
with Ada.Streams;
with Akernel_User.Syscalls;
with Akernel_User.IPC;
with Akernel_User.Streams;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.CLI;
with Akernel_User.Tables;
with Scripting;
with Scripting.Exec;
with Scripting.Interp;
with Scripting.Console_IO;

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
--  Builtins: "help", "endcli", "execute <script> [args]"
--  (milestones 42 + 70: the script runner — LF-separated command
--  lines, ';' starts a comment, Amiga-failat stop, nesting capped
--  at 4; Scripting.Interp is the AmigaDOS subset: .key args, .def
--  defaults, .set locals, <name>/<$name> substitution, if/else/
--  endif, lab/skip, quit, failat, echo, ask). Everything else is
--  resolved as a
--  command via the Path variable and the C: search path
--  (milestone 41b) — staged through the file server into a memory
--  object (memstage pattern), spawned with this shell's own
--  console + fs + Bureau svc caps (the uniform namespace — children
--  may open windows), and awaited (reap-poll) before the next prompt.
--  The stage/spawn/reap and pipeline machinery lives in
--  Scripting.Exec (milestone 70) — shared with Sys:C/Execute.
--  "System/Shell" gives a nested shell on the same channel,
--  Amiga-style. Spawned with args "execute <script>" the shell
--  runs the script and exits with its last RC (batch mode — the
--  fuzz end-to-end path). The prompt shows the cwd (ENV:CWD).

procedure Shell is
   use Akernel_User.Syscalls;
   use Scripting;  --  uniform-ABI handle constants, Split_Cmd
   use type U64;

   --  The execution engine (stage/spawn/reap/pipelines) —
   --  milestone 70 extraction; Scripting declares no U64 of its
   --  own, but Scripting.Exec does, so it comes in via renames
   --  instead of a use clause (the tdemo/Trinket precedent).
   package SE renames Scripting.Exec;

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

   --  Script runner: the milestone-42 linear semantics plus the
   --  milestone-70 interpreter core (Scripting.Interp — `.key`
   --  args, `.def` defaults, `.set` locals, `<name>`/`<$name>`
   --  substitution; if/else/endif, lab/skip, quit, failat and
   --  echo land in chunk 3). Nesting (a script executing a
   --  script) is capped; this shell's count feeds Interp's
   --  Depth. Returns the last RC.
   Nesting : Natural := 0;

   function Execute (Cmd : String) return U64;

   --  ask (milestone 70 chunk 4): the shell owns the raw
   --  console stream, so the reply is a blocking Op_Read line
   --  read — the prompt loop's discipline.
   procedure Ask_Line
     (Prompt : String; Reply : out String; Reply_Len : out Natural)
   is
   begin
      Akernel_User.Console.Put (Prompt);
      Scripting.Console_IO.Read_Line (Reply, Reply_Len);
   end Ask_Line;

   --  The dispatcher a script line runs through IS this shell's
   --  Execute — builtins (run/jobs/wait/execute itself) work in
   --  scripts, and `execute` re-enters Interp with Depth + 1.
   package SI is new Scripting.Interp
     (Run_Line => Execute, Ask_Line => Ask_Line);

   --  Rest is "<script> [args...]" — the args bind through the
   --  script's .key template. Owns the nesting counter: Depth
   --  handed to Interp is the level AFTER incrementing, so the
   --  top-level script (prompt or batch) runs at Depth 1.
   function Run_Script (Rest : String) return U64 is
      W_Last  : Natural;
      R_First : Natural;
      RC      : U64;
   begin
      Split_Cmd (Rest, W_Last, R_First);
      Nesting := Nesting + 1;
      RC := SI.Run
        (Rest (Rest'First .. W_Last),
         (if R_First > Rest'Last then ""
          else Rest (R_First .. Rest'Last)),
         Nesting);
      Nesting := Nesting - 1;
      return RC;
   end Run_Script;

   --  Job control (milestones 52 + 69), Amiga RUN lineage: `run`
   --  backgrounds a single command OR a whole pipeline; the shell
   --  owns the stage process caps, so only the shell can reap
   --  them. A job's RC is its LAST stage's exit code; a pipeline
   --  job's slot-scoped PIPE:BG<j><s> pipes are deleted when the
   --  job is reaped (harvest or wait), so the foreground
   --  PIPE:SH<n> pool can never recycle a live job's pipe.
   --  Job numbers are shell-local slot indices (the pid is not
   --  readable from a proc cap without admin introspection —
   --  Proc:self would fix display). A COMPLETED job keeps its
   --  exit code in the Done state until `wait` claims it —
   --  `jobs` reporting done must not destroy a code a later
   --  wait wants (the Script4 burn). `run` allocates a Free
   --  slot, then steals the oldest Done slot, then fails
   --  (m80f: grows instead — see the table below).
   --  `wait [n]` blocks on one (or all) and yields the exit
   --  code as the command RC so scripts compose with failat.
   --  Exiting the shell with live jobs warns once; the second
   --  exit abandons them (children are independent processes —
   --  Amiga RUN'd tasks survive the shell).
   --  m80f: chunk-appended (Akernel_User.Tables); job numbers are
   --  user-visible (jobs/wait/kill), chunk-append keeps them
   --  stable. Job_Free slots are all-zero (fresh chunks read as
   --  free). Allocation: free slot, then steal the oldest Done
   --  slot, then grow.
   type Job_State is (Job_Free, Job_Active, Job_Done);
   type Job_Rec is record
      State  : Job_State := Job_Free;
      Procs  : SE.Proc_Set := (others => 0);
      NStage : Natural := 0;
      Pipes  : SE.Pipe_Set := (others => (others => Character'Val (0)));
      PLens  : SE.Pipe_Len_Set := (others => 0);
      Code   : U64 := 0;
      Cmd    : String (1 .. 64) := (others => ' ');
      Len    : Natural := 0;
   end record;
   package Job_Tab is new Akernel_User.Tables (Job_Rec);
   function Jobs (J : Natural) return Job_Tab.Element_Access
     renames Job_Tab.Ref;
   Endcli_Warned : Boolean := False;

   procedure Harvest (Loud : Boolean) is
      Code : U64 := 0;
      Dead : U64;
      Done : Boolean;
   begin
      for J in 1 .. Job_Tab.Last loop
         if Jobs (J).State = Job_Active then
            --  Poll every stage; stages exit in any order. The
            --  job's RC is the LAST stage's code, captured
            --  whenever that stage happens to be reaped.
            Done := True;
            for S in 1 .. Jobs (J).NStage loop
               if Jobs (J).Procs (S) /= 0 then
                  if Reap_Process_Code (Jobs (J).Procs (S), Code) = 0
                  then
                     if S = Jobs (J).NStage then
                        Jobs (J).Code := Code;
                     end if;
                     Dead := Cap_Delete (Jobs (J).Procs (S));
                     Jobs (J).Procs (S) := 0;
                  else
                     Done := False;
                  end if;
               end if;
            end loop;
            if Done then
               SE.Delete_Pipes (Jobs (J).Pipes, Jobs (J).PLens);
               Jobs (J).State := Job_Done;
            end if;
         end if;
         if Loud then
            if Jobs (J).State = Job_Active then
               Akernel_User.Console.Put_Line
                 ("  job" & Natural'Image (J) & " running     " &
                  Jobs (J).Cmd (1 .. Jobs (J).Len));
            elsif Jobs (J).State = Job_Done then
               Akernel_User.Console.Put_Line
                 ("  job" & Natural'Image (J) & " done (rc" &
                  U64'Image (Jobs (J).Code) & " )  " &
                  Jobs (J).Cmd (1 .. Jobs (J).Len));
            end if;
         end if;
      end loop;
   end Harvest;

   function Jobs_Active return Natural is
      N : Natural := 0;
   begin
      for J in 1 .. Job_Tab.Last loop
         if Jobs (J).State = Job_Active then
            N := N + 1;
         end if;
      end loop;
      return N;
   end Jobs_Active;

   function Parse_Nat (S : String) return Natural is
      N : Natural := 0;
   begin
      for C of S loop
         if C not in '0' .. '9' or else N > 1000 then
            return 0;
         end if;
         N := N * 10 + (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      return N;
   end Parse_Nat;

   --  Signed parse for `pri` (Amiga ChangeTaskPri lineage);
   --  Ok is False on anything but [-]digits.
   function Parse_Int (S : String; Ok : out Boolean) return Integer is
      N    : Integer := 0;
      Neg  : Boolean := False;
      From : Positive := S'First;
   begin
      Ok := False;
      if S'Length = 0 then
         return 0;
      end if;
      if S (S'First) = '-' then
         Neg := True;
         From := S'First + 1;
         if From > S'Last then
            return 0;
         end if;
      end if;
      for I in From .. S'Last loop
         if S (I) not in '0' .. '9' or else N > 1000 then
            return 0;
         end if;
         N := N * 10 + (Character'Pos (S (I)) - Character'Pos ('0'));
      end loop;
      Ok := True;
      return (if Neg then -N else N);
   end Parse_Int;

   function Run_Background (Rest : String) return U64 is
   begin
      if Rest'Length = 0 then
         Akernel_User.Console.Put_Line
           ("usage: run <cmd> [args] [| <cmd> ...]");
         return Akernel_User.CLI.RC_Error;
      end if;
      Harvest (Loud => False);
      declare
         Slot : Natural := 0;
      begin
         for J in 1 .. Job_Tab.Last loop
            if Jobs (J).State = Job_Free then
               Slot := J;
               exit;
            end if;
         end loop;
         if Slot = 0 then
            --  No Free slot: steal the oldest Done one (its
            --  unclaimed exit code is discarded — documented).
            for J in 1 .. Job_Tab.Last loop
               if Jobs (J).State = Job_Done then
                  Slot := J;
                  exit;
               end if;
            end loop;
         end if;
         if Slot = 0 then
            Slot := Job_Tab.Append;   --  grow; 0 = arena OOM
         end if;
         if Slot = 0 then
            Akernel_User.Console.Put_Line
              ("run: job table allocation failed");
            return Akernel_User.CLI.RC_Error;
         end if;
         --  Spawn into LOCAL stage bookkeeping; the slot is only
         --  committed once every stage is live, so a mid-spawn
         --  failure (Spawn_Pipeline cleans up after itself) never
         --  leaves a half-registered job behind.
         declare
            Procs  : SE.Proc_Set := (others => 0);
            Pipes  : SE.Pipe_Set :=
              (others => (others => Character'Val (0)));
            PLens  : SE.Pipe_Len_Set := (others => 0);
            NStage : Natural := 0;
            Ok     : Boolean;
         begin
            if SE.Has_Metachar (Rest) then
               SE.Spawn_Pipeline
                 (Rest, Slot, Procs, Pipes, PLens, NStage, Ok);
               if not Ok then
                  return Akernel_User.CLI.RC_Error;
               end if;
            else
               declare
                  RW_Last  : Natural;
                  RA_First : Natural;
               begin
                  Split_Cmd (Rest, RW_Last, RA_First);
                  Procs (1) := SE.Spawn_Cmd
                    (Rest (Rest'First .. RW_Last),
                     (if RA_First > Rest'Last then ""
                      else Rest (RA_First .. Rest'Last)), "", "");
               end;
               if Procs (1) = 0 then
                  return Akernel_User.CLI.RC_Error;
               end if;
               NStage := 1;
            end if;
            Jobs (Slot).State  := Job_Active;
            Jobs (Slot).Procs  := Procs;
            Jobs (Slot).NStage := NStage;
            Jobs (Slot).Pipes  := Pipes;
            Jobs (Slot).PLens  := PLens;
            Jobs (Slot).Len := Natural'Min (64, Rest'Length);
            Jobs (Slot).Cmd (1 .. Jobs (Slot).Len) :=
              Rest (Rest'First .. Rest'First + Jobs (Slot).Len - 1);
         end;
         Akernel_User.Console.Put_Line
           ("started job" & Natural'Image (Slot) & ": " &
            Jobs (Slot).Cmd (1 .. Jobs (Slot).Len));
         return 0;
      end;
   end Run_Background;

   function Wait_Job (Args : String) return U64 is
      N    : Natural;
      RC   : U64 := 0;

      --  Claim one job: blocking-reap its stages (Active) or
      --  take the harvested code (Done), then free the slot.
      procedure Reap_Job (J : Natural; Code : out U64) is
      begin
         if Jobs (J).State = Job_Active then
            SE.Reap_Pipeline
              (Jobs (J).Procs, Jobs (J).Pipes, Jobs (J).PLens,
               Jobs (J).NStage, Code);
         else
            Code := Jobs (J).Code;
         end if;
         Jobs (J).State := Job_Free;
      end Reap_Job;
   begin
      --  NO pre-harvest here: a completed-but-unreaped job
      --  still holds its slot (and its exit code) until
      --  somebody waits on it — reaping it silently first
      --  would make `wait 1` lose the code to "no such job".
      if Args'Length = 0 then
         --  Bare wait with no jobs at all is the clock command
         --  (milestone 59): C:Wait sleeps one second.
         declare
            Any : Boolean := False;
         begin
            for J in 1 .. Job_Tab.Last loop
               Any := Any or else Jobs (J).State /= Job_Free;
            end loop;
            if not Any then
               return SE.Exec ("Wait", "");
            end if;
         end;
         --  Bare wait: every known job, slot order; RC = the
         --  last job's exit code. Done jobs hand their code
         --  over without blocking.
         for J in 1 .. Job_Tab.Last loop
            if Jobs (J).State /= Job_Free then
               Reap_Job (J, RC);
            end if;
         end loop;
         return RC;
      end if;
      N := Parse_Nat (Args);
      if N < 1 or else N > Job_Tab.Last
        or else Jobs (N).State = Job_Free
      then
         --  Milestone 59: C:Wait (the clock command) shares the
         --  name. When the argument names no live or completed
         --  job, the C: command wins (Amiga precedence) —
         --  "wait 1" with no jobs sleeps one second.
         return SE.Exec ("Wait", Args);
      end if;
      Reap_Job (N, RC);
      return RC;
   end Wait_Job;

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
         if Word /= "endcli" then
            Endcli_Warned := False;
         end if;
         if Word = "help" then
            Akernel_User.Console.Put_Line ("akernel shell — builtins:");
            Akernel_User.Console.Put_Line ("  help            this text");
            Akernel_User.Console.Put_Line
              ("  endcli          close this console window and exit");
             Akernel_User.Console.Put_Line
               ("  execute <f> [a] run a script; args bind via .key");
             Akernel_User.Console.Put_Line
               ("                  scripts: if/else/endif, lab/skip, quit,");
             Akernel_User.Console.Put_Line
               ("                  failat, echo, ask, <var>, .def/.set");
             Akernel_User.Console.Put_Line
               ("                  (C:Execute runs scripts for programs)");
            Akernel_User.Console.Put_Line
              ("  <cmd> [args]    run a C: or Sys: command");
            Akernel_User.Console.Put_Line
              ("  A | B           pipe A's output into B");
            Akernel_User.Console.Put_Line
              ("  A > file        redirect output ('<' reads stdin)");
            Akernel_User.Console.Put_Line
              ("  run <cmd> ...   background a command or pipeline");
            Akernel_User.Console.Put_Line
              ("  jobs            list/harvest background jobs");
            Akernel_User.Console.Put_Line
              ("  wait [n]        RC = job n's (or last) exit code;"); 
            Akernel_User.Console.Put_Line
              ("                  no matching job -> C:Wait (sleep)");
            Akernel_User.Console.Put_Line
              ("  pri <job> <n>   set a background job's priority");
            return 0;
         elsif Word = "endcli" then
            if Jobs_Active > 0 and then not Endcli_Warned then
               Endcli_Warned := True;
               Akernel_User.Console.Put_Line
                 ("there are running jobs (endcli again to abandon)");
               return Akernel_User.CLI.RC_Warn;
            end if;
            --  Amiga EndCLI (M85a): ask the console server to
            --  close its window; a window console (the terminal)
            --  answers 0 and closes, taking this channel down —
            --  we exit.  The serial console answers 1 (no
            --  window) and we stay up.
            if Akernel_User.Streams.Endcli (Console_EP) = 0 then
               Process_Exit;
            end if;
            Akernel_User.Console.Put_Line
              ("endcli: console is not a window");
            return Akernel_User.CLI.RC_Warn;
         elsif Word = "run" then
            return Run_Background (Rest);
         elsif Word = "jobs" then
            Harvest (Loud => True);
            return 0;
         elsif Word = "pri" then
            --  Amiga ChangeTaskPri lineage: `pri <job> <n>` sets
            --  the scheduling priority of every live stage of a
            --  background job (-128..127) through its process
            --  caps (Manage right — the shell owns its
            --  children's caps).
            declare
               J_Last  : Natural;
               P_First : Natural;
               N       : Natural;
               Pri     : Integer;
               Old     : Integer := 0;
               Ok      : Boolean;
               Bad     : Boolean := False;
            begin
               Split_Cmd (Rest, J_Last, P_First);
               if P_First > Rest'Last then
                  Akernel_User.Console.Put_Line
                    ("usage: pri <job> <priority>");
                  return Akernel_User.CLI.RC_Error;
               end if;
               N := Parse_Nat (Rest (Rest'First .. J_Last));
               Pri := Parse_Int (Rest (P_First .. Rest'Last), Ok);
               if not Ok then
                  Akernel_User.Console.Put_Line
                    ("pri: bad priority '" & Rest (P_First .. Rest'Last)
                     & "'");
                  return Akernel_User.CLI.RC_Error;
               end if;
               if N < 1 or else N > Job_Tab.Last
                 or else Jobs (N).State /= Job_Active
               then
                  Akernel_User.Console.Put_Line
                    ("pri: no active job " & Rest (Rest'First .. J_Last));
                  return Akernel_User.CLI.RC_Error;
               end if;
               for S in 1 .. Jobs (N).NStage loop
                  if Jobs (N).Procs (S) /= 0
                    and then Set_Priority
                      (Target       => Jobs (N).Procs (S),
                       New_Priority => Pri,
                       Old_Priority => Old) /= 0
                  then
                     Bad := True;
                  end if;
               end loop;
               if Bad then
                  Akernel_User.Console.Put_Line ("pri: set failed");
                  return Akernel_User.CLI.RC_Error;
               end if;
               return 0;
            end;
         elsif Word = "wait" then
            return Wait_Job (Rest);
          elsif Word = "execute" then
             if Rest'Length = 0 then
                Akernel_User.Console.Put_Line
                  ("usage: execute <script> [args]");
                return Akernel_User.CLI.RC_Error;
             end if;
             return Run_Script (Rest);
         else
            if SE.Has_Metachar (Cmd) then
               return SE.Run_Pipeline (Cmd);
            end if;
            return SE.Exec (Word, Rest);
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
    --  Milestone 70: further arguments are the script's .key
    --  args ("Shell execute s a b" binds a,b positionally).
    if Akernel_User.CLI.Arg_Count >= 1
      and then Akernel_User.CLI.Argument (1) = "execute"
    then
       if Akernel_User.CLI.Arg_Count < 2 then
          Akernel_User.CLI.Fail_With ("usage: Shell execute <script>",
                                      Akernel_User.CLI.RC_Error);
       end if;
       declare
          Rest : String (1 .. 160);
          RL   : Natural := 0;
       begin
          for I in 2 .. Akernel_User.CLI.Arg_Count loop
             declare
                A : constant String := Akernel_User.CLI.Argument (I);
             begin
                exit when RL + A'Length + 1 > Rest'Length;
                if RL > 0 then
                   RL := RL + 1;
                   Rest (RL) := ' ';
                end if;
                Rest (RL + 1 .. RL + A'Length) := A;
                RL := RL + A'Length;
             end;
          end loop;
          Akernel_User.CLI.Exit_With (Run_Script (Rest (1 .. RL)));
       end;
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
