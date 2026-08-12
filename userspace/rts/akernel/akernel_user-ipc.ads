with Akernel_User.Syscalls;

--  Typed RPC wrappers over the raw call/recv/reply syscalls.
--  Generic over request/response payload records marshalled into the
--  message's six-word area (48 bytes); larger payloads must move
--  through memory caps (future). Payloads must be flat bit-copyable
--  records (no controlled or access components); a payload bigger
--  than 48 bytes makes every operation fail with IPC_Invalid.

generic
   type Request_Payload is private;
   type Response_Payload is private;
package Akernel_User.IPC is
   subtype U64 is Akernel_User.Syscalls.U64;
   subtype Cap_Array is Akernel_User.Syscalls.IPC_Cap_Array;

   No_Caps : constant Cap_Array := (others => 0);

   --  Client side: send Request (plus up to 4 caps) and block until
   --  the server replies. On success Response holds the reply words
   --  and Response_Label the reply label.
   function Call
     (Endpoint       : U64;
      Label          : U64;
      Request        : Request_Payload;
      Send_Caps      : Cap_Array := No_Caps;
      Response_Label : out U64;
      Response       : out Response_Payload) return U64;

   --  Server side: block until a caller arrives. Request holds the
   --  caller's words, Badge the endpoint badge, Caps the transferred
   --  caps (handles already rewritten into this table, 0 = none).
   --  Reply_Handle is the minted reply cap (milestone 47: an
   --  ordinary free-slot cap delivered in a1 — 0 for a plain send
   --  or the synthetic notification message). A server may hold
   --  many outstanding reply caps and reply in any order.
   function Receive
     (Endpoint     : U64;
      Label        : out U64;
      Request      : out Request_Payload;
      Badge        : out U64;
      Caps         : out Cap_Array;
      Reply_Handle : out U64) return U64;

   --  Server side: one-shot reply to a caller (Reply_Handle from
   --  its Receive, consumed by the reply).
   function Reply
     (Reply_Handle : U64;
      Label        : U64;
      Response     : Response_Payload) return U64;

end Akernel_User.IPC;
