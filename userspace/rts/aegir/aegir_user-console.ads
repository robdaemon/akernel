with Aegir_User.Syscalls;
with Aegir_User.Streams;

--  Console output: Put/Put_Line over an Endpoint_Stream bound to the
--  console server endpoint. Normal programs get a Send cap on that
--  endpoint via the "console" manifest grant token and print through
--  here instead of the debug_putchar syscall. With no endpoint set
--  (cap not granted) output falls back to debug_putchar so early
--  bootstrap code (init) and error paths still have a channel.

package Aegir_User.Console is
   subtype U64 is Aegir_User.Syscalls.U64;

   procedure Set_Endpoint (Endpoint : U64);
   function Endpoint return U64;

   procedure Put (S : String);
   procedure Put_Line (S : String);

   --  Output redirection (milestone 46b): CLI activates this
   --  from the args-page trailer. While redirected, Put
   --  appends to a 4 KiB buffer flushed to the fs path on
   --  every newline (and on Flush); a PIPE: path ignores
   --  offsets (FIFO), a regular file writes at a running
   --  append offset. Poll semantics: Status_Not_Ready (full
   --  pipe) retries with yields — bounded, then the chunk is
   --  dropped so a dead consumer cannot hang the writer.
   procedure Set_Redirect_Out (Path : String);
   function Redirected return Boolean;
   procedure Flush;

   --  Flush + signal writer EOF when the target is a pipe +
   --  detach. CLI.Exit_With calls this so a piped consumer
   --  sees EOF exactly when the producer exits.
   procedure Close_Redirect;

   --  The bound stream, for clients that want stream semantics.
   function Stream return access Aegir_User.Streams.Endpoint_Stream;
end Aegir_User.Console;
