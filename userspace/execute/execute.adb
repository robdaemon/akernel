with Akernel_User.Syscalls;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.CLI;
with Scripting;
with Scripting.Exec;
with Scripting.Interp;

--  Execute: run a script (milestone 70 chunk 4) — the C:
--  command form of the shell's execute builtin, so OTHER
--  programs (and `run Sys:C/Execute ...`, which backgrounds a
--  script as a reapable job) get the AmigaDOS-subset
--  interpreter without a shell in the middle. Command lines
--  dispatch through Scripting.Exec (the same engine the shell
--  links: pipelines and redirection included); `execute` lines
--  re-enter Scripting.Interp with Depth + 1. ask prompts on
--  the console and reads the reply from STDIN — the
--  redirection trailer applies, so `echo y | Execute script`
--  composes. C:Execute is its own process: the nesting budget
--  starts fresh here.

procedure Execute is
   use Akernel_User.Syscalls;
   use Scripting;  --  handle constants, Split_Cmd
   use type U64;

   package SE renames Scripting.Exec;

   Nesting : Natural := 0;

   function Dispatch (Cmd : String) return U64;
   procedure Ask
     (Prompt : String; Reply : out String; Reply_Len : out Natural);

   package SI is new Scripting.Interp
     (Run_Line => Dispatch, Ask_Line => Ask);

   --  Rest is "<script> [args...]"; owns the nesting counter
   --  (Depth handed to Interp is the level AFTER incrementing).
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

   function Dispatch (Cmd : String) return U64 is
      W_Last  : Natural;
      R_First : Natural;
   begin
      if Cmd'Length = 0 then
         return 0;
      end if;
      Split_Cmd (Cmd, W_Last, R_First);
      declare
         Word : constant String := Cmd (Cmd'First .. W_Last);
         Rest : constant String :=
           (if R_First > Cmd'Last then ""
            else Cmd (R_First .. Cmd'Last));
      begin
         if Word = "execute" then
            if Rest'Length = 0 then
               Akernel_User.Console.Put_Line
                 ("usage: execute <script> [args]");
               return Akernel_User.CLI.RC_Error;
            end if;
            return Run_Script (Rest);
         elsif SE.Has_Metachar (Cmd) then
            return SE.Run_Pipeline (Cmd);
         else
            return SE.Exec (Word, Rest);
         end if;
      end;
   end Dispatch;

   procedure Ask
     (Prompt : String; Reply : out String; Reply_Len : out Natural)
   is
      EOF : Boolean;
   begin
      Akernel_User.Console.Put (Prompt);
      Akernel_User.CLI.Get_Line (Reply, Reply_Len, EOF);
      if EOF then
         Reply_Len := 0;
      end if;
   end Ask;

begin
   Akernel_User.Console.Set_Endpoint (Console_EP);
   Akernel_User.Files.Bind (FS_EP);

   if Akernel_User.CLI.Arg_Count < 1 then
      Akernel_User.CLI.Fail_With ("usage: Execute <script> [args]",
                                  Akernel_User.CLI.RC_Error);
   end if;
   declare
      SArgs : String (1 .. 160);
      SL    : Natural := 0;
   begin
      for I in 2 .. Akernel_User.CLI.Arg_Count loop
         declare
            A : constant String := Akernel_User.CLI.Argument (I);
         begin
            exit when SL + A'Length + 1 > SArgs'Length;
            if SL > 0 then
               SL := SL + 1;
               SArgs (SL) := ' ';
            end if;
            SArgs (SL + 1 .. SL + A'Length) := A;
            SL := SL + A'Length;
         end;
      end loop;
      Akernel_User.CLI.Exit_With
        (Run_Script
           (Akernel_User.CLI.Argument (1)
            & (if SL = 0 then "" else " " & SArgs (1 .. SL))));
   end;
end Execute;
