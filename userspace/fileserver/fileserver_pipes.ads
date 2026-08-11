with Akernel_User.Syscalls;
with Interfaces;

--  PIPE: volume backing store (milestone 46a): Amiga-style named
--  pipes as a fileserver-INTERNAL virtual volume. A pipe is a
--  bounded FIFO ring; readers poll (Status_Not_Ready on an empty
--  non-EOF pipe, writers on a full one) because the kernel allows
--  only ONE outstanding reply per server thread — a deferred
--  reply would be destroyed by the next recv (reply-gone wakes
--  the deferred client). True blocking needs kernel reply-cap
--  duplication; poll semantics preserve the Amiga-visible
--  behaviour (names, FIFO order, explicit EOF).
--
--  EOF is EXPLICIT (Op_Close from the writer): the fs protocol
--  is stateless — no fids, no close-counting — so a pipe cannot
--  infer "all writers gone". The RTS redirect layer sends
--  Op_Close when a redirected program exits.
--
--  Library level so the rings live in BSS, never on the 16 KiB
--  server stack (the fileserver_tables burn class).

package Fileserver_Pipes is
   subtype U64 is Akernel_User.Syscalls.U64;

   Max_Pipes     : constant := 8;
   Pipe_Bytes    : constant := 16384;
   Max_Pipe_Name : constant := 40;

   --  Case-insensitive name lookup (fs convention); 0 = absent.
   function Find (Name : String) return Natural;

   --  Lookup, creating an empty pipe when absent; 0 = table full
   --  (or an empty/over-long name — both rejected Bad_Args by
   --  the caller before it gets here; 0 means "retry later").
   function Find_Or_Create (Name : String) return Natural;

   procedure Destroy (I : Natural);

   --  Op_Truncate on a pipe: empty the ring and clear EOF so the
   --  pipe can be reused (the shell reuses a small name pool).
   procedure Reset (I : Natural);

   --  Op_Close from a writer: no more data is coming. Reads keep
   --  draining the ring; an empty EOF pipe answers 0 bytes.
   procedure Set_EOF (I : Natural);
   function Is_EOF (I : Natural) return Boolean;

   function Buffered (I : Natural) return U64;
   function Space_Left (I : Natural) return U64;

   --  FIFO byte ops (the server copies to/from the mapped client
   --  buffer window one byte at a time — simple, and pipeline
   --  flushes are a few KiB at most).
   function Pop (I : Natural; B : out Interfaces.Unsigned_8)
                 return Boolean;
   procedure Push (I : Natural; B : Interfaces.Unsigned_8);

end Fileserver_Pipes;
