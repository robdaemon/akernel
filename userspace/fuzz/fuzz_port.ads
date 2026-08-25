with Akernel_User.Syscalls;
with Trinket.App_Port;

--  Milestone 68 fuzz section: headless test of Trinket.App_Port —
--  the Swing-style user port that lets worker tasks report to a
--  window's event-dispatch thread. No Bureau needed: the test
--  builds the same pieces a window owns (sink endpoint, one-page
--  ring) and plays event loop on the main thread.
--
--  The notification is NOT created here: a thread binds exactly
--  one notification for its whole life (the kernel rejects a
--  second bind), and fuzz's main thread is already bound to the
--  ntfn section's N2 earlier in the run. Run_Tests takes that
--  bound cap and signals it with App_Signal_Bit — exactly what a
--  Trinket window does with its own bound notification.
--
--  Covers: wake path (worker Post signals the ntfn, main blocked
--  in IPC_Recv wakes with Notification_Label + App_Signal_Bit),
--  per-producer FIFO and payload integrity, two concurrent
--  producers (protected-lock serialisation), drop-new overflow,
--  same-thread posts, and the reserved quit code.
package Fuzz_Port is
   procedure Run_Tests (Bound_Ntfn : Akernel_User.Syscalls.U64);
   --  Bound_Ntfn must be the notification cap already bound to the
   --  calling thread (Write right needed for signalling). It is
   --  NOT deleted here — the binding outlives the test.
end Fuzz_Port;
