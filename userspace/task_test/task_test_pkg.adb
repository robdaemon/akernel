with Akernel_User.Console;
with Akernel_User.Syscalls;

with Akernel_User.Syscalls;

package body Task_Test_Pkg is
   Done : Boolean := False;

   task body Worker is
   begin
      Akernel_User.Syscalls.Debug_Put_Line ("task_test: worker start");
      Akernel_User.Console.Put_Line ("task_test: worker start");
      delay 0.01;
      Akernel_User.Syscalls.Debug_Put_Line ("task_test: worker done");
      Akernel_User.Console.Put_Line ("task_test: worker done");
      Done := True;
   end Worker;

   procedure Wait_For_Worker is
      Timeout : Natural := 5000;  --  ~5s at 1ms delays
   begin
      Akernel_User.Syscalls.Debug_Put_Line ("task_test: wait start");
      while not Done and then Timeout > 0 loop
         delay 0.001;
         Timeout := Timeout - 1;
      end loop;
      if not Done then
         Akernel_User.Syscalls.Debug_Put_Line ("task_test: worker timed out");
      end if;
      Akernel_User.Syscalls.Debug_Put_Line ("task_test: wait end");
   end Wait_For_Worker;
begin
   Akernel_User.Syscalls.Debug_Put_Line ("task_test_pkg: body begin");
end Task_Test_Pkg;
