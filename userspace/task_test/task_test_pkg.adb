with Aegir_User.Console;
with Aegir_User.Syscalls;

with Aegir_User.Syscalls;

package body Task_Test_Pkg is
   Done : Boolean := False;

   task body Worker is
   begin
      Aegir_User.Syscalls.Debug_Put_Line ("task_test: worker start");
      Aegir_User.Console.Put_Line ("task_test: worker start");
      delay 0.01;
      Aegir_User.Syscalls.Debug_Put_Line ("task_test: worker done");
      Aegir_User.Console.Put_Line ("task_test: worker done");
      Done := True;
   end Worker;

   procedure Wait_For_Worker is
      Timeout : Natural := 5000;  --  ~5s at 1ms delays
   begin
      Aegir_User.Syscalls.Debug_Put_Line ("task_test: wait start");
      while not Done and then Timeout > 0 loop
         delay 0.001;
         Timeout := Timeout - 1;
      end loop;
      if not Done then
         Aegir_User.Syscalls.Debug_Put_Line ("task_test: worker timed out");
      end if;
      Aegir_User.Syscalls.Debug_Put_Line ("task_test: wait end");
   end Wait_For_Worker;
begin
   Aegir_User.Syscalls.Debug_Put_Line ("task_test_pkg: body begin");
end Task_Test_Pkg;
