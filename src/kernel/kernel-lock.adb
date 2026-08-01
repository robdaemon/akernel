with Board.UART;
with Interfaces;
with Kernel.CPUs;
with System;

package body Kernel.Lock is
   use type Interfaces.Unsigned_64;

   subtype U64 is Interfaces.Unsigned_64;

   procedure Raw_Spin_Lock (Lock : System.Address)
     with Import, Convention => C, External_Name => "riscv_spin_lock";

   procedure Raw_Spin_Unlock (Lock : System.Address)
     with Import, Convention => C, External_Name => "riscv_spin_unlock";

   function Raw_Scause return U64
     with Import, Convention => C, External_Name => "riscv_read_scause";

   function Raw_Sepc return U64
     with Import, Convention => C, External_Name => "riscv_read_sepc";

   function Raw_Stval return U64
     with Import, Convention => C, External_Name => "riscv_read_stval";

   function Raw_Try_Lock (Lock : System.Address) return U64
     with Import, Convention => C, External_Name => "riscv_try_lock";

   --  Exported under C names: the trap trampoline releases the lock
   --  itself (Owner := Nobody, then a release-ordered unlock) as the
   --  final step before trap_return, so the handler's C stack is
   --  never touched after the lock is gone.
   Lock_Word : aliased U64 := 0
     with Alignment => 8, Export, Convention => C,
          External_Name => "kernel_lock_word";

   --  Re-entry check: the hart holding the lock, or Nobody.  Written
   --  after acquiring / before releasing; only the owning hart's own
   --  re-acquire can observe a stale value.
   Nobody : constant U64 := U64'Last;
   Owner  : U64 := Nobody
     with Export, Convention => C,
          External_Name => "kernel_lock_owner";

   Dying     : Boolean := False;
   Dump_Lock : aliased U64 := 0
     with Alignment => 8;

   --  Non-blocking single claim: a fatal dump may itself take a
   --  nested trap whose handler lands here again; spinning on the
   --  dump lock would deadlock the hart with half a dump printed.
   function Try_Enter_Fatal return Boolean is
   begin
      if Raw_Try_Lock (Dump_Lock'Address) /= 0 then
         return False;
      end if;
      if Dying then
         Raw_Spin_Unlock (Dump_Lock'Address);
         return False;
      end if;
      Dying := True;
      Raw_Spin_Unlock (Dump_Lock'Address);
      return True;
   end Try_Enter_Fatal;

   procedure Acquire is
      Self : constant U64 := U64 (Kernel.CPUs.Current);
   begin
      if Owner = Self then
         if not Try_Enter_Fatal then
            --  Another hart is already dumping a fatal; halt quietly.
            loop
               null;
            end loop;
         end if;
         --  Panic path: unsafe prints (this hart may hold the UART
         --  print lock if a fault struck mid-message).
         Board.UART.Put_Unsafe ("fatal: kernel lock re-acquired, hart ");
         Board.UART.Put_Hex_Unsafe (Self);
         Board.UART.Put_Unsafe (" scause ");
         Board.UART.Put_Hex_Unsafe (Raw_Scause);
         Board.UART.Put_Unsafe (" sepc ");
         Board.UART.Put_Hex_Unsafe (Raw_Sepc);
         Board.UART.Put_Unsafe (" stval ");
         Board.UART.Put_Hex_Unsafe (Raw_Stval);
         Board.UART.Put_Line_Unsafe ("");
         loop
            null;
         end loop;
      end if;

      Raw_Spin_Lock (Lock_Word'Address);
      Owner := Self;
   end Acquire;

   procedure Release is
   begin
      Owner := Nobody;
      Raw_Spin_Unlock (Lock_Word'Address);
   end Release;

end Kernel.Lock;
