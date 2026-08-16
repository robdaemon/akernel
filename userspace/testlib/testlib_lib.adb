with Akernel_User;
with Akernel_User.Syscalls;

package body Testlib_Lib is

   use Akernel_User;
   use Akernel_User.Syscalls;
   use type U64;

   Result : U64;

   function Words_To_String (W : Words) return String is
      S : String (1 .. 48);
   begin
      for I in 0 .. 5 loop
         for B in 0 .. 7 loop
            S (I * 8 + B + 1) :=
              Character'Val
                (Integer ((W (I) / U64 (2 ** (B * 8))) mod 256));
         end loop;
      end loop;
      return S;
   end Words_To_String;

   function String_To_Words (S : String) return Words is
      W : Words := (others => 0);
   begin
      for I in S'Range loop
         declare
            Word_Idx : constant Natural := (I - 1) / 8;
            Byte_Idx : constant Natural := (I - 1) mod 8;
         begin
            W (Word_Idx) := W (Word_Idx) or
              (U64 (Character'Pos (S (I))) * U64 (2 ** (Byte_Idx * 8)));
         end;
      end loop;
      return W;
   end String_To_Words;

   procedure On_Open is
   begin
      null;
   end On_Open;

   procedure Dispatch
     (Label        : U64;
      Request      : Words;
      Request_Caps : Caps;
      Reply_Handle : U64;
      Shutdown     : out Boolean)
   is
      pragma Unreferenced (Request_Caps);

      S   : constant String := Words_To_String (Request);
      Len : Natural := 0;
   begin
      Shutdown := False;

      if Label /= 1 then
         Message.Label := 0;
         Message.Words := (others => 0);
         Message.Caps := (others => 0);
         Result := IPC_Reply (Reply_Handle);
         return;
      end if;

      for I in 1 .. 48 loop
         if S (I) = ASCII.NUL then
            Len := I - 1;
            exit;
         end if;
      end loop;
      if Len = 0 then
         Len := 48;
      end if;

      declare
         T : String (1 .. Len) := S (1 .. Len);
      begin
         for I in 1 .. Len loop
            if T (I) in 'a' .. 'z' then
               T (I) := Character'Val (Character'Pos (T (I)) - 32);
            end if;
         end loop;

         Message.Label := 1;
         Message.Words := String_To_Words (T);
         Message.Caps := (others => 0);
         Result := IPC_Reply (Reply_Handle);
      end;
   end Dispatch;

end Testlib_Lib;
