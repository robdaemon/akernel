with Ada.IO_Exceptions;
with Akernel_User.IPC;

package body Akernel_User.Streams is
   use Akernel_User.Syscalls;
   use type U64;

   package RPC is new Akernel_User.IPC (Stream_Request, Stream_Response);

   procedure Set_Endpoint
     (Stream   : in out Endpoint_Stream;
      Endpoint : U64)
   is
   begin
      Stream.Bound_Endpoint := Endpoint;
   end Set_Endpoint;

   function Endpoint (Stream : Endpoint_Stream) return U64 is
   begin
      return Stream.Bound_Endpoint;
   end Endpoint;

   procedure Read
     (Stream : in out Endpoint_Stream;
      Item   : out Stream_Element_Array;
      Last   : out Stream_Element_Offset)
   is
      First    : Stream_Element_Offset := Item'First;
      Status   : U64;
      R_Label  : U64;
      Request  : Stream_Request;
      Response : Stream_Response;
      Want     : Stream_Element_Offset;
   begin
      if Item'Length = 0 then
         Last := Item'First - 1;
         return;
      end if;

      if Stream.Bound_Endpoint = 0 then
         raise Ada.IO_Exceptions.Device_Error;
      end if;

      while First <= Item'Last loop
         Want := Stream_Element_Offset'Min
           (Item'Last - First + 1, Stream_Element_Offset (Max_Chunk));
         Request := (Count => U64 (Want), Data => (others => 0));

         Status := RPC.Call
           (Stream.Bound_Endpoint, Op_Read, Request,
            RPC.No_Caps, R_Label, Response);
         if Status /= IPC_Ok then
            raise Ada.IO_Exceptions.Device_Error;
         end if;

         if Response.Count = 0 then
            --  EOF: report what was gathered so far.
            Last := First - 1;
            return;
         end if;

         for I in 1 .. Stream_Element_Offset (Response.Count) loop
            Item (First + I - 1) := Response.Data (I);
         end loop;
         First := First + Stream_Element_Offset (Response.Count);
      end loop;

      Last := Item'Last;
   end Read;

   procedure Write
     (Stream : in out Endpoint_Stream;
      Item   : Stream_Element_Array)
   is
      First    : Stream_Element_Offset := Item'First;
      Status   : U64;
      R_Label  : U64;
      Request  : Stream_Request;
      Response : Stream_Response;
      Chunk    : Stream_Element_Offset;
   begin
      if Stream.Bound_Endpoint = 0 then
         raise Ada.IO_Exceptions.Device_Error;
      end if;

      while First <= Item'Last loop
         Chunk := Stream_Element_Offset'Min
           (Item'Last - First + 1, Stream_Element_Offset (Max_Chunk));

         Request.Count := U64 (Chunk);
         Request.Data := (others => 0);
         for I in 1 .. Chunk loop
            Request.Data (I) := Item (First + I - 1);
         end loop;

         Status := RPC.Call
           (Stream.Bound_Endpoint, Op_Write, Request,
            RPC.No_Caps, R_Label, Response);
         if Status /= IPC_Ok then
            raise Ada.IO_Exceptions.Device_Error;
         end if;

         First := First + Stream_Element_Offset (Response.Count);
         if Response.Count = 0 then
            --  Server consumed nothing: avoid a silent livelock.
            raise Ada.IO_Exceptions.Device_Error;
         end if;
      end loop;
   end Write;

   function Endcli (Endpoint : U64) return U64 is
      R_Label  : U64;
      Response : Stream_Response;
      Status   : U64;
   begin
      Status := RPC.Call
        (Endpoint, Op_Endcli, (Count => 0, Data => (others => 0)),
         RPC.No_Caps, R_Label, Response);
      if Status /= IPC_Ok then
         return 1;  --  channel dead/foreign: stay up
      end if;
      return Response.Count;
   end Endcli;

end Akernel_User.Streams;
