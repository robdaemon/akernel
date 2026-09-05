package body Akernel_User.Display is
   use Akernel_User.Syscalls;
   use type U64;

   --  Raw IPC_Call pattern (the RPC generic marshals stream
   --  payloads; display messages are plain words + caps).

   function Get_Info
     (EP                    : U64;
      Width, Height, Stride : out U64;
      Total_Pages           : out U64) return U64
   is
      Status : U64;
   begin
      Message.Label := Op_Get_Info;
      Message.Words := (others => 0);
      Message.Caps  := (others => 0);
      Status := IPC_Call (EP);
      if Status /= IPC_Ok
        or else Message.Words (0) /= Status_Ok
      then
         return Status_Device;
      end if;
      Width       := Message.Words (1);
      Height      := Message.Words (2);
      Stride      := Message.Words (3);
      Total_Pages := Message.Words (4);
      return Status_Ok;
   end Get_Info;

   function Set_Buffer
     (EP   : U64;
      Base : U64;
      C0   : U64;
      C1   : U64 := 0;
      C2   : U64 := 0;
      C3   : U64 := 0) return U64
   is
      Status : U64;
   begin
      Message.Label := Op_Set_Buffer;
      Message.Words := (others => 0);
      Message.Words (0) := Base;
      Message.Caps := (C0, C1, C2, C3);
      Status := IPC_Call (EP);
      if Status /= IPC_Ok then
         return Status_Device;
      end if;
      return Message.Words (0);
   end Set_Buffer;

   function Commit_Buffer (EP : U64) return U64 is
      Status : U64;
   begin
      Message.Label := Op_Commit_Buffer;
      Message.Words := (others => 0);
      Message.Caps  := (others => 0);
      Status := IPC_Call (EP);
      if Status /= IPC_Ok then
         return Status_Device;
      end if;
      return Message.Words (0);
   end Commit_Buffer;

   function Present
     (EP      : U64;
      X, Y, W : U64;
      H       : U64) return U64
   is
      Status : U64;
   begin
      Message.Label := Op_Present;
      Message.Words := (others => 0);
      Message.Words (0) := X;
      Message.Words (1) := Y;
      Message.Words (2) := W;
      Message.Words (3) := H;
      Message.Caps := (others => 0);
      Status := IPC_Call (EP);
      if Status /= IPC_Ok then
         return Status_Device;
      end if;
      return Message.Words (0);
   end Present;

   function Set_Mode
     (EP                    : U64;
      Req_W, Req_H          : U64;
      Width, Height, Stride : out U64;
      Total_Pages           : out U64) return U64
   is
      Status : U64;
   begin
      Message.Label := Op_Set_Mode;
      Message.Words := (others => 0);
      Message.Words (0) := Req_W;
      Message.Words (1) := Req_H;
      Message.Caps  := (others => 0);
      Status := IPC_Call (EP);
      Width       := Message.Words (1);
      Height      := Message.Words (2);
      Stride      := Message.Words (3);
      Total_Pages := Message.Words (4);
      if Status /= IPC_Ok then
         return Status_Device;
      end if;
      return Message.Words (0);
   end Set_Mode;

end Akernel_User.Display;
