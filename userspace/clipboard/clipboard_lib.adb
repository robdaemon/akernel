with Aegir_User;
with Aegir_User.Syscalls;
with Interfaces;
with System.Storage_Elements;

package body Clipboard_Lib is

   use type Aegir_User.Syscalls.U64;

   package Sys renames Aegir_User.Syscalls;
   use System.Storage_Elements;
   use type Sys.U64;

   subtype U8 is Interfaces.Unsigned_8;

   --  Server scratch window for mapping a client's buffer memobj.
   --  Static VA below the text base; the compile-time guard keeps
   --  it from ever sliding onto code/data (fileserver 37b lesson).
   Clip_Win_VA  : constant U64 := 16#4300_0000#;
   Clip_Pages   : constant U64 := U64 (Clip_Max / 4096);
   Windows_Fit  : constant :=
     1 / Boolean'Pos
       (Clip_Win_VA + Clip_Max <= 16#4600_0000#);

   --  The single clipboard buffer. One instance per session,
   --  serialized by the service loop, so no locking is needed.
   Store     : array (U64 range 0 .. Clip_Max - 1) of U8 :=
     (others => 0);
   Store_Len : U64 := 0;

   Result : U64;

   procedure Reply (Reply_Handle : U64; Label : U64;
                    W0, W1 : U64) is
   begin
      Sys.Message.Label := Label;
      Sys.Message.Words := (0 => W0, 1 => W1, others => 0);
      Sys.Message.Caps := (others => 0);
      Sys.Message.Badge := 0;
      Result := Sys.IPC_Reply (Reply_Handle);
   end Reply;

   procedure On_Open is
   begin
      null;
   end On_Open;

   procedure Dispatch
     (Label        : U64;
      Request      : Libserv.Words;
      Request_Caps : Libserv.Caps;
      Reply_Handle : U64;
      Shutdown     : out Boolean)
   is
      Win : array (U64 range 0 .. Clip_Max - 1) of U8
        with Address => System'To_Address
          (System.Storage_Elements.Integer_Address (Clip_Win_VA));
      St  : U64;
   begin
      Shutdown := False;
      if Request_Caps (0) = 0 then
         Reply (Reply_Handle, Label, Status_Bad, 0);
         return;
      end if;

      --  Map the client buffer into the scratch window (flags 3:
      --  read+write), do the copy, unmap, then drop the per-op
      --  transferred cap so no request leaks a cap-table slot.
      if Sys.Mem_Map
        (Address_Space => Sys.Address_Space_Cap,
         Cap           => Request_Caps (0),
         VA            => Clip_Win_VA,
         Offset        => 0,
         Length        => Clip_Max,
         Flags         => 3) /= 0
      then
         Result := Sys.Cap_Delete (Request_Caps (0));
         Reply (Reply_Handle, Label, Status_Bad, 0);
         return;
      end if;

      if Label = Label_Put then
         if Request (0) > Clip_Max then
            St := Status_Too_Big;
         else
            Store_Len := Request (0);
            for I in 0 .. Store_Len - 1 loop
               Store (I) := Win (I);
            end loop;
            St := Status_Ok;
         end if;
      elsif Label = Label_Get then
         declare
            Off : constant U64 := Request (0);
            N   : U64;
         begin
            if Off >= Store_Len then
               N := 0;
            else
               N := U64'Min (Store_Len - Off, Clip_Max);
               for I in 0 .. N - 1 loop
                  Win (I) := Store (Off + I);
               end loop;
            end if;
            St := Status_Ok;
            Reply (Reply_Handle, Label, St, N);
            Result := Sys.Mem_Unmap
              (Address_Space => Sys.Address_Space_Cap,
               VA            => Clip_Win_VA,
               Length        => Clip_Max);
            Result := Sys.Cap_Delete (Request_Caps (0));
            return;
         end;
      else
         St := Status_Bad;
      end if;

      Reply (Reply_Handle, Label, St, 0);
      Result := Sys.Mem_Unmap
        (Address_Space => Sys.Address_Space_Cap,
         VA            => Clip_Win_VA,
         Length        => Clip_Max);
      Result := Sys.Cap_Delete (Request_Caps (0));
   end Dispatch;

end Clipboard_Lib;
