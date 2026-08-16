with Akernel_User; use Akernel_User;
with Akernel_User.Syscalls;

--  Libserv (milestone 58 Tier-1): shared-library server boilerplate.
--  A library server links this crate and calls Libserv.Run. Libserv
--  reads the rendezvous cap from handle 5, creates a service endpoint,
--  sends it back to the client, then runs the service loop. The library
--  author supplies the request dispatch callback.

package Libserv is
   use type Syscalls.U64;

   subtype U64 is Syscalls.U64;
   subtype Words is Syscalls.IPC_Word_Array;
   subtype Caps is Syscalls.IPC_Cap_Array;

   Invalid_Handle : constant U64 := 0;

   --  Dispatch callback: handle one request arriving on the library's
   --  service endpoint. Request words and transferred caps are in the
   --  arrays; Reply_Handle is the one-shot reply cap from Receive.
   --  Set Shutdown to True to make Run return cleanly.
   type Dispatch_Procedure is access procedure
     (Label        : U64;
      Request      : Words;
      Request_Caps : Caps;
      Reply_Handle : U64;
      Shutdown     : out Boolean);

   --  Run the library server lifecycle:
   --  1. Read the rendezvous cap from handle 5.
   --  2. Create the service endpoint and send it back to the client.
   --  3. Call On_Open (if non-null).
   --  4. Receive requests and dispatch them until the service endpoint
   --      is closed (Status = IPC_Endpoint_Gone) or Dispatch sets Shutdown.
   procedure Run
     (On_Open  : access procedure;
      Dispatch : Dispatch_Procedure);

end Libserv;
