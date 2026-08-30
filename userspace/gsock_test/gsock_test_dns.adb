with Ada.Streams;
with GNAT.Sockets;

package body Gsock_Test_Dns is

   package AS renames Ada.Streams;
   package GS renames GNAT.Sockets;

   use type U32;
   use type AS.Stream_Element_Offset;

   task body Responder is
      S     : GS.Socket_Type;
      Q     : AS.Stream_Element_Array (1 .. 512);
      Last  : AS.Stream_Element_Offset;
      Sent  : AS.Stream_Element_Offset;
      From  : GS.Sock_Addr_Type;
      To    : aliased GS.Sock_Addr_Type;
   begin
      while not Go loop
         delay 0.001;
      end loop;

      GS.Create_Socket (S, GS.Family_Inet, GS.Socket_Datagram);
      GS.Bind_Socket
        (S, (GS.Family_Inet,
             GS.Inet_Addr (Own_IP (1 .. Own_Len)), 53));
      Bound := True;

      GS.Receive_Socket (S, Q, Last, From);

      --  Turn the query into a response: QR|AA, RCODE 0, one
      --  answer.  The question section stays untouched; the
      --  answer is appended with a compression pointer to the
      --  question name at offset 12.
      Q (3) := 16#81#;
      Q (4) := 16#80#;
      Q (7) := 0;
      Q (8) := 1;
      Q (Last +  1) := 16#C0#;
      Q (Last +  2) := 16#0C#;
      Q (Last +  3) := 0;
      Q (Last +  4) := 1;                      --  TYPE A
      Q (Last +  5) := 0;
      Q (Last +  6) := 1;                      --  CLASS IN
      Q (Last +  7) := 0;
      Q (Last +  8) := 0;
      Q (Last +  9) := 0;
      Q (Last + 10) := 60;                     --  TTL
      Q (Last + 11) := 0;
      Q (Last + 12) := 4;                      --  RDLENGTH
      Q (Last + 13) :=
        AS.Stream_Element
          (Interfaces.Shift_Right (Reply_Word, 24) and 16#FF#);
      Q (Last + 14) :=
        AS.Stream_Element
          (Interfaces.Shift_Right (Reply_Word, 16) and 16#FF#);
      Q (Last + 15) :=
        AS.Stream_Element
          (Interfaces.Shift_Right (Reply_Word, 8) and 16#FF#);
      Q (Last + 16) := AS.Stream_Element (Reply_Word and 16#FF#);

      To := From;
      GS.Send_Socket (S, Q (1 .. Last + 16), Sent, To'Access);
      GS.Close_Socket (S);
      Done := True;
   end Responder;

end Gsock_Test_Dns;
