with Interfaces;

package Thread_Test_Sync is
   subtype U32 is Interfaces.Unsigned_32;

   Worker_Done : U32 := 0 with Atomic, Volatile;
   --  Shared with the secondary thread; Atomic/Volatile give visibility
   --  on SMP and prevent the main loop from caching the value.

   procedure Worker
     with Export, Convention => C, External_Name => "thread_test_worker";
   --  Library-level entry point handed to Thread_Create.
end Thread_Test_Sync;
