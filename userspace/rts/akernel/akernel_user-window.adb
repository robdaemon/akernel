package body Akernel_User.Window is
   use Akernel_User.Syscalls;
   use type U64;

   function Call (EP : U64) return U64 is
      St : constant U64 := IPC_Call (EP);
   begin
      if St /= IPC_Ok then
         return Status_Device;
      end if;
      return Message.Words (0);
   end Call;

   function Surface_Create
     (EP             : U64;
      Width, Height  : U64;
      Id, Pages      : out U64;
      Grant_W        : out U64;
      Grant_H        : out U64) return U64
   is
   begin
      Message.Label := Op_Surface_Create;
      Message.Words := (others => 0);
      Message.Words (0) := Width;
      Message.Words (1) := Height;
      Message.Caps  := (others => 0);
      if IPC_Call (EP) /= IPC_Ok then
         return Status_Device;
      end if;
      Id      := Message.Words (1);
      Pages   := Message.Words (2);
      Grant_W := Message.Words (3);
      Grant_H := Message.Words (4);
      return Message.Words (0);
   end Surface_Create;

   function Surface_Set_Buffer
     (EP   : U64;
      Id   : U64;
      Base : U64;
      C0   : U64;
      C1   : U64 := 0;
      C2   : U64 := 0;
      C3   : U64 := 0) return U64
   is
   begin
      Message.Label := Op_Surface_Set_Buffer;
      Message.Words := (others => 0);
      Message.Words (0) := Id;
      Message.Words (1) := Base;
      Message.Caps := (C0, C1, C2, C3);
      return Call (EP);
   end Surface_Set_Buffer;

   function Surface_Commit_Buffer (EP : U64; Id : U64) return U64 is
   begin
      Message.Label := Op_Surface_Commit_Buffer;
      Message.Words := (others => 0);
      Message.Words (0) := Id;
      Message.Caps  := (others => 0);
      return Call (EP);
   end Surface_Commit_Buffer;

   function Surface_Update
     (EP      : U64;
      Id      : U64;
      X, Y, W : U64;
      H       : U64) return U64
   is
   begin
      Message.Label := Op_Surface_Update;
      Message.Words := (others => 0);
      Message.Words (0) := Id;
      Message.Words (1) := X;
      Message.Words (2) := Y;
      Message.Words (3) := W;
      Message.Words (4) := H;
      Message.Caps := (others => 0);
      return Call (EP);
   end Surface_Update;

end Akernel_User.Window;
