with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Files;

--  CD: current directory (milestone 42; the Amiga C:CD analog).
--  "CD" prints the cwd; "CD <dir>" changes it. Relative paths
--  resolve against the cwd; "/" is the Amiga parent idiom
--  (cd / goes up one level, // two) via CLI.Resolve_Path. The
--  cwd is the ENV:CWD variable — global like every variable —
--  so a child CD moves the parent's session too, Amiga-style.
--
--  The target must be a directory: fat32 answers Stat with
--  Not_Found for a missing path, Ok for a FILE (with its size),
--  and Bad_Args for a directory (no dir stat) — Bad_Args is
--  exactly the "is a directory" signal here.
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send).

procedure CD is
   package CLI renames Akernel_User.CLI;
   use type CLI.U64;

   Size : CLI.U64;
   St   : CLI.U64;
begin
   Akernel_User.Console.Set_Endpoint (1);
   Akernel_User.Files.Bind (2);
   Akernel_User.Files.Set_Default_Volume ("BD0");

   if CLI.Arg_Count = 0 then
      Akernel_User.Console.Put_Line (CLI.Get_Cwd);
      CLI.Exit_With (CLI.RC_Ok);
   end if;

   declare
      Target : constant String := CLI.Resolve_Path (CLI.Argument (1));
   begin
      St := Akernel_User.Files.Stat (Target, Size);
      if St = Akernel_User.Files.Status_Not_Found then
         CLI.Fail_With ("CD: no such directory " & Target,
                        CLI.RC_Error);
      elsif St = Akernel_User.Files.Status_Ok then
         CLI.Fail_With ("CD: not a directory " & Target,
                        CLI.RC_Error);
      elsif St /= Akernel_User.Files.Status_Bad_Args then
         CLI.Fail_With ("CD: can't read " & Target, CLI.RC_Error);
      end if;
      --  Bad_Args = directory (or volume root). Adopt it.
      St := CLI.Set_Cwd (Target);
      if St /= Akernel_User.Files.Status_Ok then
         CLI.Fail_With ("CD: can't set CWD", CLI.RC_Error);
      end if;
   end;

   CLI.Exit_With (CLI.RC_Ok);
end CD;
