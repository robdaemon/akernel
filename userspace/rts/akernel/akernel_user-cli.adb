with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.Syscalls;

package body Akernel_User.CLI is

   --  Args page staging + token table (library level: big buffers
   --  never live on the user stack).
   Args_Buf   : String (1 .. 4096) := (others => Character'Val (0));
   Args_Len   : Natural := 0;
   Args_Read  : Boolean := False;

   Max_Args   : constant := 64;
   type Slice is record
      First : Natural := 0;
      Last  : Natural := 0;  --  0/0 = empty
   end record;
   Tokens    : array (1 .. Max_Args) of Slice;
   Tok_Count : Natural := 0;

   procedure Parse_Args is
      I : Natural := 1;
      F : Natural;
   begin
      if Args_Read then
         return;
      end if;
      Args_Read := True;
      Syscalls.Read_Args (Args_Buf, Args_Len);
      while I <= Args_Len loop
         while I <= Args_Len and then Args_Buf (I) = ' ' loop
            I := I + 1;
         end loop;
         exit when I > Args_Len or else Tok_Count = Max_Args;
         F := I;
         while I <= Args_Len and then Args_Buf (I) /= ' ' loop
            I := I + 1;
         end loop;
         Tok_Count := Tok_Count + 1;
         Tokens (Tok_Count) := (First => F, Last => I - 1);
      end loop;
   end Parse_Args;

   function Arg_Count return Natural is
   begin
      Parse_Args;
      return Tok_Count;
   end Arg_Count;

   function Argument (Index : Positive) return String is
   begin
      Parse_Args;
      if Index > Tok_Count then
         return "";
      end if;
      return Args_Buf (Tokens (Index).First .. Tokens (Index).Last);
   end Argument;

   Env_Buf : String (1 .. 256);

   function Get_Env (Name : String) return String is
      Size  : U64 := 0;
      Count : U64 := 0;
      St    : U64;
   begin
      St := Files.Open ("ENV:" & Name, Size);
      if St /= Files.Status_Ok then
         return "";
      end if;
      Size := U64'Min (Size, U64 (Env_Buf'Length));
      St := Files.Read
        ("ENV:" & Name, 0, Env_Buf'Address, Size, Count);
      if St /= Files.Status_Ok or else Count = 0 then
         return "";
      end if;
      return Env_Buf (1 .. Natural (Count));
   end Get_Env;

   function Set_Env (Name : String; Value : String) return U64 is
      Count : U64 := 0;
      St    : U64;
   begin
      St := Files.Truncate ("ENV:" & Name);
      for I in Value'Range loop
         Env_Buf (I - Value'First + 1) := Value (I);
      end loop;
      --  Write creates the file when missing.
      return Files.Write
        ("ENV:" & Name, 0, Env_Buf'Address,
         U64 (Value'Length), Count);
   end Set_Env;

   function Resolve_Command (Name : String) return String is
      Size      : U64 := 0;
      Path      : constant String := Get_Env ("Path");
      Candidate : String (1 .. 256);
      CLen      : Natural;
      P0        : Natural;

      function Try (S : String) return Boolean is
      begin
         return Files.Stat (S, Size) = Files.Status_Ok;
      end Try;
   begin
      for C of Name loop
         if C = ':' or else C = '/' then
            return Name;
         end if;
      end loop;

      if Path'Length > 0 then
         P0 := Path'First;
         for I in Path'Range loop
            if Path (I) = ';' then
               if I > P0 then
                  CLen := I - P0;
                  Candidate (1 .. CLen) := Path (P0 .. I - 1);
                  Candidate (CLen + 1 .. CLen + Name'Length) := Name;
                  CLen := CLen + Name'Length;
                  if Try (Candidate (1 .. CLen)) then
                     return Candidate (1 .. CLen);
                  end if;
               end if;
               P0 := I + 1;
            elsif I = Path'Last then
               CLen := I - P0 + 1;
               Candidate (1 .. CLen) := Path (P0 .. I);
               Candidate (CLen + 1 .. CLen + Name'Length) := Name;
               CLen := CLen + Name'Length;
               if Try (Candidate (1 .. CLen)) then
                  return Candidate (1 .. CLen);
               end if;
            end if;
         end loop;
      else
         --  Default search: cwd, then the volume root (the
         --  default-volume bind makes a bare name root-relative),
         --  then C/.
         declare
            Rel : constant String := Resolve_Path (Name);
         begin
            if Rel'Length > Name'Length and then Try (Rel) then
               return Rel;
            end if;
         end;
         if Try (Name) then
            return Name;
         end if;
         if Try ("C/" & Name) then
            return "C/" & Name;
         end if;
      end if;

      return "";
   end Resolve_Command;

   ---------------------------------------------------------------
   --  cwd + path helpers (milestone 42)
   ---------------------------------------------------------------

   function Get_Cwd return String is
      V : constant String := Get_Env ("CWD");
   begin
      if V'Length = 0 then
         return "BD0:";
      end if;
      return V;
   end Get_Cwd;

   function Set_Cwd (Path : String) return U64 is
   begin
      return Set_Env ("CWD", Path);
   end Set_Cwd;

   function Join_Path (Dir, Leaf : String) return String is
   begin
      if Dir'Length > 0 and then Dir (Dir'Last) = ':' then
         return Dir & Leaf;
      end if;
      return Dir & "/" & Leaf;
   end Join_Path;

   function Normalize_Path (Path : String) return String is
      Max_Comps : constant := 16;
      type Slice is record
         First : Natural := 0;
         Last  : Natural := 0;
      end record;
      Comps  : array (1 .. Max_Comps) of Slice;
      NComp  : Natural := 0;
      Colon  : Natural := 0;  --  index of ':' in Path, 0 = none
      Result : String (1 .. 256);
      RLen   : Natural := 0;

      procedure Push (F, L : Natural) is
      begin
         if F > L or else NComp = Max_Comps then
            return;
         end if;
         NComp := NComp + 1;
         Comps (NComp) := (First => F, Last => L);
      end Push;
   begin
      for I in Path'Range loop
         if Path (I) = ':' then
            Colon := I;
            exit;
         end if;
      end loop;

      --  Split the component part on '/': an empty component
      --  ascends one level (the Amiga "/" parent idiom), ".."
      --  is honoured as an alias, everything else pushes.
      declare
         F : Natural := (if Colon = 0 then Path'First else Colon + 1);

         procedure Component (F, L : Natural) is
         begin
            if F > L
              or else (L - F = 1
                       and then Path (F) = '.'
                       and then Path (L) = '.')
            then
               if NComp > 0 then
                  NComp := NComp - 1;
               end if;
            else
               Push (F, L);
            end if;
         end Component;
      begin
         for I in F .. Path'Last loop
            if Path (I) = '/' then
               Component (F, I - 1);
               F := I + 1;
            end if;
         end loop;
         Component (F, Path'Last);
      end;

      if Colon > 0 then
         for I in Path'First .. Colon loop
            RLen := RLen + 1;
            Result (RLen) := Path (I);
         end loop;
      end if;
      for C in 1 .. NComp loop
         if RLen > 0 and then Result (RLen) /= ':' then
            RLen := RLen + 1;
            Result (RLen) := '/';
         end if;
         for I in Comps (C).First .. Comps (C).Last loop
            RLen := RLen + 1;
            exit when RLen > Result'Last;
            Result (RLen) := Path (I);
         end loop;
      end loop;
      return Result (1 .. RLen);
   end Normalize_Path;

   function Resolve_Path (Path : String) return String is
   begin
      for C of Path loop
         if C = ':' then
            return Normalize_Path (Path);
         end if;
      end loop;
      return Normalize_Path (Join_Path (Get_Cwd, Path));
   end Resolve_Path;

   procedure Fail_With (Message : String; Code : U64 := RC_Error) is
   begin
      Console.Put_Line (Message);
      Syscalls.Process_Exit (Code);
      loop
         Syscalls.Yield;  --  unreachable; keeps No_Return honest
      end loop;
   end Fail_With;

   procedure Exit_With (Code : U64 := RC_Ok) is
   begin
      Syscalls.Process_Exit (Code);
      loop
         Syscalls.Yield;
      end loop;
   end Exit_With;

end Akernel_User.CLI;
