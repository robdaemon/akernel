--  Command-line support for C: commands (milestone 40b) — the
--  amiga.lib analog: one place for the conventions every CLI
--  program shares, so commands are logic-only.
--
--  Return codes follow the Amiga convention: a command exits with
--  RC_Ok on success; RC_Warn/RC_Error/RC_Fail are increasing
--  severities (scripts and the shell can branch on thresholds).
--  The code rides the exit syscall into the PCB and the spawner
--  reads it back through Reap_Process_Code (kernel milestone 40b).
--
--  Arguments are the whitespace-separated tokens of the spawn-time
--  args page (milestone 33a); Argument (1) is the FIRST token —
--  there is no argv[0], the caller knows its own name.
--
--  Variables are files (milestone 33a): ENV:<Name> holds the
--  value, global by construction.
with Interfaces;

package Akernel_User.CLI is
   subtype U64 is Interfaces.Unsigned_64;
   use type U64;
   RC_Ok    : constant U64 := 0;
   RC_Warn  : constant U64 := 5;
   RC_Error : constant U64 := 10;
   RC_Fail  : constant U64 := 20;

   --  Whitespace-separated tokens of the args page (no quoting
   --  yet). Argument returns "" for an out-of-range index.
   function Arg_Count return Natural;
   function Argument (Index : Positive) return String;

   --  ENV:<Name> read/write. Get_Env returns "" when unset or
   --  unreadable; values are truncated at 255 characters.
   --  Set_Env returns the file-protocol status (Status_Ok on
   --  success).
   function Get_Env (Name : String) return String;
   function Set_Env (Name : String; Value : String) return U64;

   --  Resolve a command name against the current directory,
   --  then the Path variable (or the built-in default search
   --  list: volume root, then C/). Returns the fully-qualified
   --  path to the executable, or "" if not found. Qualified
   --  names (containing ':' or '/') are returned unchanged.
   --  The current directory is always searched first (the
   --  Amiga current-dir rule; Sys:C/Path manages the list).
   function Resolve_Command (Name : String) return String;

   --  Current working directory (milestone 42): the ENV:CWD
   --  variable, global by construction like every variable;
   --  the boot volume when unset. Commands qualify relative
   --  path arguments through Resolve_Path — this package is the
   --  ONLY owner of the boot-volume name; programs never call
   --  Files.Set_Default_Volume (milestone 44: the default
   --  volume is the pre-cwd mechanism, and every path a
   --  command acts on is cwd-resolved and fully qualified
   --  before it reaches the file server).
   Boot_Volume : constant String := "BD0:";
   function Get_Cwd return String;
   function Set_Cwd (Path : String) return U64;

   --  Join a directory and a leaf: volume roots ("BD0:") take
   --  no slash, everything else gets one.
   function Join_Path (Dir, Leaf : String) return String;

   --  Collapse path components Amiga-style: each EMPTY
   --  component (an extra '/') ascends one directory — "/" is
   --  the parent, "//" the grandparent. ".." is accepted as an
   --  alias (fat32 dirs physically carry the entry); "." is NOT
   --  special (AmigaDOS has no dot components). Ascending past a
   --  volume root stays at the root.
   function Normalize_Path (Path : String) return String;

   --  Qualify a path argument against the cwd: paths containing
   --  ':' are already qualified; anything else is joined under
   --  the cwd. The result is normalized.
   function Resolve_Path (Path : String) return String;

   --  Print Message to the console, then exit with Code.
   procedure Fail_With (Message : String; Code : U64 := RC_Error)
     with No_Return;

   --  Exit with an explicit code (RC_Ok default).
   procedure Exit_With (Code : U64 := RC_Ok)
     with No_Return;
end Akernel_User.CLI;
