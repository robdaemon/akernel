with System;
with Akernel_User.Syscalls;

--  Trinket app port (milestone 68): the Swing/Amiga-style user port
--  that lets worker tasks talk to a window's event loop without ever
--  touching the widget tree.
--
--  The rule (Swing's EDT, Amiga's single-writer): ONLY the thread
--  that runs the window event loop — the event-dispatch thread —
--  reads/mutates widgets, draws, and drains this port. Workers call
--  Post from any thread; the loop thread Drain + dispatches.
--
--  Mechanism mirrors the Bureau v3 input channel: a one-page ring
--  (head word 0, tail word 1, then 4-word slots) plus a signal bit
--  on the window's thread-bound notification. Post's Ntfn_Signal
--  wakes the loop thread's blocking IPC_Recv with the synthetic
--  Notification_Label message (word 0 = pending bits). No kernel
--  changes; the cap table is process-wide so any thread can signal.
--
--  Multiple producers are serialised by a Ravenscar protected lock
--  around head allocation + slot write (the head bump must not
--  become visible before the slot contents). Single consumer, so
--  the tail word is lock-free. Full ring => drop-new, Post returns
--  False (same policy as Bureau's input queue).
package Trinket.App_Port is
   use type Trinket.U64;

   --  Bureau's input channel signals bit 1 (Input_Signal_Bit in
   --  Akernel_User.Window); the app port uses bit 2.
   App_Signal_Bit : constant U64 := 2;

   --  Reserved message code: Request_Quit posts this. Apps use
   --  codes >= 1.
   App_Code_Quit : constant U64 := 0;

   Slot_Words : constant U64 := 4;              --  (Code, A0, A1, A2)
   Max_Events : constant U64 := (512 - 2) / 4;  --  127 per page

   type Port is limited private;

   type Msg_Callback is access procedure (Code, A0, A1, A2 : U64);

   procedure Setup
     (P        : in out Port;
      Page     : System.Address;
      Ntfn_Cap : U64);
   --  Page must be a mapped, writable 4 KiB page owned by the
   --  caller (cap hygiene stays with the caller). Head/tail are
   --  zeroed here. Ntfn_Cap must carry the Write right and be
   --  bound to the event-loop thread.

   function Post
     (P             : in out Port;
      Code, A0, A1, A2 : U64) return Boolean;
   --  Any thread. True when the message was queued and the loop
   --  thread signalled; False when the ring is full (dropped).

   procedure Drain
     (P         : in out Port;
      Cb        : Msg_Callback;
      Quit_Seen : out Boolean);
   --  Event-loop thread only. Invokes Cb once per queued message,
   --  in FIFO order. App_Code_Quit is NOT dispatched to Cb (Cb may
   --  be null); it sets Quit_Seen instead — the window's Run loop
   --  turns that into loop exit.

private

   type Word_Array is array (U64 range 0 .. 511) of U64
     with Volatile_Components;

   protected type Head_Lock is
      procedure Put
        (Page         : System.Address;
         Code, A0, A1, A2 : U64;
         Ok           : out Boolean);
      --  Claim a slot, write it, bump head — atomically.
   end Head_Lock;

   type Port is limited record
      Page     : System.Address := System.Null_Address;
      Ntfn_Cap : U64 := 0;
      Lock     : Head_Lock;
   end record;

end Trinket.App_Port;
