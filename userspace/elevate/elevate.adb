with Interfaces;
with System.Storage_Elements;
with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.IPC;
with Akernel_User.Syscalls;

--  Elevate: run a command with the admin cap (milestone 45;
--  the Amiga has no analog — think sudo). A dumb client of
--  System/Elevated: packs the command line into a one-page
--  memory object, Calls the elevation service (uniform ABI
--  handle 5), and exits with the child's exit code. The admin
--  cap never lands in THIS namespace — Elevated mints a
--  Manage-only copy straight into the child's grant list.
--
--  Usage: Elevate <command> [args...]
--  Output goes to Elevated's console (the serial log today —
--  window consoles are Send-only and cannot be delegated).
--
--  Spawned by the shell under the uniform program ABI:
--  1 = console stream (Send), 2 = file server (Send),
--  5 = elevation service (Send; absent without a spawner
--  chain — the Call then fails and we exit RC_Fail).

procedure Elevate is
   use Akernel_User.Syscalls;
   use type U64;

   package Proto is new Akernel_User.IPC (U64, U64);

   Svc_EP     : constant U64 := 5;
   Op_Elevate : constant U64 := 1;
   --  The shell-proven staging VA — 0x05C0_0000 landed inside
   --  the RTS heap (Mem_Map failed, "out of memory").
   Stage_VA   : constant U64 := 16#5440_0000#;

   Mem_Cap : U64;
   St      : U64;
   R_Label : U64;
   Code    : U64 := Akernel_User.CLI.RC_Fail;
begin
   Akernel_User.Console.Set_Endpoint (1);

   if Akernel_User.CLI.Arg_Count < 1 then
      Akernel_User.CLI.Fail_With
        ("usage: Elevate <command> [args...]",
         Akernel_User.CLI.RC_Error);
   end if;

   --  Pack "cmd args..." NUL-terminated into one page.
   Mem_Cap := Mem_Alloc (1);
   if Mem_Cap = Syscall_Failed
     or else Mem_Map (Address_Space_Cap, Mem_Cap, Stage_VA, 0,
                      4096, 3) /= 0
   then
      Akernel_User.CLI.Fail_With ("Elevate: out of memory",
                                  Akernel_User.CLI.RC_Fail);
   end if;

   declare
      use System.Storage_Elements;
      type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;
      Page : Byte_Array (0 .. 4095)
        with Address => To_Address (Integer_Address (Stage_VA));
      Pos  : U64 := 0;
   begin
      for A in 1 .. Akernel_User.CLI.Arg_Count loop
         declare
            Arg : constant String := Akernel_User.CLI.Argument (A);
         begin
            if A > 1 then
               Page (Pos) := Character'Pos (' ');
               Pos := Pos + 1;
            end if;
            for C of Arg loop
               exit when Pos >= 4095;
               Page (Pos) := Interfaces.Unsigned_8
                 (Character'Pos (C));
               Pos := Pos + 1;
            end loop;
            exit when Pos >= 4095;
         end;
      end loop;
      Page (Pos) := 0;
   end;

   St := Proto.Call
     (Svc_EP, Op_Elevate, 0,
      Send_Caps      => (0 => Mem_Cap, others => 0),
      Response_Label => R_Label,
      Response       => Code);

   if St /= 0 then
      Akernel_User.CLI.Fail_With
        ("Elevate: the elevation service is unavailable",
         Akernel_User.CLI.RC_Fail);
   end if;

   if Code = 255 then
      --  The daemon staged nothing: its console is the serial
      --  boot console, so the user-facing message is OURS.
      --  255 is elevated's cannot-find-executable reply.
      Akernel_User.CLI.Fail_With
        ("Elevate: cannot find executable: " &
         Akernel_User.CLI.Argument (1),
         Akernel_User.CLI.RC_Fail);
   end if;

   Akernel_User.CLI.Exit_With (Code);
end Elevate;
