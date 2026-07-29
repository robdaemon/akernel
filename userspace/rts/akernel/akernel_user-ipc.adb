with Interfaces;

package body Akernel_User.IPC is
   use Akernel_User.Syscalls;
   use type Interfaces.Unsigned_64;

   Max_Payload_Bits : constant := 6 * 64;

   --  Payload marshalling: overlay the record on a zeroed word
   --  buffer so a small payload leaves the remaining words zero.
   procedure Write_Request (Data : Request_Payload) is
      Words   : aliased IPC_Word_Array := (others => 0);
      Overlay : Request_Payload
        with Import, Address => Words'Address;
   begin
      Overlay := Data;
      Message.Words := Words;
   end Write_Request;

   procedure Write_Response (Data : Response_Payload) is
      Words   : aliased IPC_Word_Array := (others => 0);
      Overlay : Response_Payload
        with Import, Address => Words'Address;
   begin
      Overlay := Data;
      Message.Words := Words;
   end Write_Response;

   function Read_Request return Request_Payload is
      Words   : aliased constant IPC_Word_Array := Message.Words;
      Overlay : Request_Payload
        with Import, Address => Words'Address;
   begin
      return Overlay;
   end Read_Request;

   function Read_Response return Response_Payload is
      Words   : aliased constant IPC_Word_Array := Message.Words;
      Overlay : Response_Payload
        with Import, Address => Words'Address;
   begin
      return Overlay;
   end Read_Response;

   function Call
     (Endpoint       : U64;
      Label          : U64;
      Request        : Request_Payload;
      Send_Caps      : Cap_Array := No_Caps;
      Response_Label : out U64;
      Response       : out Response_Payload) return U64
   is
      Status : U64;
   begin
      Response_Label := 0;
      if Request_Payload'Size > Max_Payload_Bits
        or else Response_Payload'Size > Max_Payload_Bits
      then
         return IPC_Invalid;
      end if;

      Message.Label := Label;
      Write_Request (Request);
      Message.Caps := Send_Caps;

      Status := IPC_Call (Endpoint);
      if Status /= IPC_Ok then
         return Status;
      end if;

      Response_Label := Message.Label;
      Response := Read_Response;
      return IPC_Ok;
   end Call;

   function Receive
     (Endpoint : U64;
      Label    : out U64;
      Request  : out Request_Payload;
      Badge    : out U64;
      Caps     : out Cap_Array) return U64
   is
      Status : U64;
   begin
      Label := 0;
      Badge := 0;
      Caps := (others => 0);
      if Request_Payload'Size > Max_Payload_Bits then
         return IPC_Invalid;
      end if;

      Status := IPC_Recv (Endpoint);
      if Status /= IPC_Ok then
         return Status;
      end if;

      Label := Message.Label;
      Badge := Message.Badge;
      Caps := Message.Caps;
      Request := Read_Request;
      return IPC_Ok;
   end Receive;

   function Reply
     (Label    : U64;
      Response : Response_Payload) return U64
   is
   begin
      if Response_Payload'Size > Max_Payload_Bits then
         return IPC_Invalid;
      end if;

      Message.Label := Label;
      Write_Response (Response);
      Message.Caps := (others => 0);
      return IPC_Reply;
   end Reply;

end Akernel_User.IPC;
