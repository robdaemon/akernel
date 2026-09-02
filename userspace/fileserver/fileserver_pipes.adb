with Akernel_User.Tables;

package body Fileserver_Pipes is
   use Interfaces;
   use type U64;

   type Ring_Array is array (U64 range 0 .. Pipe_Bytes - 1)
     of Unsigned_8;

   type Pipe_Entry is record
      Valid  : Boolean := False;
      Name   : String (1 .. Max_Pipe_Name) :=
        (others => Character'Val (0));
      N_Len  : Natural := 0;
      Ring   : Ring_Array := (others => 0);
      Head   : U64 := 0;  --  next pop
      Count  : U64 := 0;
      Eof    : Boolean := False;
   end record;

   --  M80d: grow-on-demand chunk chains (Akernel_User.Tables);
   --  the 16 KiB rings moved out of BSS (32 x 16 KiB) into arena
   --  chunks.  Pipes (I) reads unchanged via the renames below;
   --  scans run 1 .. Pipe_Tab.Last and creation appends.
   package Pipe_Tab is new Akernel_User.Tables (Pipe_Entry);

   function Pipes (I : Natural) return Pipe_Tab.Element_Access
     renames Pipe_Tab.Ref;

   function Match (Name : String; I : Natural) return Boolean is
   begin
      if Name'Length /= Pipes (I).N_Len then
         return False;
      end if;
      for K in Name'Range loop
         declare
            A : constant Character := Name (K);
            B : constant Character :=
              Pipes (I).Name (K - Name'First + 1);
            LA : constant Character :=
              (if A in 'A' .. 'Z'
               then Character'Val (Character'Pos (A) + 32) else A);
            LB : constant Character :=
              (if B in 'A' .. 'Z'
               then Character'Val (Character'Pos (B) + 32) else B);
         begin
            if LA /= LB then
               return False;
            end if;
         end;
      end loop;
      return True;
   end Match;

   function Find (Name : String) return Natural is
   begin
      for I in 1 .. Pipe_Tab.Last loop
         if Pipes (I).Valid and then Match (Name, I) then
            return I;
         end if;
      end loop;
      return 0;
   end Find;

   function Find_Or_Create (Name : String) return Natural is
      P : constant Natural := Find (Name);
      I : Natural;
   begin
      if P /= 0 then
         return P;
      end if;
      if Name'Length = 0 or else Name'Length > Max_Pipe_Name then
         return 0;
      end if;
      I := 0;
      for K in 1 .. Pipe_Tab.Last loop
         if not Pipes (K).Valid then
            I := K;
            exit;
         end if;
      end loop;
      if I = 0 then
         I := Pipe_Tab.Append;  --  grow: 0 only on arena OOM
      end if;
      if I = 0 then
         return 0;
      end if;
      Pipes (I).Valid := True;
      Pipes (I).Name := (others => Character'Val (0));
      Pipes (I).Name (1 .. Name'Length) := Name;
      Pipes (I).N_Len := Name'Length;
      Pipes (I).Head := 0;
      Pipes (I).Count := 0;
      Pipes (I).Eof := False;
      return I;
   end Find_Or_Create;

   procedure Destroy (I : Natural) is
   begin
      Pipes (I).Valid := False;
      Pipes (I).N_Len := 0;
      Pipes (I).Head := 0;
      Pipes (I).Count := 0;
      Pipes (I).Eof := False;
   end Destroy;

   procedure Reset (I : Natural) is
   begin
      Pipes (I).Head := 0;
      Pipes (I).Count := 0;
      Pipes (I).Eof := False;
   end Reset;

   procedure Set_EOF (I : Natural) is
   begin
      Pipes (I).Eof := True;
   end Set_EOF;

   function Is_EOF (I : Natural) return Boolean is
     (Pipes (I).Eof);

   function Buffered (I : Natural) return U64 is
     (Pipes (I).Count);

   function Space_Left (I : Natural) return U64 is
     (Pipe_Bytes - Pipes (I).Count);

   function Pop (I : Natural; B : out Unsigned_8) return Boolean is
   begin
      if Pipes (I).Count = 0 then
         return False;
      end if;
      B := Pipes (I).Ring (Pipes (I).Head);
      Pipes (I).Head := (Pipes (I).Head + 1) mod Pipe_Bytes;
      Pipes (I).Count := Pipes (I).Count - 1;
      return True;
   end Pop;

   procedure Push (I : Natural; B : Unsigned_8) is
      Tail : constant U64 :=
        (Pipes (I).Head + Pipes (I).Count) mod Pipe_Bytes;
   begin
      Pipes (I).Ring (Tail) := B;
      Pipes (I).Count := Pipes (I).Count + 1;
   end Push;

   --  Pending table (milestone 49): deferred pipe requests.
   type Pending_Entry is record
      Kind    : Pending_Kind := P_None;
      Pipe    : Natural := 0;
      Reply_H : U64 := 0;
      Buf     : U64 := 0;
      Length  : U64 := 0;
   end record;

   --  M80d: grow-on-demand like the pipes themselves; Stash fails
   --  (poll fallback) only on arena OOM now.
   package Pend_Tab is new Akernel_User.Tables (Pending_Entry);

   function Pendings (I : Natural) return Pend_Tab.Element_Access
     renames Pend_Tab.Ref;

   function Pend_Last return Natural is
     (Pend_Tab.Last);

   function Stash
     (P : Natural; Kind : Pending_Kind;
      Reply_H, Buf, Length : U64) return Boolean
   is
      S : Natural := 0;
   begin
      for K in 1 .. Pend_Tab.Last loop
         if Pendings (K).Kind = P_None then
            S := K;
            exit;
         end if;
      end loop;
      if S = 0 then
         S := Pend_Tab.Append;
      end if;
      if S = 0 then
         return False;
      end if;
      Pendings (S).all :=
        (Kind    => Kind,
         Pipe    => P,
         Reply_H => Reply_H,
         Buf     => Buf,
         Length  => Length);
      return True;
   end Stash;

   function Pend_Pipe (S : Natural) return Natural is
     (Pendings (S).Pipe);

   function Pend_Kind (S : Natural) return Pending_Kind is
     (Pendings (S).Kind);

   function Pend_Reply (S : Natural) return U64 is
     (Pendings (S).Reply_H);

   function Pend_Buf (S : Natural) return U64 is
     (Pendings (S).Buf);

   function Pend_Length (S : Natural) return U64 is
     (Pendings (S).Length);

   procedure Pend_Clear (S : Natural) is
   begin
      Pendings (S).Kind := P_None;
      Pendings (S).Pipe := 0;
      Pendings (S).Reply_H := 0;
      Pendings (S).Buf := 0;
      Pendings (S).Length := 0;
   end Pend_Clear;

end Fileserver_Pipes;
