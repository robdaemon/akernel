with Ada.Streams;
with Aegir_User.Syscalls;
with Aegir_User.IPC;
with Aegir_User.Streams;

package body Scripting.Console_IO is
   use Aegir_User.Syscalls;
   use type U64;

   package RPC is new Aegir_User.IPC
     (Aegir_User.Streams.Stream_Request,
      Aegir_User.Streams.Stream_Response);

   procedure Read_Line (Buf : out String; Len : out Natural) is
      Status   : U64;
      Rlbl     : U64;
      Request  : Aegir_User.Streams.Stream_Request;
      Response : Aegir_User.Streams.Stream_Response;
      Done     : Boolean := False;
   begin
      Len := 0;
      while not Done loop
         Request.Count := Aegir_User.Streams.Max_Chunk;
         Request.Data := (others => 0);
         Status := RPC.Call
           (Console_EP, Aegir_User.Streams.Op_Read, Request,
            RPC.No_Caps, Rlbl, Response);
         if Status /= IPC_Ok then
            Done := True;  --  console gone: empty reply
         elsif Response.Count = 0 then
            Yield;
         else
            for I in 1 .. Ada.Streams.Stream_Element_Offset
              (Response.Count)
            loop
               declare
                  Code : constant Natural :=
                    Natural (Response.Data (I));
               begin
                  if Code = 10 or else Code = 13 then
                     Done := True;
                  elsif Code = 8 or else Code = 127 then
                     if Len > 0 then
                        Len := Len - 1;
                     end if;
                  elsif Code >= 32 and then Code < 127 then
                     if Len < Buf'Length then
                        Len := Len + 1;
                        Buf (Buf'First + Len - 1) :=
                          Character'Val (Code);
                     end if;
                  end if;
               end;
            end loop;
         end if;
      end loop;
   end Read_Line;

end Scripting.Console_IO;
