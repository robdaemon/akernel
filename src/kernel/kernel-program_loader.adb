with Ada.Unchecked_Conversion;
with System;
with System.Storage_Elements;
with Kernel.Initrd;

package body Kernel.Program_Loader is
   use type Interfaces.Unsigned_64;
   use type Kernel.Initrd.Status;

   subtype U8 is Interfaces.Unsigned_8;

   type U8_Access is access all U8;
   function To_U8_Access is new Ada.Unchecked_Conversion
     (Source => System.Address,
      Target => U8_Access);

   Max_Token_Length : constant := 64;
   subtype Token_String is String (1 .. Max_Token_Length);

   Manifest_Path : constant String := "System/Manifest";

   function Byte_At (Base : U64; Offset : U64) return U8 is
      Addr : constant System.Address := System.Storage_Elements.To_Address
        (System.Storage_Elements.Integer_Address (Base + Offset));
      Ptr  : constant U8_Access := To_U8_Access (Addr);
   begin
      return Ptr.all;
   end Byte_At;

   function Is_Space (C : Character) return Boolean is
   begin
      return C = ' ' or else C = Character'Val (9);
   end Is_Space;

   procedure Next_Token
     (Base      : U64;
      Line_End  : U64;
      Pos       : in out U64;
      Token     : out Token_String;
      Length    : out Natural;
      Available : out Boolean)
   is
      C : Character;
   begin
      Token := (others => Character'Val (0));
      Length := 0;
      Available := False;

      while Pos < Line_End loop
         C := Character'Val (Natural (Byte_At (Base, Pos)));
         exit when not Is_Space (C);
         Pos := Pos + 1;
      end loop;

      if Pos >= Line_End then
         return;
      end if;

      Available := True;
      while Pos < Line_End loop
         C := Character'Val (Natural (Byte_At (Base, Pos)));
         exit when Is_Space (C);

         if Length < Max_Token_Length then
            Length := Length + 1;
            Token (Length) := C;
         end if;

         Pos := Pos + 1;
      end loop;
   end Next_Token;

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
      Valid  : out Boolean) return U64
   is
      Value : U64 := 0;
      C     : Character;
   begin
      Valid := Length > 0;
      for Index in 1 .. Length loop
         C := Token (Index);
         if C < '0' or else C > '9' then
            Valid := False;
            return 0;
         end if;

         Value := Value * 10 + U64 (Character'Pos (C) - Character'Pos ('0'));
      end loop;

      return Value;
   end Parse_U64;

   function Grant_From_Token
     (Token  : Token_String;
      Length : Natural) return Grant_Kind
   is
   begin
      if Token_Equals (Token, Length, "uart_mmio") then
         return UART_MMIO_Grant;
      elsif Token_Equals (Token, Length, "uart_irq") then
         return UART_IRQ_Grant;
      else
         return No_Grant;
      end if;
   end Grant_From_Token;

   procedure Parse_Line
     (Manifest_Base : U64;
      Line_Start    : U64;
      Line_End      : U64;
      Program_Id    : U64;
      Result        : out Status;
      Manifest      : out Program_Manifest;
      Matched       : out Boolean)
   is
      Pos        : U64 := Line_Start;
      Token      : Token_String;
      Length     : Natural;
      Have_Token : Boolean;
      Valid_Id   : Boolean;
      Id         : U64;
      Path       : Token_String;
      Path_Len   : Natural;
      Init_Result : Kernel.Initrd.Status;
      Grant       : Grant_Kind;
   begin
      Result := Ok;
      Matched := False;

      Next_Token (Manifest_Base, Line_End, Pos, Token, Length, Have_Token);
      if not Have_Token or else Token (1) = '#' then
         return;
      end if;

      if not Token_Equals (Token, Length, "program") then
         return;
      end if;

      Next_Token (Manifest_Base, Line_End, Pos, Token, Length, Have_Token);
      if not Have_Token then
         Result := Bad_Image;
         return;
      end if;

      Id := Parse_U64 (Token, Length, Valid_Id);
      if not Valid_Id then
         Result := Bad_Image;
         return;
      end if;

      if Id /= Program_Id then
         return;
      end if;

      Next_Token (Manifest_Base, Line_End, Pos, Path, Path_Len, Have_Token);
      if not Have_Token then
         Result := Bad_Image;
         return;
      end if;

      Manifest := Null_Manifest;
      Kernel.Initrd.Find
        (Name   => Path (1 .. Path_Len),
         Result => Init_Result,
         Base   => Manifest.Image.Base,
         Size   => Manifest.Image.Size);

      case Init_Result is
         when Kernel.Initrd.Ok =>
            null;
         when Kernel.Initrd.Not_Found =>
            Result := Not_Found;
            return;
         when others =>
            Result := Bad_Image;
            return;
      end case;

      loop
         Next_Token
           (Manifest_Base, Line_End, Pos, Token, Length, Have_Token);
         exit when not Have_Token;

         Grant := Grant_From_Token (Token, Length);
         if Grant /= No_Grant then
            if Manifest.Grant_Count = Max_Grants then
               Result := Bad_Image;
               return;
            end if;

            Manifest.Grants
              (Grant_Index (Manifest.Grant_Count)) := Grant;
            Manifest.Grant_Count := Manifest.Grant_Count + 1;
         end if;
      end loop;

      Matched := True;
   end Parse_Line;

   procedure Find
     (Program_Id : U64;
      Result     : out Status;
      Manifest   : out Program_Manifest)
   is
      Init_Result   : Kernel.Initrd.Status;
      Manifest_Base : U64;
      Manifest_Size : U64;
      Line_Start    : U64 := 0;
      Line_End      : U64;
      C             : Character;
      Matched       : Boolean;
   begin
      Manifest := Null_Manifest;

      Kernel.Initrd.Find
        (Name   => Manifest_Path,
         Result => Init_Result,
         Base   => Manifest_Base,
         Size   => Manifest_Size);

      if Init_Result = Kernel.Initrd.Not_Found then
         Result := Not_Found;
         return;
      elsif Init_Result /= Kernel.Initrd.Ok then
         Result := Bad_Image;
         return;
      end if;

      while Line_Start < Manifest_Size loop
         Line_End := Line_Start;
         while Line_End < Manifest_Size loop
            C := Character'Val
              (Natural (Byte_At (Manifest_Base, Line_End)));
            exit when C = Character'Val (10) or else C = Character'Val (13);
            Line_End := Line_End + 1;
         end loop;

         Parse_Line
           (Manifest_Base => Manifest_Base,
            Line_Start    => Line_Start,
            Line_End      => Line_End,
            Program_Id    => Program_Id,
            Result        => Result,
            Manifest      => Manifest,
            Matched       => Matched);

         if Result /= Ok or else Matched then
            if Matched then
               Result := Ok;
            end if;
            return;
         end if;

         Line_Start := Line_End + 1;
         while Line_Start < Manifest_Size loop
            C := Character'Val
              (Natural (Byte_At (Manifest_Base, Line_Start)));
            exit when C /= Character'Val (10) and then C /= Character'Val (13);
            Line_Start := Line_Start + 1;
         end loop;
      end loop;

      Result := Invalid_Program;
   end Find;
end Kernel.Program_Loader;
