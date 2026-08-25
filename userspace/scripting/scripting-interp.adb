with Interfaces;
with Ada.Unchecked_Deallocation;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.CLI;

package body Scripting.Interp is
   use Akernel_User.Syscalls;
   use type U64;

   function Lower (C : Character) return Character is
   begin
      if C in 'A' .. 'Z' then
         return Character'Val (Character'Pos (C) + 32);
      end if;
      return C;
   end Lower;

   --  Case-insensitive equality (Amiga keywords are caseless).
   function Same_Word (A : String; B : String) return Boolean is
   begin
      if A'Length /= B'Length then
         return False;
      end if;
      for I in A'Range loop
         if Lower (A (I)) /= Lower (B (B'First + (I - A'First))) then
            return False;
         end if;
      end loop;
      return True;
   end Same_Word;

   function Is_Ident_Start (C : Character) return Boolean is
     ((C in 'a' .. 'z') or else (C in 'A' .. 'Z') or else C = '_');

   function Is_Ident (C : Character) return Boolean is
     (Is_Ident_Start (C) or else (C in '0' .. '9'));

   --  Both-ends space trim: First/Last bracket the trimmed span
   --  (First > Last when the string is all spaces).
   procedure Trim (S : String; First, Last : out Natural) is
   begin
      First := S'First;
      Last  := S'Last;
      while First <= Last and then S (First) = ' ' loop
         First := First + 1;
      end loop;
      while Last >= First and then S (Last) = ' ' loop
         Last := Last - 1;
      end loop;
   end Trim;

   function Run
     (Path  : String;
      Args  : String;
      Depth : Natural) return U64
   is
      subtype Byte is Interfaces.Unsigned_8;
      use type Byte;
      type Byte_Array is array (U64 range <>) of Byte;
      type Buf_Access is access Byte_Array;
      procedure Free is new Ada.Unchecked_Deallocation
        (Byte_Array, Buf_Access);

      Full  : constant String := Akernel_User.CLI.Resolve_Path (Path);
      Size  : U64 := 0;
      Count : U64 := 0;
      St    : U64;
      Buf   : Buf_Access;
      RC    : U64 := 0;

      --  Script locals (chunk 2): .key template slots (in
      --  positional order via Order), .def defaults, .set
      --  runtime updates. A slot with VLen = 0 is DEFINED-EMPTY
      --  — distinct from undefined, which is a hard error at
      --  substitution time.
      Max_Name  : constant := 32;
      Max_Value : constant := 128;
      type Local_Rec is record
         Name : String (1 .. Max_Name) := (others => ' ');
         NLen : Natural := 0;
         Val  : String (1 .. Max_Value) := (others => ' ');
         VLen : Natural := 0;
      end record;
      Locals   : array (1 .. Max_Locals) of Local_Rec;
      NLoc     : Natural := 0;
      Order    : array (1 .. Max_Locals) of Natural := (others => 0);
      Template : Natural := 0;
      Bound    : Boolean := False;

      --  Case-insensitive local lookup; 0 when undefined.
      function Find_Local (Name : String) return Natural is
      begin
         for I in 1 .. NLoc loop
            if Same_Word
              (Locals (I).Name (1 .. Locals (I).NLen), Name)
            then
               return I;
            end if;
         end loop;
         return 0;
      end Find_Local;

      --  Add a fresh slot (no dup check — callers do it);
      --  reports and returns 0 when full/the name is too long.
      function Add_Local (Name : String) return Natural is
      begin
         if Name'Length = 0 or else Name'Length > Max_Name then
            Akernel_User.Console.Put_Line
              ("bad local name: " & Name);
            return 0;
         end if;
         if NLoc = Max_Locals then
            Akernel_User.Console.Put_Line ("too many locals (16)");
            return 0;
         end if;
         NLoc := NLoc + 1;
         Locals (NLoc).Name (1 .. Name'Length) := Name;
         Locals (NLoc).NLen := Name'Length;
         Locals (NLoc).VLen := 0;
         return NLoc;
      end Add_Local;

      --  Set Slot's value; False (+ message) when overlong.
      function Set_Value (Slot : Natural; Value : String) return Boolean
      is
      begin
         if Value'Length > Max_Value then
            Akernel_User.Console.Put_Line ("local value too long");
            return False;
         end if;
         Locals (Slot).Val (1 .. Value'Length) := Value;
         Locals (Slot).VLen := Value'Length;
         return True;
      end Set_Value;

      --  .key a,b,c — comma-separated template names in
      --  positional order. RC_Error out on a malformed header.
      procedure Parse_Key (Rest : String; Bad : out Boolean) is
         I : Natural := Rest'First;
         J : Natural;
         F : Natural;
         L : Natural;
      begin
         Bad := False;
         while I <= Rest'Last loop
            J := I;
            while J <= Rest'Last and then Rest (J) /= ',' loop
               J := J + 1;
            end loop;
            Trim (Rest (I .. J - 1), F, L);
            if L >= F then
               declare
                  Slot : Natural := Find_Local (Rest (F .. L));
               begin
                  if Slot = 0 then
                     Slot := Add_Local (Rest (F .. L));
                     if Slot = 0 then
                        Bad := True;
                        return;
                     end if;
                  end if;
                  if Template = Max_Locals then
                     Akernel_User.Console.Put_Line
                       ("too many locals (16)");
                     Bad := True;
                     return;
                  end if;
                  Template := Template + 1;
                  Order (Template) := Slot;
               end;
            end if;
            I := J + 1;
         end loop;
      end Parse_Key;

      --  .def name=value — default for a template name (or a
      --  plain named local when the name is not templated).
      procedure Parse_Def (Rest : String; Bad : out Boolean) is
         Eq : Natural := 0;
         NF : Natural;
         NL : Natural;
         VF : Natural;
         VL : Natural;
      begin
         Bad := False;
         for I in Rest'Range loop
            if Rest (I) = '=' then
               Eq := I;
               exit;
            end if;
         end loop;
         if Eq = 0 then
            Akernel_User.Console.Put_Line
              ("bad .def (want .def name=value)");
            Bad := True;
            return;
         end if;
         Trim (Rest (Rest'First .. Eq - 1), NF, NL);
         Trim (Rest (Eq + 1 .. Rest'Last), VF, VL);
         if NL < NF then
            Akernel_User.Console.Put_Line
              ("bad .def (want .def name=value)");
            Bad := True;
            return;
         end if;
         declare
            Slot : Natural := Find_Local (Rest (NF .. NL));
         begin
            if Slot = 0 then
               Slot := Add_Local (Rest (NF .. NL));
               if Slot = 0 then
                  Bad := True;
                  return;
               end if;
            end if;
            if VL >= VF
              and then not Set_Value (Slot, Rest (VF .. VL))
            then
               Bad := True;
            end if;
         end;
      end Parse_Def;

      --  Bind the whitespace-separated Args through the
      --  template: arg I overrides slot Order (I)'s .def
      --  default. Extra args are ignored (lenient).
      procedure Bind_Args (Bad : out Boolean) is
         I    : Natural := Args'First;
         J    : Natural;
         Slot : Natural := 0;
      begin
         Bad := False;
         while I <= Args'Last and then Slot < Template loop
            while I <= Args'Last and then Args (I) = ' ' loop
               I := I + 1;
            end loop;
            exit when I > Args'Last;
            J := I;
            while J <= Args'Last and then Args (J) /= ' ' loop
               J := J + 1;
            end loop;
            Slot := Slot + 1;
            if not Set_Value (Order (Slot), Args (I .. J - 1)) then
               Bad := True;
               return;
            end if;
            I := J + 1;
         end loop;
         Bound := True;
      end Bind_Args;

      --  <name> lookup: locals first (unless Env_Only), then
      --  ENV:<name>. ENV definedness comes from Stat —
      --  CLI.Get_Env cannot tell unset from empty.
      procedure Lookup
        (Name     : String;
         Env_Only : Boolean;
         Val      : out String;
         VLen     : out Natural;
         Defined  : out Boolean)
      is
         Slot : Natural := 0;
         Sz   : U64 := 0;
      begin
         VLen := 0;
         Defined := False;
         if not Env_Only then
            Slot := Find_Local (Name);
         end if;
         if Slot /= 0 then
            Defined := True;
            VLen := Locals (Slot).VLen;
            Val (Val'First .. Val'First + VLen - 1) :=
              Locals (Slot).Val (1 .. VLen);
            return;
         end if;
         if Akernel_User.Files.Stat ("ENV:" & Name, Sz) =
           Akernel_User.Files.Status_Ok
         then
            Defined := True;
            declare
               V : constant String := Akernel_User.CLI.Get_Env (Name);
            begin
               VLen := Natural'Min (V'Length, Val'Length);
               if VLen > 0 then
                  Val (Val'First .. Val'First + VLen - 1) :=
                    V (V'First .. V'First + VLen - 1);
               end if;
            end;
         end if;
      end Lookup;

      --  Expand <name> references in Line into Out_Buf. `<` only
      --  opens a reference when immediately followed by `$` or
      --  an identifier start AND closed by `>` on the same line;
      --  anything else stays literal (so `< file` redirection
      --  and stray `<` pass through). Bad + a console message on
      --  an undefined reference or an overlong expansion.
      procedure Expand
        (Line    : String;
         Out_Buf : out String;
         Out_Len : out Natural;
         Bad     : out Boolean)
      is
         I : Natural := Line'First;

         procedure Put_Char (C : Character) is
         begin
            if Out_Len = Out_Buf'Length then
               Akernel_User.Console.Put_Line ("script line too long");
               Bad := True;
               return;
            end if;
            Out_Len := Out_Len + 1;
            Out_Buf (Out_Buf'First + Out_Len - 1) := C;
         end Put_Char;

         procedure Put_Str (S : String) is
         begin
            for C of S loop
               Put_Char (C);
               exit when Bad;
            end loop;
         end Put_Str;
      begin
         Out_Len := 0;
         Bad := False;
         while I <= Line'Last and then not Bad loop
            if Line (I) = '<' and then I < Line'Last
              and then (Line (I + 1) = '$'
                        or else Is_Ident_Start (Line (I + 1)))
            then
               declare
                  Env_Only : constant Boolean := Line (I + 1) = '$';
                  J        : constant Natural :=
                    I + 1 + (if Env_Only then 1 else 0);
                  K        : Natural;
               begin
                  if J <= Line'Last
                    and then Is_Ident_Start (Line (J))
                  then
                     K := J + 1;
                     while K <= Line'Last
                       and then Is_Ident (Line (K))
                     loop
                        K := K + 1;
                     end loop;
                     if K <= Line'Last and then Line (K) = '>' then
                        declare
                           Val : String (1 .. 256);
                           VL  : Natural;
                           Def : Boolean;
                        begin
                           Lookup (Line (J .. K - 1), Env_Only,
                                   Val, VL, Def);
                           if not Def then
                              Akernel_User.Console.Put_Line
                                ("bad substitution: <"
                                 & Line (J .. K - 1) & ">");
                              Bad := True;
                           else
                              Put_Str (Val (1 .. VL));
                           end if;
                        end;
                        I := K + 1;
                     else
                        Put_Char (Line (I));
                        I := I + 1;
                     end if;
                  else
                     Put_Char (Line (I));
                     I := I + 1;
                  end if;
               end;
            else
               Put_Char (Line (I));
               I := I + 1;
            end if;
         end loop;
      end Expand;

      --  .set name value — the value is the trimmed rest of the
      --  (already expanded) line; `.set name` alone clears the
      --  local to defined-empty.
      procedure Handle_Set (Rest : String; Bad : out Boolean) is
         W_Last  : Natural;
         R_First : Natural;
         VF      : Natural;
         VL      : Natural;
      begin
         Bad := False;
         if Rest'Length = 0 then
            Akernel_User.Console.Put_Line
              ("usage: .set <name> [value]");
            Bad := True;
            return;
         end if;
         Split_Cmd (Rest, W_Last, R_First);
         declare
            Name : constant String := Rest (Rest'First .. W_Last);
            Slot : Natural := Find_Local (Name);
         begin
            if Slot = 0 then
               Slot := Add_Local (Name);
               if Slot = 0 then
                  Bad := True;
                  return;
               end if;
            end if;
            if R_First > Rest'Last then
               if not Set_Value (Slot, "") then
                  Bad := True;
               end if;
            else
               Trim (Rest (R_First .. Rest'Last), VF, VL);
               if VL >= VF
                 and then not Set_Value (Slot, Rest (VF .. VL))
               then
                  Bad := True;
               elsif VL < VF
                 and then not Set_Value (Slot, "")
               then
                  Bad := True;
               end if;
            end if;
         end;
      end Handle_Set;

   begin
      if Depth > Max_Nest then
         Akernel_User.Console.Put_Line ("scripts nested too deep");
         return Akernel_User.CLI.RC_Error;
      end if;
      St := Akernel_User.Files.Open (Full, Size);
      if St /= Akernel_User.Files.Status_Ok then
         Akernel_User.Console.Put_Line ("can't open script " & Full);
         return Akernel_User.CLI.RC_Error;
      end if;
      if Size > Max_Script then
         Akernel_User.Console.Put_Line ("script too big " & Full);
         return Akernel_User.CLI.RC_Error;
      end if;
      Buf := new Byte_Array (0 .. (if Size = 0 then 0 else Size - 1));
      St := Akernel_User.Files.Read
        (Full, 0, Buf.all'Address, Size, Count);
      if St /= Akernel_User.Files.Status_Ok or else Count /= Size then
         Akernel_User.Console.Put_Line ("can't read script " & Full);
         Free (Buf);
         return Akernel_User.CLI.RC_Error;
      end if;

      declare
         Lo : U64 := 0;
         Hi : U64;
         LF : constant Byte := Byte (Character'Pos (ASCII.LF));
         CR : constant Byte := Byte (Character'Pos (ASCII.CR));
         In_Header : Boolean := True;
      begin
         while Lo < Size loop
            Hi := Lo;
            while Hi < Size and then Buf (Hi) /= LF loop
               Hi := Hi + 1;
            end loop;
            declare
               Last : U64 := Hi;
               Line : String (1 .. 256);
               Len  : Natural;
            begin
               if Last > Lo and then Buf (Last - 1) = CR then
                  Last := Last - 1;
               end if;
               Len := Natural (Last - Lo);
               --  Parity with the milestone-42 runner: a raw
               --  line over 256 bytes is silently skipped.
               if Len > 0 and then Len <= Line'Length then
                  for I in 0 .. Len - 1 loop
                     Line (I + 1) :=
                       Character'Val (Natural (Buf (Lo + U64 (I))));
                  end loop;
                  if Line (1) = ';' then
                     null;  --  comment (column 1 only)
                  else
                     declare
                        W_Last  : Natural;
                        R_First : Natural;
                        Bad     : Boolean;
                     begin
                        Split_Cmd (Line (1 .. Len), W_Last, R_First);
                        if In_Header
                          and then Line (1) = '.'
                          and then (Same_Word (Line (1 .. W_Last),
                                               ".key")
                                    or else
                                    Same_Word (Line (1 .. W_Last),
                                               ".k"))
                        then
                           Parse_Key
                             ((if R_First > Len then ""
                               else Line (R_First .. Len)), Bad);
                           if Bad then
                              RC := Akernel_User.CLI.RC_Error;
                           end if;
                        elsif In_Header
                          and then Line (1) = '.'
                          and then Same_Word (Line (1 .. W_Last),
                                              ".def")
                        then
                           Parse_Def
                             ((if R_First > Len then ""
                               else Line (R_First .. Len)), Bad);
                           if Bad then
                              RC := Akernel_User.CLI.RC_Error;
                           end if;
                        else
                           if In_Header and then not Bound then
                              Bind_Args (Bad);
                              if Bad then
                                 RC := Akernel_User.CLI.RC_Error;
                              end if;
                           end if;
                           In_Header := False;
                           if RC < Akernel_User.CLI.RC_Error then
                              declare
                                 XBuf : String (1 .. 512);
                                 XLen : Natural;
                              begin
                                 Expand (Line (1 .. Len),
                                         XBuf, XLen, Bad);
                                 if Bad then
                                    RC := Akernel_User.CLI.RC_Error;
                                 elsif XLen > 0 then
                                    Split_Cmd (XBuf (1 .. XLen),
                                               W_Last, R_First);
                                    if XBuf (1) = '.'
                                      and then Same_Word
                                        (XBuf (1 .. W_Last), ".set")
                                    then
                                       Handle_Set
                                         ((if R_First > XLen
                                           then ""
                                           else XBuf (R_First
                                                        .. XLen)),
                                          Bad);
                                       RC :=
                                         (if Bad
                                          then Akernel_User.CLI
                                            .RC_Error
                                          else 0);
                                    else
                                       RC := Run_Line
                                         (XBuf (1 .. XLen));
                                    end if;
                                 end if;
                              end;
                           end if;
                        end if;
                     end;
                  end if;
               end if;
            end;
            exit when RC >= Akernel_User.CLI.RC_Error;
            Lo := Hi + 1;
         end loop;
      end;
      Free (Buf);
      return RC;
   end Run;

end Scripting.Interp;
