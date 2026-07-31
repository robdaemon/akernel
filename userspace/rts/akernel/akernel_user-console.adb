with Ada.Streams;

package body Akernel_User.Console is
   use type U64;

   Console_Endpoint : U64 := 0;

   --  Bound lazily on first use once the endpoint is set.
   Bound          : Boolean := False;
   Stream_Storage : aliased Akernel_User.Streams.Endpoint_Stream;

   procedure Bind is
   begin
      if not Bound and then Console_Endpoint /= 0 then
         Akernel_User.Streams.Set_Endpoint
           (Stream_Storage, Console_Endpoint);
         Bound := True;
      end if;
   end Bind;

   procedure Set_Endpoint (Endpoint : U64) is
   begin
      Console_Endpoint := Endpoint;
   end Set_Endpoint;

   function Endpoint return U64 is
   begin
      return Console_Endpoint;
   end Endpoint;

   function Stream return access Akernel_User.Streams.Endpoint_Stream is
   begin
      Bind;
      return Stream_Storage'Access;
   end Stream;

   procedure Put (S : String) is
   begin
      if Console_Endpoint = 0 then
         Akernel_User.Syscalls.Debug_Put (S);
         return;
      end if;

      Bind;
      declare
         Item : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (S'Length));
      begin
         for I in S'Range loop
            Item (Ada.Streams.Stream_Element_Offset (I - S'First + 1)) :=
              Ada.Streams.Stream_Element (Character'Pos (S (I)));
         end loop;
         Akernel_User.Streams.Write (Stream_Storage, Item);
      end;
   end Put;

   procedure Put_Line (S : String) is
   begin
      Put (S);
      Put ((1 => Character'Val (10)));
   end Put_Line;

end Akernel_User.Console;
