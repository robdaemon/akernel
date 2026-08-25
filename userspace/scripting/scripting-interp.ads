with Akernel_User.Syscalls;

--  Scripting.Interp (milestone 70 chunk 2): the AmigaDOS-subset
--  script interpreter core. The host (the shell's `execute`
--  builtin, Sys:C/Execute) instantiates this generic with its
--  own command dispatcher, so a script line runs exactly what
--  the host would run — builtins included — and `execute`
--  re-enters the interpreter through the same callback (Depth
--  threads the nesting cap across hosts).
--
--  Chunk-2 language: the milestone-42 linear runner (LF-
--  separated lines, ';' at column 1 starts a comment, stop at
--  the first RC >= 10 Amiga-failat style) PLUS locals and
--  substitution:
--    .key a,b,c     template: positional args bind to a,b,c
--    .k             .key alias
--    .def name=val  default when the arg is absent
--    .set name val  set a script local mid-script (value is the
--                   trimmed rest of the line; `.set name` clears
--                   it to empty — defined-empty, distinct from
--                   undefined, which errors)
--    <name>         substitutes the local, else ENV:<name>
--    <$name>        ENV: only
--  `<` followed by a space (or without a closing `>` on the
--  line) is literal — pipeline operators are standalone tokens,
--  so `< file` redirection is untouched. An undefined reference
--  is a hard error (RC 10, aborts the script), AmigaDOS "bad
--  substitution" style. .key/.k/.def are header directives:
--  they are only recognised before the first command line.
--
--  Control flow (chunk 3), keywords case-insensitive:
--    if [not] <cmd>        true iff the command's RC < failat
--                          (the condition RC is CONSUMED — it
--                          does not trip failat itself)
--    if [not] <a> eq|ne|gt|ge|lt|le <b> [val]
--                          case-insensitive strings; val = numeric
--    if [not] exists <path>
--    if / if not           tests the stored condition flag
--    else / endif          8-deep if stack; skipped blocks still
--                          track nested if/endif
--    lab <name> / skip <name> [back]
--                          skip abandons any open if frames —
--                          the classic loop idiom `if cond /
--                          skip loop back / endif` relies on it;
--                          an unknown label is RC 10
--    quit [rc]             stop the script, RC = rc (default 0)
--    failat <n>            abort threshold (default 10)
--    echo <text> [noline]  internal fast path; a line holding
--                          |, > or < falls through to C:Echo so
--                          redirection composes (noline is then
--                          unsupported)
--  `ask` lands in chunk 4.
generic
   --  Command dispatch: how the host runs one expanded command
   --  line. Nested subprograms are legal actuals (a formal
   --  subprogram carries no accessibility check, unlike an
   --  access-to-subprogram type would).
   with function Run_Line
     (Cmd : String) return Akernel_User.Syscalls.U64;
package Scripting.Interp is
   subtype U64 is Akernel_User.Syscalls.U64;

   Max_Script : constant := 16 * 1024;  --  slurp cap (bytes)
   Max_Nest   : constant := 4;          --  execute-in-script depth
   Max_Locals : constant := 16;         --  .key/.def/.set slots

   --  Run the script at Path (cwd-resolved) with whitespace-
   --  separated Args bound through the .key template. Depth is
   --  this run's nesting level: 1 for a top-level script, one
   --  more than the enclosing script's Depth for a nested
   --  `execute`. Returns the last command's RC, or RC_Error on
   --  a script-level failure (open/parse/bad substitution).
   function Run
     (Path  : String;
      Args  : String;
      Depth : Natural) return U64;

end Scripting.Interp;
