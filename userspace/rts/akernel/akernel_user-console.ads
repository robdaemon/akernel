with Akernel_User.Syscalls;
with Akernel_User.Streams;

--  Console output: Put/Put_Line over an Endpoint_Stream bound to the
--  console server endpoint. Normal programs get a Send cap on that
--  endpoint via the "console" manifest grant token and print through
--  here instead of the debug_putchar syscall. With no endpoint set
--  (cap not granted) output falls back to debug_putchar so early
--  bootstrap code (init) and error paths still have a channel.

package Akernel_User.Console is
   subtype U64 is Akernel_User.Syscalls.U64;

   procedure Set_Endpoint (Endpoint : U64);
   function Endpoint return U64;

   procedure Put (S : String);
   procedure Put_Line (S : String);

   --  The bound stream, for clients that want stream semantics.
   function Stream return access Akernel_User.Streams.Endpoint_Stream;
end Akernel_User.Console;
