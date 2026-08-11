with Ada.Streams;
with Akernel_User.Files;

package body Akernel_User.Console is
   use type U64;

   Console_Endpoint : U64 := 0;

   --  Bound lazily on first use once the endpoint is set.
   Bound          : Boolean := False;
   Stream_Storage : aliased Akernel_User.Streams.Endpoint_Stream;

   --  Redirection state (library level: the buffer must not
   --  ride the 32 KiB process stack).
   Redir_On   : Boolean := False;
   Redir_Pipe : Boolean := False;
   Redir_Path : String (1 .. 48) := (others => Character'Val (0));
   Redir_PLen : Natural := 0;
   Redir_Off  : U64 := 0;  --  append offset (regular files)
   Redir_Buf  : String (1 .. 4096) := (others => Character'Val (0));
   Redir_Len  : Natural := 0;

   procedure Set_Redirect_Out (Path : String) is
   begin
      if Path'Length = 0 or else Path'Length > Redir_Path'Length then
         return;
      end if;
      Redir_Path := (others => Character'Val (0));
      Redir_Path (1 .. Path'Length) := Path;
      Redir_PLen := Path'Length;
      Redir_Off := 0;
      Redir_Len := 0;
      --  PIPE: volumes are case-insensitive prefixes.
      Redir_Pipe := Path'Length >= 5
        and then (Path (Path'First .. Path'First + 4) = "PIPE:"
                  or else Path (Path'First .. Path'First + 4) =
                            "pipe:");
      Redir_On := True;
   end Set_Redirect_Out;

   function Redirected return Boolean is
     (Redir_On);

   procedure Flush is
      Count  : U64;
      Status : U64;
   begin
      if not Redir_On or else Redir_Len = 0 then
         return;
      end if;
      --  Poll-and-retry on a full pipe (m46a semantics): the
      --  consumer drains between yields. Bounded so a dead
      --  consumer drops the chunk instead of hanging the
      --  writer forever.
      for Try in 1 .. 100_000 loop
         Status := Akernel_User.Files.Write
           (Redir_Path (1 .. Redir_PLen), Redir_Off,
            Redir_Buf'Address, U64 (Redir_Len), Count);
         exit when Status /= Akernel_User.Files.Status_Not_Ready;
         Akernel_User.Syscalls.Yield;
      end loop;
      if Status = Akernel_User.Files.Status_Ok then
         Redir_Off := Redir_Off + Count;
      end if;
      Redir_Len := 0;
   end Flush;

   procedure Close_Redirect is
   begin
      if not Redir_On then
         return;
      end if;
      Flush;
      if Redir_Pipe then
         declare
            Ignore : constant U64 := Akernel_User.Files.Close
              (Redir_Path (1 .. Redir_PLen));
         begin
            null;
         end;
      end if;
      Redir_On := False;
   end Close_Redirect;

   procedure Put_Redirected (S : String) is
   begin
      for C of S loop
         if Redir_Len = Redir_Buf'Length then
            Flush;
         end if;
         Redir_Len := Redir_Len + 1;
         Redir_Buf (Redir_Len) := C;
         if C = Character'Val (10) then
            Flush;  --  line granularity keeps pipes timely
         end if;
      end loop;
   end Put_Redirected;

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
      if Redir_On then
         Put_Redirected (S);
         return;
      end if;
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
