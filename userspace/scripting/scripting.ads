with Akernel_User.Syscalls;

--  Scripting (milestone 70): the shared shell-script machinery.
--  Root package: the uniform-ABI handle constants every command
--  spawn grants, and the Split_Cmd line utility shared by the
--  shell and the execution engine. Deliberately declares NO U64
--  subtype of its own — clients `use Akernel_User.Syscalls` for
--  that, and two use-visible U64 subtypes would hide each other.
--
--  Children:
--    Scripting.Exec (chunk 1) — the command/pipeline execution
--      engine extracted unchanged from the shell: stage, spawn,
--      reap, pipelines, redirection.
--    Scripting.Interp (chunk 2) — the AmigaDOS-subset script
--      interpreter core.
package Scripting is

   --  Uniform namespace handles (milestone 31b): every spawned
   --  command inherits these from its spawner.
   Console_EP : constant Akernel_User.Syscalls.U64 := 1;
   FS_EP      : constant Akernel_User.Syscalls.U64 := 2;
   Win_EP     : constant Akernel_User.Syscalls.U64 := 3;
   Svc_EP     : constant Akernel_User.Syscalls.U64 := 5;

   --  Split a command line into its first word and the trimmed
   --  remainder: Word = Cmd (Cmd'First .. W_Last), the rest is
   --  Cmd (R_First .. Cmd'Last) (empty when R_First > Cmd'Last).
   procedure Split_Cmd
     (Cmd : String; W_Last : out Natural; R_First : out Natural);

end Scripting;
