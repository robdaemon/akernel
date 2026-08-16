------------------------------------------------------------------------------
--  Akernel vendored System.Relative_Delays (milestone 59): the
--  embedded-runtime s-reldel routes through Ada.Real_Time.Delays,
--  which is tasking (System.Task_Primitives) — unavailable in this
--  No_Tasking runtime. The non-tasking delay statement path is
--  System.OS_Primitives.Timed_Delay (vendored, nanosleep over the
--  rdtime timebase), so Delay_For is a one-line forward.
------------------------------------------------------------------------------

with System.OS_Primitives;

package body System.Relative_Delays is

   procedure Delay_For (D : Duration) is
   begin
      System.OS_Primitives.Timed_Delay
        (D, System.OS_Primitives.Relative);
   end Delay_For;

end System.Relative_Delays;
