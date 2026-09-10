with Aegir_User.Console;
with Aegir_User.Syscalls;
with Interfaces;
with System.Machine_Code;

--  Floating-point context regression (m47a): the trap frame must carry
--  f0..f31 across a context switch.  Two instances of this program run
--  concurrently; each seeds the callee-saved doubles f28..f31 with a
--  value derived from the monotonic clock, then repeatedly yields so
--  the timer preempts it and the sibling runs (clobbering those very
--  registers with *its* value).  If the kernel does not save/restore
--  the FP state, the read-back no longer matches and the check fails.
--
--  The registers are only ever touched through inline assembly, so the
--  compiler cannot reload the value from memory behind our back.
procedure Fpchk is
   use Aegir_User.Syscalls;
   use type Interfaces.Unsigned_64;

   V            : Interfaces.Unsigned_64;
   R0, R1, R2, R3 : Interfaces.Unsigned_64;
   Bad          : Natural := 0;
   Rounds       : constant := 40;
   Yield_Count  : constant := 25;

   procedure Seed is
   begin
      System.Machine_Code.Asm
        ("fmv.d.x f28, %0" & ASCII.LF &
         "fmv.d.x f29, %0" & ASCII.LF &
         "fmv.d.x f30, %0" & ASCII.LF &
         "fmv.d.x f31, %0",
         Inputs  => (Interfaces.Unsigned_64'Asm_Input ("r", V)),
         Volatile => True);
   end Seed;

   procedure Read_Back is
   begin
      System.Machine_Code.Asm
        ("fmv.x.d %0, f28" & ASCII.LF &
         "fmv.x.d %1, f29" & ASCII.LF &
         "fmv.x.d %2, f30" & ASCII.LF &
         "fmv.x.d %3, f31",
         Outputs => (Interfaces.Unsigned_64'Asm_Output ("=r", R0),
                     Interfaces.Unsigned_64'Asm_Output ("=r", R1),
                     Interfaces.Unsigned_64'Asm_Output ("=r", R2),
                     Interfaces.Unsigned_64'Asm_Output ("=r", R3)),
         Volatile => True);
   end Read_Back;
begin
   Aegir_User.Console.Set_Endpoint (1);

   --  A per-instance pattern: the clock value mixed through an odd
   --  multiplier, so two instances never hold the same bits.
   V := Read_Time * 16#9E37_79B9_7F4A_7C15#;
   if V = 0 then
      V := 16#3FF0_0000_0000_0001#;
   end if;

   for Round in 1 .. Rounds loop
      Seed;
      for Y in 1 .. Yield_Count loop
         Yield;
      end loop;
      Read_Back;
      if R0 /= V or else R1 /= V or else R2 /= V or else R3 /= V then
         Bad := Bad + 1;
      end if;
   end loop;

   if Bad = 0 then
      Aegir_User.Console.Put_Line ("fp context ok");
   else
      Aegir_User.Console.Put_Line ("fp context FAIL");
   end if;
end Fpchk;
