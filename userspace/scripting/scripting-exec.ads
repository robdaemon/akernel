with Akernel_User.Syscalls;

--  Scripting.Exec (milestone 70 chunk 1): the shell's command
--  execution engine, extracted unchanged so the script
--  interpreter (Scripting.Interp) and Sys:C/Execute link the
--  same code the interactive shell uses — one stage/spawn/reap
--  implementation, one pipeline parser.
--
--  Pipelines + redirection (milestone 46b), Amiga-style:
--  `A | B` connects A's output to B's input through a PIPE:
--  name; `> file` (final stage only) and `< file` (first
--  stage only) redirect through regular files. Operators
--  are standalone tokens (spaces around them); no quoting
--  yet. Stages run CONCURRENTLY, the pipeline RC is the
--  last stage's RC. Foreground pipes come from a small
--  PIPE:SH<n> pool, created + reset up front (Truncate
--  clears stale data/EOF) and deleted after the reap.
--  Milestone 69: `run` backgrounds a whole pipeline; its
--  pipes are slot-scoped PIPE:BG<j><s> names, deleted when
--  the job is reaped (see Spawn_Pipeline's Bg_Slot).
package Scripting.Exec is
   subtype U64 is Akernel_User.Syscalls.U64;

   --  Run Word as a child on the caller's channel: same console
   --  (Send, badge 0), fs and Bureau svc caps, a one-page
   --  argument string memory object at handle 4 (the Amiga
   --  command-line analog; milestone 33a - always granted, an
   --  empty page when Args is empty, so the handle layout stays
   --  uniform), the shared-library manager at handle 5
   --  (milestone 65), and the elevation service (Send) at handle
   --  6 (milestone 45). When Out_Path/In_Path is nonempty the
   --  args page gains the milestone-46b redirection trailer so
   --  the child's RTS routes console output / stdin through
   --  those fs paths. Returns the child process cap (0 on
   --  failure); the CALLER reaps (pipelines run stages
   --  concurrently).
   function Spawn_Cmd
     (Word     : String;
      Args     : String;
      Out_Path : String;
      In_Path  : String) return U64;

   --  Spawn Word and block until it exits; RC_Error when the
   --  spawn itself failed, else the child's exit code.
   function Exec (Word : String; Args : String) return U64;

   --  True when Cmd holds a pipeline/redirection operator.
   function Has_Metachar (Cmd : String) return Boolean;

   Max_Stages : constant := 4;

   --  Shared pipeline bookkeeping (milestone 69): the spawn
   --  phase hands the stage process caps and owned pipe names
   --  to the caller — the foreground path reaps immediately,
   --  `run` parks them in a job slot until harvest/wait.
   type Proc_Set is array (1 .. Max_Stages) of U64;
   subtype Pipe_Name_Str is String (1 .. 16);
   type Pipe_Set is array (1 .. Max_Stages - 1) of Pipe_Name_Str;
   type Pipe_Len_Set is array (1 .. Max_Stages - 1) of Natural;

   --  Spawn every stage of a pipeline CONCURRENTLY (the m46b
   --  parser/wiring, split out in milestone 69 so `run` can
   --  background the group). Bg_Slot = 0 is the foreground:
   --  pipes come from the rotating PIPE:SH<n> pool. Bg_Slot > 0
   --  names pipes PIPE:BG<slot><stage> — slot-scoped, so the
   --  foreground pool's name recycling can never truncate a
   --  live background job's pipe. On failure everything spawned
   --  and created is reaped and deleted before return
   --  (Ok = False).
   procedure Spawn_Pipeline
     (Cmd     : String;
      Bg_Slot : Natural;
      Procs   : out Proc_Set;
      Pipes   : out Pipe_Set;
      PLens   : out Pipe_Len_Set;
      NStage  : out Natural;
      Ok      : out Boolean);

   procedure Delete_Pipes (Pipes : Pipe_Set; PLens : Pipe_Len_Set);

   --  Blocking reap of a whole pipeline group (milestone 69):
   --  stages in order, RC = the LAST stage's exit code, proc
   --  caps deleted as they are reaped, owned pipes deleted once
   --  every stage is dead. Foreground pipelines and `wait` on a
   --  background job both funnel through here.
   procedure Reap_Pipeline
     (Procs  : in out Proc_Set;
      Pipes  : Pipe_Set;
      PLens  : Pipe_Len_Set;
      NStage : Natural;
      RC     : out U64);

   --  Foreground pipeline (milestone 46b): spawn all stages,
   --  block until every stage exits, RC = the last stage's RC.
   function Run_Pipeline (Cmd : String) return U64;

end Scripting.Exec;
