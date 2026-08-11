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

   Pipes : array (1 .. Max_Pipes) of Pipe_Entry;

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
      for I in Pipes'Range loop
         if Pipes (I).Valid and then Match (Name, I) then
            return I;
         end if;
      end loop;
      return 0;
   end Find;

   function Find_Or_Create (Name : String) return Natural is
      P : constant Natural := Find (Name);
   begin
      if P /= 0 then
         return P;
      end if;
      if Name'Length = 0 or else Name'Length > Max_Pipe_Name then
         return 0;
      end if;
      for I in Pipes'Range loop
         if not Pipes (I).Valid then
            Pipes (I).Valid := True;
            Pipes (I).Name := (others => Character'Val (0));
            Pipes (I).Name (1 .. Name'Length) := Name;
            Pipes (I).N_Len := Name'Length;
            Pipes (I).Head := 0;
            Pipes (I).Count := 0;
            Pipes (I).Eof := False;
            return I;
         end if;
      end loop;
      return 0;
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

end Fileserver_Pipes;
