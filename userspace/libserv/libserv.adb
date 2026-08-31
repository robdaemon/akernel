with Akernel_User; use Akernel_User;
with Akernel_User.Syscalls;

package body Libserv is

   Rendezvous_Handle : constant U64 := 5;

   procedure Run
     (On_Open  : access procedure;
      Dispatch : Dispatch_Procedure;
      Version  : U64 := 0;
      Revision : U64 := 0)
   is
      use Syscalls;

      Rendezvous : constant U64 := Rendezvous_Handle;
      Service_EP : U64;
      Status     : U64;
      Reply_H    : U64;
      Shutdown   : Boolean := False;
      Result     : U64;
   begin
      Service_EP := EP_Create;
      if Service_EP = Syscall_Failed then
         return;
      end if;

      --  Send the service endpoint cap back to the client through the
      --  rendezvous endpoint. The client waits on handle 5 with Receive.
      --  Words 0/1 advertise the library version/revision for the
      --  manager's OpenLibrary version floor.
      Message.Label := 0;
      Message.Words := (0 => Version, 1 => Revision, others => 0);
      Message.Caps := (0 => Service_EP, others => 0);
      Message.Badge := 0;

      Status := IPC_Send (Rendezvous);
      if Status /= IPC_Ok then
         Result := Cap_Delete (Service_EP);
         return;
      end if;

      if On_Open /= null then
         On_Open.all;
      end if;

      --  Service loop: receive requests on the service endpoint and
      --  dispatch them. The endpoint going away (last client closed)
      --  wakes us with IPC_Endpoint_Gone so we exit cleanly.
      loop
         Status := IPC_Recv (Service_EP, Reply_H);

         if Status = IPC_Endpoint_Gone then
            exit;
         elsif Status /= IPC_Ok then
            exit;
         end if;

         --  Management op (m75): the manager's expunge asks us to
         --  shut down. Reply, then leave the loop.
         if Message.Label = Shutdown_Label then
            Message.Label := 0;
            Message.Words := (others => 0);
            Message.Caps := (others => 0);
            Message.Badge := 0;
            Status := IPC_Reply (Reply_H);
            exit;
         end if;

         declare
            Req_Words : Words := Message.Words;
            Req_Caps  : Caps := Message.Caps;
         begin
            Dispatch (Message.Label, Req_Words, Req_Caps, Reply_H, Shutdown);
         end;

         exit when Shutdown;
      end loop;

      Result := Cap_Delete (Service_EP);
   end Run;

end Libserv;
