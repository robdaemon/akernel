with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.Syscalls;
with System.Storage_Elements;

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

   --  Input redirection state (milestone 46b): the args-page
   --  trailer's in_path. Library level (stack rule).
   In_Set    : Boolean := False;
   In_Pipe   : Boolean := False;
   In_Path   : String (1 .. 48) := (others => Character'Val (0));
   In_PLen   : Natural := 0;
   In_Offset : Syscalls.U64 := 0;  --  regular files only
   In_Buf    : String (1 .. 4096) := (others => Character'Val (0));
   In_Pos    : Natural := 1;
   In_End    : Natural := 0;
   In_EOF    : Boolean := False;

   --  Read the redirection trailer and wire it up. Runs once
   --  with Parse_Args (the page is mapped by Read_Args first).
   procedure Parse_Trailer is
      use System.Storage_Elements;
      type Word_Array is array (0 .. 7) of Syscalls.U64;
      Trailer : Word_Array
        with Address => To_Address
          (Integer_Address (Syscalls.Args_VA
                            + Syscalls.Args_Trailer_Offset));
      Mapped : Boolean;

      function Path_At (Off : Syscalls.U64) return String is
         Page : String (1 .. 4096)
           with Address => To_Address
             (Integer_Address (Syscalls.Args_VA));
         Len : Natural := 0;
      begin
         if Off = 0 or else Off >= 4032 then
            return "";
         end if;
         while Off + Syscalls.U64 (Len) < 4032
           and then Page (Integer (Off) + Len + 1) /=
             Character'Val (0)
         loop
            Len := Len + 1;
         end loop;
         return Page (Integer (Off) + 1 .. Integer (Off) + Len);
      end Path_At;
   begin
      Syscalls.Map_Args (Mapped);
      if not Mapped
        or else Trailer (0) /= Syscalls.Args_Trailer_Magic
      then
         return;
      end if;
      declare
         Out_P : constant String := Path_At (Trailer (1));
         In_P  : constant String := Path_At (Trailer (2));
      begin
         if Out_P'Length > 0 then
            Console.Set_Redirect_Out (Out_P);
         end if;
         if In_P'Length > 0 and then In_P'Length <= In_Path'Length
         then
            In_Path := (others => Character'Val (0));
            In_Path (1 .. In_P'Length) := In_P;
            In_PLen := In_P'Length;
            In_Pipe := In_P'Length >= 5
              and then (In_P (In_P'First .. In_P'First + 4) =
                          "PIPE:"
                        or else In_P (In_P'First .. In_P'First + 4)
                          = "pipe:");
            In_Set := True;
         end if;
      end;
   end Parse_Trailer;

   procedure Parse_Args is
      I : Natural := 1;
      F : Natural;
   begin
      if Args_Read then
         return;
      end if;
      Args_Read := True;
      Syscalls.Read_Args (Args_Buf, Args_Len);
      Parse_Trailer;
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

   procedure Init is
   begin
      --  Lazy default binding (milestone 54): same no-clobber
      --  rule as the gloss Ensure_Bound — a program that bound
      --  its own endpoint layout (fuzz) keeps it. Resolve_Path
      --  reads ENV:CWD through Files, so the fs handle must be
      --  live before any path touches it; programs no longer
      --  bind handles 1/2 by hand.
      if Console.Endpoint = 0 then
         Console.Set_Endpoint (1);
      end if;
      if Files.Endpoint = 0 then
         Files.Bind (2);
      end if;
      Parse_Args;
   end Init;

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

   --  ENV: lives at Sys:Prefs/Env, and Prefs/ ships absent from
   --  the disk image — create the directory chain on FIRST USE
   --  (first env write), not at image build. Directories answer
   --  Stat with Bad_Args (dirs are not stat-able), so "missing"
   --  is exactly Status_Not_Found. Best effort: a failing Mkdir
   --  is ignored, the Write verdict decides.
   procedure Ensure_Env_Dir is
      Size : U64 := 0;
      Txt  : String (1 .. 40);
      TL   : Natural;
      St   : U64;
   begin
      if Files.Stat ("ENV:", Size) /= Files.Status_Not_Found then
         return;
      end if;
      for I in U64 range 0 .. 15 loop
         St := Files.Assign_List (I, Txt, TL);
         exit when St /= Files.Status_Ok;
         if TL >= 6 and then Txt (1 .. 5) = "ENV: " then
            declare
               T : constant String := Txt (6 .. TL);
            begin
               for J in reverse T'Range loop
                  if T (J) = '/' then
                     St := Files.Mkdir (T (T'First .. J - 1));
                     exit;
                  end if;
               end loop;
               St := Files.Mkdir (T);
            end;
            return;
         end if;
      end loop;
   end Ensure_Env_Dir;

   function Set_Env (Name : String; Value : String) return U64 is
      Count : U64 := 0;
      St    : U64;
   begin
      Ensure_Env_Dir;
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

      --  The current directory comes first, always (the Amiga
      --  current-dir rule; milestone 43). Then the Path variable
      --  entries — they ADD to the search — and last the built-in
      --  default: the volume root, then C:. (Path REPLACING the
      --  built-in tail made `Path X ADD` hide every C: command
      --  including Path itself — Amiga never removes C:.)
      declare
         Rel : constant String := Resolve_Path (Name);
      begin
         if Rel'Length > Name'Length and then Try (Rel) then
            return Rel;
         end if;
      end;

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
      end if;

      --  Built-in tail (always): the boot volume root, then the
      --  C: assign. Both candidates are fully qualified — no
      --  Files.Set_Default_Volume involved (milestone 44).
      declare
         Root_Try : constant String := Boot_Volume & Name;
         C_Try    : constant String := "C:" & Name;
      begin
         if Try (Root_Try) then
            return Root_Try;
         end if;
         if Try (C_Try) then
            return C_Try;
         end if;
      end;

      return "";
   end Resolve_Command;

   ---------------------------------------------------------------
   --  cwd + path helpers (milestone 42)
   ---------------------------------------------------------------

   function Get_Cwd return String is
      V : constant String := Get_Env ("CWD");
   begin
      if V'Length = 0 then
         return Boot_Volume;
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
      --  Exception: a TRAILING empty component is just a
      --  trailing separator (POSIX "the directory itself") and
      --  is ignored — "c/" is c, not its parent. The bare-"/"
      --  idiom is unaffected: Join_Path supplies the cwd's own
      --  separator, so "/" becomes a middle empty component.
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
         if F <= Path'Last then
            Component (F, Path'Last);
         end if;
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
      Console.Close_Redirect;  --  flush a redirected tail (m54)
      Syscalls.Process_Exit (Code);
      loop
         Syscalls.Yield;  --  unreachable; keeps No_Return honest
      end loop;
   end Fail_With;

   procedure Get_Line
     (S           : out String;
      Len         : out Natural;
      End_Of_Input : out Boolean)
   is
      Status : U64;
      Count  : U64;
      L      : Natural;
   begin
      Parse_Args;
      Len := 0;
      End_Of_Input := False;
      if not In_Set then
         End_Of_Input := True;  --  no stdin in the ABI yet
         return;
      end if;
      loop
         --  A buffered line?
         for I in In_Pos .. In_End loop
            if In_Buf (I) = Character'Val (10) then
               L := Natural'Min (S'Length, I - In_Pos);
               if L > 0 then
                  S (S'First .. S'First + L - 1) :=
                    In_Buf (In_Pos .. In_Pos + L - 1);
               end if;
               Len := L;
               In_Pos := I + 1;
               return;
            end if;
         end loop;

         if In_EOF then
            --  A trailing unterminated line, then EOF.
            if In_Pos <= In_End then
               L := Natural'Min (S'Length, In_End - In_Pos + 1);
               S (S'First .. S'First + L - 1) :=
                 In_Buf (In_Pos .. In_Pos + L - 1);
               Len := L;
               In_Pos := In_End + 1;
               return;
            end if;
            End_Of_Input := True;
            return;
         end if;

         --  Compact and refill.
         if In_Pos > 1 then
            if In_Pos <= In_End then
               In_Buf (1 .. In_End - In_Pos + 1) :=
                 In_Buf (In_Pos .. In_End);
               In_End := In_End - In_Pos + 1;
            else
               In_End := 0;
            end if;
            In_Pos := 1;
         end if;
         if In_End = In_Buf'Length then
            --  Line longer than the staging buffer: deliver the
            --  buffer as a (split) line.
            L := Natural'Min (S'Length, In_End);
            S (S'First .. S'First + L - 1) := In_Buf (1 .. L);
            Len := L;
            if L = In_End then
               In_Pos := 1;
               In_End := 0;
            else
               In_Buf (1 .. In_End - L) := In_Buf (L + 1 .. In_End);
               In_End := In_End - L;
            end if;
            return;
         end if;

         if In_Pipe then
            Status := Files.Status_Not_Ready;
            for Try in 1 .. 1_000_000 loop
               Status := Files.Read
                 (In_Path (1 .. In_PLen), 0,
                  In_Buf (In_End + 1)'Address,
                  U64 (In_Buf'Length - In_End), Count);
               exit when Status /= Files.Status_Not_Ready;
               Syscalls.Yield;
            end loop;
         else
            Status := Files.Read
              (In_Path (1 .. In_PLen), In_Offset,
               In_Buf (In_End + 1)'Address,
               U64 (In_Buf'Length - In_End), Count);
         end if;

         if Status = Files.Status_Ok and then Count > 0 then
            In_End := In_End + Natural (Count);
            if not In_Pipe then
               In_Offset := In_Offset + Count;
            end if;
         else
            --  Ok+0 / Out_Of_Range at end of file, a pipe poll
            --  that outlived its bound, or an error: all of
            --  them surface as EOF to the reader.
            In_EOF := True;
         end if;
      end loop;
   end Get_Line;

   procedure Exit_With (Code : U64 := RC_Ok) is
   begin
      Console.Close_Redirect;  --  flush + pipe EOF (m46b)
      Syscalls.Process_Exit (Code);
      loop
         Syscalls.Yield;
      end loop;
   end Exit_With;

end Akernel_User.CLI;
