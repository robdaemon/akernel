with Akernel_User.Syscalls;
with System.Machine_Code;

package body Thread_Test_Sync is

   procedure Worker is
   begin
      --  Minimal worker: signal completion and terminate.
      Akernel_User.Syscalls.Debug_Put_Line ("thread_test: worker alive");
      Worker_Done := 1;
      --  Ensure the store is visible to the main thread on other
      --  harts before Thread_Exit completes.
      System.Machine_Code.Asm ("fence", Volatile => True);
      Akernel_User.Syscalls.Thread_Exit;
   end Worker;

end Thread_Test_Sync;
