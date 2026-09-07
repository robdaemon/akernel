with Aegir_User.Console;
with Aegir_User.Syscalls;
with Task_Test_Pkg;

procedure Task_Test is
begin
   Aegir_User.Syscalls.Debug_Put_Line ("task_test: main start");
   Aegir_User.Console.Put_Line ("task_test: main start");
   Task_Test_Pkg.Wait_For_Worker;
   Aegir_User.Console.Put_Line ("task_test: main done");
   Aegir_User.Syscalls.Debug_Put_Line ("task_test: main done");
end Task_Test;
