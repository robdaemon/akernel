with Ada.Streams;
with Akernel_User.Syscalls;

--  Streams over endpoint caps: the fundamental user-mode I/O
--  substrate. An Endpoint_Stream marshals Read/Write primitives into
--  blocking RPC calls on an endpoint cap held by the client; a server
--  (e.g. the console server in Drivers/Serial) holds the matching
--  Receive cap and performs the actual device I/O. The wire protocol
--  below is pure userspace convention: the kernel never parses it.
--
--  Wire protocol (message label = opcode):
--    Op_Write: request carries Count + up to Max_Chunk data bytes;
--              reply carries the number of bytes consumed.
--    Op_Read:  request carries the wanted byte count; reply carries
--              Count bytes in Data (Count = 0 means EOF/no data).
--    Op_Input: device -> server direction: the request carries
--              Count input bytes a source driver (virtio-input
--              keyboard, later others) injects into the server's
--              input FIFO; a client Op_Read drains that FIFO. The
--              reply carries the number of bytes accepted.
--    Op_Attach_Sink: cap slot 0 carries an endpoint Send cap the
--              console server mirrors its line-atomic output to
--              (e.g. the virtio-gpu text console). Only the
--              init/devmgr badge (0) may attach; reply Count is a
--              status (0 = attached, 1 = rejected). A sink whose
--              writes fail is dropped.
--  Caps slots are otherwise unused; badges are not interpreted
--  except by Op_Attach_Sink.

package Akernel_User.Streams is
   use Ada.Streams;
   subtype U64 is Akernel_User.Syscalls.U64;

   Op_Write       : constant U64 := 1;
   Op_Read        : constant U64 := 2;
   Op_Input       : constant U64 := 3;
   Op_Attach_Sink : constant U64 := 4;
   Max_Chunk : constant := 40;  --  6 message words - Count word

   type Stream_Request is record
      Count : U64;
      Data  : Stream_Element_Array (1 .. Max_Chunk);
   end record;

   type Stream_Response is record
      Count : U64;
      Data  : Stream_Element_Array (1 .. Max_Chunk);
   end record;

   --  Client-side stream. Set_Endpoint binds it to an endpoint cap
   --  handle (0 = unbound: every operation raises Device_Error).
   --  Write blocks per chunk until the server replies; a failed
   --  call (endpoint gone, transfer failure) raises
   --  Ada.IO_Exceptions.Device_Error. Read fills Item unless the
   --  server reports EOF, in which case Last is Item'First - 1.
   type Endpoint_Stream is new Root_Stream_Type with private;

   procedure Set_Endpoint
     (Stream   : in out Endpoint_Stream;
      Endpoint : U64);

   function Endpoint (Stream : Endpoint_Stream) return U64;

   overriding procedure Read
     (Stream : in out Endpoint_Stream;
      Item   : out Stream_Element_Array;
      Last   : out Stream_Element_Offset);

   overriding procedure Write
     (Stream : in out Endpoint_Stream;
      Item   : Stream_Element_Array);

private
   type Endpoint_Stream is new Root_Stream_Type with record
      Bound_Endpoint : U64 := 0;
   end record;
end Akernel_User.Streams;
