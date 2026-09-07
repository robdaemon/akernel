with System.Storage_Elements;
with Interfaces;
with Aegir_User.Libs;

package body Aegir_User.Clipboard is

   use System.Storage_Elements;

   Library_Name : constant String := "Sys:Libs/Clipboard";

   Buf_Cap   : U64 := 0;
   Buf_Bytes : constant U64 := Buffer_Pages * Syscalls.Page_Size;

   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (U64 range <>) of Byte;

   --  Request labels (match userspace/clipboard/clipboard_lib.ads).
   Label_Put : constant U64 := 1;
   Label_Get : constant U64 := 2;

   function Ensure_Buffer return Boolean is
   begin
      if Buf_Cap /= 0 then
         return True;
      end if;
      Buf_Cap := Syscalls.Mem_Alloc (Buffer_Pages);
      if Buf_Cap = Syscalls.Syscall_Failed
        or else Syscalls.Mem_Map
          (Address_Space => Syscalls.Address_Space_Cap,
           Cap           => Buf_Cap,
           VA            => Buffer_VA,
           Offset        => 0,
           Length        => Buf_Bytes,
           Flags         => 3) /= 0
      then
         Buf_Cap := 0;
         return False;
      end if;
      return True;
   end Ensure_Buffer;

   function Open return U64 is
   begin
      return Aegir_User.Libs.Open_Library
        (Library_Name, Min_Version => 1);
   end Open;

   procedure Close (Service : U64) is
   begin
      if Service /= 0 then
         Aegir_User.Libs.Close_Library (Service);
      end if;
   end Close;

   function Put (Service : U64; Text : String) return U64 is
      Src : Byte_Array (0 .. Buf_Bytes - 1)
        with Address => To_Address (Integer_Address (Buffer_VA));
   begin
      if Service = 0
        or else Text'Length > Clipboard_Max
        or else not Ensure_Buffer
      then
         return (if Text'Length > Clipboard_Max
                 then Status_Too_Big else Status_Bad);
      end if;

      for I in 0 .. Text'Length - 1 loop
         Src (U64 (I)) := Byte (Character'Pos (Text (Text'First + I)));
      end loop;

      Syscalls.Message.Label := Label_Put;
      Syscalls.Message.Words := (0 => U64 (Text'Length), others => 0);
      Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);
      Syscalls.Message.Badge := 0;
      if Syscalls.IPC_Call (Service) /= Syscalls.IPC_Ok then
         return Status_Bad;
      end if;
      return Syscalls.Message.Words (0);
   end Put;

   function Read
     (Service : U64;
      Offset  : U64;
      Dest    : System.Address;
      Length  : U64;
      Count   : out U64) return U64
   is
      Status : U64;
      Src    : Byte_Array (0 .. Buf_Bytes - 1)
        with Address => To_Address (Integer_Address (Buffer_VA));
      Dst    : Byte_Array (0 .. Length - 1)
        with Address => Dest;
   begin
      Count := 0;
      if Service = 0
        or else Length = 0
        or else not Ensure_Buffer
      then
         return Status_Bad;
      end if;

      Syscalls.Message.Label := Label_Get;
      Syscalls.Message.Words := (0 => Offset, others => 0);
      Syscalls.Message.Caps := (0 => Buf_Cap, others => 0);
      Syscalls.Message.Badge := 0;
      if Syscalls.IPC_Call (Service) /= Syscalls.IPC_Ok then
         return Status_Bad;
      end if;

      Status := Syscalls.Message.Words (0);
      if Status /= Status_Ok then
         return Status;
      end if;

      Count := Syscalls.Message.Words (1);
      if Count > 0 then
         for I in 0 .. Count - 1 loop
            Dst (I) := Src (I);
         end loop;
      end if;
      return Status_Ok;
   end Read;

   function Get
     (Service : U64;
      Text    : out String;
      Len     : out Natural) return U64
   is
      Off   : U64 := 0;
      Got   : U64;
      St    : U64;
      Total : Natural := 0;
   begin
      Len := 0;
      if Service = 0 then
         return Status_Bad;
      end if;
      loop
         exit when Total >= Text'Length;
         declare
            Want : constant U64 :=
              U64'Min (U64 (Text'Length - Total), Buf_Bytes);
            Chunk : String (1 .. Natural (Want));
         begin
            St := Read (Service, Off, Chunk'Address, Want, Got);
            if St /= Status_Ok or else Got = 0 then
               return St;
            end if;
            Text (Text'First + Total
                  .. Text'First + Total + Natural (Got) - 1) :=
              Chunk (1 .. Natural (Got));
            Total := Total + Natural (Got);
            Off := Off + Got;
            exit when Got < Want;   --  end of buffer
         end;
      end loop;
      Len := Total;
      return Status_Ok;
   end Get;

end Aegir_User.Clipboard;
