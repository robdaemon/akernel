with Akernel_User.Console;
with Akernel_User.Syscalls;
with Task_Test_Pkg;

procedure Task_Test is
begin
   Akernel_User.Syscalls.Debug_Put_Line ("task_test: main start");
   Akernel_User.Console.Put_Line ("task_test: main start");
   Task_Test_Pkg.Wait_For_Worker;
   Akernel_User.Console.Put_Line ("task_test: main done");
   Akernel_User.Syscalls.Debug_Put_Line ("task_test: main done");
end Task_Test;
