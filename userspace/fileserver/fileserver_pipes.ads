with Akernel_User.Syscalls;
with Interfaces;

--  PIPE: volume backing store (milestone 46a): Amiga-style named
--  pipes as a fileserver-INTERNAL virtual volume. A pipe is a
--  bounded FIFO ring. Milestone 49 made reads/writes BLOCKING:
--  an empty non-EOF read or a write that does not fit defers its
--  reply (kernel reply-cap duplication, milestone 47) until the
--  opposite side arrives; the request's reply cap and buffer cap
--  sit in the pending table below. The pending table is grow-on-
--  demand (M80d) — when even the arena is out the server falls
--  back to the old Status_Not_Ready poll answer, so clients keep
--  their retry loops as degradation, never as the hot path.
--
--  M80d: pipes and pendings are grow-on-demand chunk chains
--  (Akernel_User.Tables) — capacity is RAM, not Max_Pipes /
--  Max_Pending literals, and the 32 x 16 KiB rings moved out of
--  BSS into arena chunks.  (Milestone 69 headroom note: `run`
--  can background a pipeline, and a background job holds its
--  pipes until reaped — that silent-fill class is gone.)
--
--  EOF is EXPLICIT (Op_Close from the writer): the fs protocol
--  is stateless — no fids, no close-counting — so a pipe cannot
--  infer "all writers gone". The RTS redirect layer sends
--  Op_Close when a redirected program exits.
--
--  Library level: nothing here may sit on the server stack (the
--  fileserver_tables burn class).

package Fileserver_Pipes is
   subtype U64 is Akernel_User.Syscalls.U64;

   Pipe_Bytes    : constant := 16384;
   Max_Pipe_Name : constant := 40;

   --  Case-insensitive name lookup (fs convention); 0 = absent.
   function Find (Name : String) return Natural;

   --  Lookup, creating an empty pipe when absent; 0 = arena OOM
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

   --  Blocking pipes (milestone 49): deferred-request table. A
   --  stashed entry owns the request's reply cap and client
   --  buffer cap until the fileserver completes or fails it;
   --  completion scans the whole table (drain passes run until
   --  no progress — a completing read can unblock a write and
   --  vice versa).  Grow-on-demand (M80d); Stash fails only on
   --  arena OOM.
   type Pending_Kind is (P_None, P_Read, P_Write);

   --  Reserve a slot for pipe P; False = arena OOM (the caller
   --  answers Status_Not_Ready so the client polls).
   function Stash
     (P : Natural; Kind : Pending_Kind;
      Reply_H, Buf, Length : U64) return Boolean;

   --  Scan access for the drain (slots 1 .. Pend_Last).
   function Pend_Last return Natural;
   function Pend_Pipe (S : Natural) return Natural;
   function Pend_Kind (S : Natural) return Pending_Kind;
   function Pend_Reply (S : Natural) return U64;
   function Pend_Buf (S : Natural) return U64;
   function Pend_Length (S : Natural) return U64;

   --  Free a slot (after completion or failure).
   procedure Pend_Clear (S : Natural);

end Fileserver_Pipes;
