with Ada.Unchecked_Conversion;
with Interfaces;
with Kernel.Last_Chance;
with System;

package body Kernel.Stack_Guard is
   use Interfaces;

   type Word_Ptr is access all Interfaces.Unsigned_64;

   function To_Word_Ptr is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => Word_Ptr);

   function To_Addr is new Ada.Unchecked_Conversion
     (Source => Interfaces.Unsigned_64,
      Target => System.Address);

   Overflow_Msg : aliased constant String :=
     "kernel stack overflow" & ASCII.NUL;

   procedure Plant (Top : Interfaces.Unsigned_64;
                    Size : Interfaces.Unsigned_64) is
      Bottom : constant Interfaces.Unsigned_64 := Top - Size;
   begin
      To_Word_Ptr (To_Addr (Bottom)).all := Canary;
   end Plant;

   procedure Check (Top : Interfaces.Unsigned_64;
                    Size : Interfaces.Unsigned_64) is
      Bottom : constant Interfaces.Unsigned_64 := Top - Size;
   begin
      if To_Word_Ptr (To_Addr (Bottom)).all /= Canary then
         --  Report through the last-chance handler: prints the hart
         --  and this message, then halts (never returns).
         Kernel.Last_Chance.Handler (Overflow_Msg'Address, 0);
      end if;
   end Check;

end Kernel.Stack_Guard;
