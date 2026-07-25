with Akernel_User.Syscalls;

procedure Init is
   use type Akernel_User.Syscalls.U64;

   Max_Token_Length : constant := 64;
   subtype Token_String is String (1 .. Max_Token_Length);

   Manifest_File : constant Akernel_User.Syscalls.U64 :=
     Akernel_User.Syscalls.Boot_Manifest_File;

   Manifest_Size : Akernel_User.Syscalls.U64;
   Spawned_Count : Akernel_User.Syscalls.U64 := 0;

   function Is_Space (C : Character) return Boolean is
   begin
      return C = ' ' or else C = Character'Val (9);
   end Is_Space;

   function Token_Equals
     (Token  : Token_String;
      Length : Natural;
      Value  : String) return Boolean
   is
   begin
      if Length /= Value'Length then
         return False;
      end if;

      for Index in Value'Range loop
         if Token (Index - Value'First + 1) /= Value (Index) then
            return False;
         end if;
      end loop;

      return True;
   end Token_Equals;

   function Parse_U64
     (Token  : Token_String;
      Length : Natural;
      Valid  : out Boolean) return Akernel_User.Syscalls.U64
   is
      Value : Akernel_User.Syscalls.U64 := 0;
      C     : Character;
   begin
      Valid := Length > 0;
      for Index in 1 .. Length loop
         C := Token (Index);
         if C < '0' or else C > '9' then
            Valid := False;
            return 0;
         end if;

         Value := Value * 10
           + Akernel_User.Syscalls.U64
             (Character'Pos (C) - Character'Pos ('0'));
      end loop;

      return Value;
   end Parse_U64;

   procedure Skip_Spaces
     (Line_End : Akernel_User.Syscalls.U64;
      Pos      : in out Akernel_User.Syscalls.U64)
   is
      Raw : Akernel_User.Syscalls.U64;
      C   : Character;
   begin
      while Pos < Line_End loop
         Raw := Akernel_User.Syscalls.Boot_Read_Byte
           (Manifest_File, Pos);
         exit when Raw > 255;
         C := Character'Val (Natural (Raw));
         exit when not Is_Space (C);
         Pos := Pos + 1;
      end loop;
   end Skip_Spaces;

   procedure Next_Token
     (Line_End  : Akernel_User.Syscalls.U64;
      Pos       : in out Akernel_User.Syscalls.U64;
      Token     : out Token_String;
      Length    : out Natural;
      Available : out Boolean)
   is
      Raw : Akernel_User.Syscalls.U64;
      C   : Character;
   begin
      Token := (others => Character'Val (0));
      Length := 0;
      Available := False;

      while Pos < Line_End loop
         Raw := Akernel_User.Syscalls.Boot_Read_Byte
           (Manifest_File, Pos);
         exit when Raw > 255;
         C := Character'Val (Natural (Raw));
         exit when not Is_Space (C);
         Pos := Pos + 1;
      end loop;

      if Pos >= Line_End then
         return;
      end if;

      Available := True;
      while Pos < Line_End loop
         Raw := Akernel_User.Syscalls.Boot_Read_Byte
           (Manifest_File, Pos);
         exit when Raw > 255;
         C := Character'Val (Natural (Raw));
         exit when Is_Space (C);

         if Length < Max_Token_Length then
            Length := Length + 1;
            Token (Length) := C;
         end if;

         Pos := Pos + 1;
      end loop;
   end Next_Token;

   procedure Parse_Program_Line
     (Line_Start : Akernel_User.Syscalls.U64;
      Line_End   : Akernel_User.Syscalls.U64)
   is
      Pos        : Akernel_User.Syscalls.U64 := Line_Start;
      Token      : Token_String;
      Length     : Natural;
      Have_Token : Boolean;
      Valid_Id   : Boolean;
      Program_Id : Akernel_User.Syscalls.U64;
      Grant_Mask  : Akernel_User.Syscalls.U64 := 0;
      Path_Offset : Akernel_User.Syscalls.U64;
      Path_Length : Akernel_User.Syscalls.U64;
      Result      : Akernel_User.Syscalls.U64;
   begin
      Next_Token (Line_End, Pos, Token, Length, Have_Token);
      if not Have_Token or else Token (1) = '#' then
         return;
      end if;

      if not Token_Equals (Token, Length, "program") then
         return;
      end if;

      Next_Token (Line_End, Pos, Token, Length, Have_Token);
      if not Have_Token then
         return;
      end if;

      Program_Id := Parse_U64 (Token, Length, Valid_Id);
      if not Valid_Id then
         return;
      end if;

      Skip_Spaces (Line_End, Pos);
      Path_Offset := Pos;
      Next_Token (Line_End, Pos, Token, Length, Have_Token);
      if not Have_Token then
         return;
      end if;
      Path_Length := Akernel_User.Syscalls.U64 (Length);

      loop
         Next_Token (Line_End, Pos, Token, Length, Have_Token);
         exit when not Have_Token;

         if Token_Equals (Token, Length, "uart_mmio") then
            Grant_Mask := Grant_Mask
              or Akernel_User.Syscalls.UART_MMIO_Grant_Bit;
         elsif Token_Equals (Token, Length, "uart_irq") then
            Grant_Mask := Grant_Mask
              or Akernel_User.Syscalls.UART_IRQ_Grant_Bit;
         end if;
      end loop;

      Result := Akernel_User.Syscalls.Spawn_Boot_Path
        (Path_Offset, Path_Length, Grant_Mask);

      if Result /= 0 then
         Spawned_Count := Spawned_Count + 1;
         if Program_Id = 1 then
            Akernel_User.Syscalls.Debug_Put_Line ("serial spawned");
         else
            Akernel_User.Syscalls.Debug_Put_Line ("program spawned");
         end if;
      else
         Akernel_User.Syscalls.Debug_Put_Line ("program spawn failed");
      end if;
   end Parse_Program_Line;

   procedure Parse_Manifest is
      Line_Start : Akernel_User.Syscalls.U64 := 0;
      Line_End   : Akernel_User.Syscalls.U64;
      Raw        : Akernel_User.Syscalls.U64;
      C          : Character;
   begin
      while Line_Start < Manifest_Size loop
         Line_End := Line_Start;
         while Line_End < Manifest_Size loop
            Raw := Akernel_User.Syscalls.Boot_Read_Byte
              (Manifest_File, Line_End);
            exit when Raw > 255;
            C := Character'Val (Natural (Raw));
            exit when C = Character'Val (10) or else C = Character'Val (13);
            Line_End := Line_End + 1;
         end loop;

         Parse_Program_Line (Line_Start, Line_End);

         Line_Start := Line_End + 1;
         while Line_Start < Manifest_Size loop
            Raw := Akernel_User.Syscalls.Boot_Read_Byte
              (Manifest_File, Line_Start);
            exit when Raw > 255;
            C := Character'Val (Natural (Raw));
            exit when C /= Character'Val (10) and then C /= Character'Val (13);
            Line_Start := Line_Start + 1;
         end loop;
      end loop;
   end Parse_Manifest;
begin
   Akernel_User.Syscalls.Debug_Put_Line ("init online from Ada");

   Manifest_Size := Akernel_User.Syscalls.Boot_File_Size (Manifest_File);
   if Manifest_Size = Akernel_User.Syscalls.Syscall_Failed then
      Akernel_User.Syscalls.Debug_Put_Line
        ("init fatal: boot manifest unavailable");
      loop
         Akernel_User.Syscalls.Yield;
      end loop;
   end if;

   Akernel_User.Syscalls.Debug_Put_Line ("boot manifest visible");
   Akernel_User.Syscalls.Debug_Put_Line ("launching manifest programs");
   Parse_Manifest;

   Akernel_User.Syscalls.Yield;
   Akernel_User.Syscalls.Debug_Put_Line ("init resumed");

   if Spawned_Count = 0 then
      Akernel_User.Syscalls.Debug_Put_Line
        ("init fatal: no manifest programs spawned");
   end if;

   loop
      Akernel_User.Syscalls.Yield;
   end loop;
end Init;
