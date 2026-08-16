with Interfaces;
with Akernel_User.Syscalls;
with Akernel_User.CLI;
with Akernel_User.Console;
with Akernel_User.Libs;

use Akernel_User.Syscalls;
use Akernel_User;

--  Testlib_Client: client for the milestone 58 Tier-1 shared-library
--  demo. Uses Akernel_User.Libs.Open_Library/Close_Library, sends the
--  Uppercase request, and prints the reply.

procedure Testlib_Client is

   use type U64;

   Service : U64;
   Status  : U64;
   S       : String := CLI.Argument (1);

   type Byte_Array is array (U64 range <>) of Interfaces.Unsigned_8;

   function Words_To_String (W : IPC_Word_Array) return String is
      Str : String (1 .. 48);
   begin
      for I in 0 .. 5 loop
         for B in 0 .. 7 loop
            Str (I * 8 + B + 1) :=
              Character'Val
                (Integer ((W (I) / U64 (2 ** (B * 8))) mod 256));
         end loop;
      end loop;
      return Str;
   end Words_To_String;

   procedure String_To_Words (Str : String; W : out IPC_Word_Array) is
   begin
      W := (others => 0);
      for I in Str'Range loop
         declare
            Word_Idx : constant Natural := (I - 1) / 8;
            Byte_Idx : constant Natural := (I - 1) mod 8;
         begin
            W (Word_Idx) := W (Word_Idx) or
              (U64 (Character'Pos (Str (I))) *
               U64 (2 ** (Byte_Idx * 8)));
         end;
      end loop;
   end String_To_Words;

begin
   if CLI.Arg_Count < 1 then
      Console.Put_Line ("usage: Testlib_Client <string>");
      CLI.Exit_With (CLI.RC_Error);
   end if;

   Service := Libs.Open_Library ("Sys:Libs/Testlib");
   if Service = Libs.Invalid_Handle then
      Console.Put_Line ("cannot open Sys:Libs/Testlib");
      CLI.Exit_With (CLI.RC_Error);
   end if;

   --  Send the Uppercase request (label 1).
   declare
      Req_Words : IPC_Word_Array;
   begin
      String_To_Words (S, Req_Words);
      Message.Label := 1;
      Message.Words := Req_Words;
      Message.Caps := (others => 0);
      Message.Badge := 0;
   end;

   Status := IPC_Call (Service);
   if Status /= IPC_Ok then
      Libs.Close_Library (Service);
      Console.Put_Line ("uppercase call failed");
      CLI.Exit_With (CLI.RC_Error);
   end if;

   declare
      Resp_Words : IPC_Word_Array := Message.Words;
   begin
      Console.Put_Line (Words_To_String (Resp_Words));
   end;

   Libs.Close_Library (Service);
   CLI.Exit_With (CLI.RC_Ok);
end Testlib_Client;
