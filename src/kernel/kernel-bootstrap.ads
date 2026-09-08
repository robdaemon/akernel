with Kernel.Tasks;

--  Home of the kernel-started (bootstrap) process/thread records.
--  These used to be locals of the Aegir main procedure, i.e. they
--  lived on the boot CPU's main stack just below __stack_top; the
--  idle path re-uses that stack fresh from the top after boot and,
--  whenever it nested deep enough (wakeups, scheduling), descended
--  straight into init's own PCB/TCB and corrupted the cap table.
--  Static storage is unreachable by any stack growth.
package Kernel.Bootstrap is

   Bootstrap_Process : aliased Kernel.Tasks.Process_Control_Block;
   Driver_Process    : aliased Kernel.Tasks.Process_Control_Block;
   Init_Process      : aliased Kernel.Tasks.Process_Control_Block;
   Bootstrap_Task    : aliased Kernel.Tasks.Thread_Control_Block;
   Driver_Task       : aliased Kernel.Tasks.Thread_Control_Block;
   Init_Task         : aliased Kernel.Tasks.Thread_Control_Block;

end Kernel.Bootstrap;
