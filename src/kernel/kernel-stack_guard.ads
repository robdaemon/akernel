with Interfaces;

--  Kernel stack overflow tripwire.  Every kernel stack (per-task
--  4 KiB pages and the per-hart idle main/trap stacks) gets a canary
--  word at its lowest address when it is created.  Code that nests
--  past the bottom of a stack clobbers the word first; Check reports
--  "kernel stack overflow" through the Last_Chance handler (visible
--  panic, halts this hart) at the next checkpoint.  Guard pages below
--  each stack would fault at the moment of overflow instead; deferred
--  as a hardening follow-up (planting here already gives the marker a
--  home for that check to reuse).
package Kernel.Stack_Guard is

   Canary : constant Interfaces.Unsigned_64 := 16#AE67_1357_9BDF_CA1E#;
   --  Any 64-bit pattern that stack traffic never writes on purpose.

   --  Top and Size are kernel virtual addresses/byte counts (Bottom =
   --  Top - Size).  A task stack: Top = Phys_To_Virt (frame + page),
   --  Size = one page.  An idle stack: Top = Idle_*_Stack_Top (CPU).
   procedure Plant (Top : Interfaces.Unsigned_64;
                    Size : Interfaces.Unsigned_64);

   procedure Check (Top : Interfaces.Unsigned_64;
                    Size : Interfaces.Unsigned_64);

end Kernel.Stack_Guard;
