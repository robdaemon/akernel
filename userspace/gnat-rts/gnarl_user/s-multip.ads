package System.Multiprocessors is
   pragma Preelaborate (Multiprocessors);

   type CPU_Range is range 0 .. 4;

   subtype CPU is CPU_Range range 1 .. CPU_Range'Last;

   Not_A_Specific_CPU : constant CPU_Range := 0;

   function Number_Of_CPUs return CPU;
   pragma Inline (Number_Of_CPUs);

end System.Multiprocessors;
