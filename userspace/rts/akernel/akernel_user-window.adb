with Interfaces;
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
       Queue_Cap      : U64 := 0;
       Ntfn_Cap       : U64 := 0;
       Id, Pages      : out U64;
       Grant_W        : out U64;
       Grant_H        : out U64;
       Flags          : U64 := 0) return U64
    is
    begin
       Message.Label := Op_Surface_Create;
       Message.Words := (others => 0);
       Message.Words (0) := Width;
       Message.Words (1) := Height;
       Message.Words (2) := Flags;
       Message.Caps  := (others => 0);
       Message.Caps (0) := Queue_Cap;
       Message.Caps (1) := Ntfn_Cap;
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

    function Surface_Resize
      (EP             : U64;
       Id             : U64;
       Width, Height  : U64;
       Pages          : out U64;
       Grant_W        : out U64;
       Grant_H        : out U64) return U64
    is
    begin
       Message.Label := Op_Surface_Resize;
       Message.Words := (others => 0);
       Message.Words (0) := Id;
       Message.Words (1) := Width;
       Message.Words (2) := Height;
       Message.Caps  := (others => 0);
       if IPC_Call (EP) /= IPC_Ok then
          return Status_Device;
       end if;
       Pages   := Message.Words (1);
       Grant_W := Message.Words (2);
       Grant_H := Message.Words (3);
       return Message.Words (0);
    end Surface_Resize;

   function Surface_Set_Title
     (EP : U64; Id : U64; S : String) return U64
   is
   begin
      Message.Label := Op_Set_Title;
      Message.Words := (others => 0);
      Message.Words (0) := Id;
      --  Pack up to 40 chars, little-endian byte order, into
      --  words 1..5.
      for I in S'Range loop
         exit when I - S'First >= 40;
         declare
            K : constant Natural := I - S'First;
            W : constant Natural := 1 + K / 8;
            B : constant Natural := K mod 8;
            use type Interfaces.Unsigned_64;
         begin
            Message.Words (W) := Message.Words (W)
              or Interfaces.Shift_Left
                (U64 (Character'Pos (S (I))), B * 8);
         end;
      end loop;
      Message.Caps := (others => 0);
      return Call (EP);
   end Surface_Set_Title;

   function Surface_Set_Menus
     (EP : U64; Id : U64; Page_Cap : U64) return U64 is
   begin
      Message.Label := Op_Set_Menus;
      Message.Words := (others => 0);
      Message.Words (0) := Id;
      Message.Caps := (others => 0);
      Message.Caps (0) := Page_Cap;
      return Call (EP);
   end Surface_Set_Menus;

   function Surface_Destroy (EP : U64; Id : U64) return U64 is
   begin
      Message.Label := Op_Surface_Destroy;
      Message.Words := (others => 0);
      Message.Words (0) := Id;
      Message.Caps := (others => 0);
      return Call (EP);
   end Surface_Destroy;

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

   function Set_Screen_Mode
     (EP            : U64;
      Width, Height : U64;
      Cur_W, Cur_H  : out U64) return U64
   is
      St : U64;
   begin
      Message.Label := Op_Set_Screen_Mode;
      Message.Words := (others => 0);
      Message.Words (0) := Width;
      Message.Words (1) := Height;
      Message.Caps := (others => 0);
      St := Call (EP);
      Cur_W := Message.Words (1);
      Cur_H := Message.Words (2);
      return St;
   end Set_Screen_Mode;

end Akernel_User.Window;
