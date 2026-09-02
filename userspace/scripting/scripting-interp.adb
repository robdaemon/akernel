with Interfaces;
with Ada.Unchecked_Deallocation;
with Akernel_User.Console;
with Akernel_User.Files;
with Akernel_User.CLI;
with Scripting.Exec;

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

   --  Case-insensitive lexicographic compare (for if gt/lt).
   function Lower_Less (A : String; B : String) return Boolean is
   begin
      for I in 0 .. Natural'Min (A'Length, B'Length) - 1 loop
         declare
            Ca : constant Character := Lower (A (A'First + I));
            Cb : constant Character := Lower (B (B'First + I));
         begin
            if Ca /= Cb then
               return Ca < Cb;
            end if;
         end;
      end loop;
      return A'Length < B'Length;
   end Lower_Less;

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

   --  Digits-only parse for failat/quit/if-val.
   function Parse_Nat (S : String; Ok : out Boolean) return Natural is
      N : Natural := 0;
   begin
      Ok := False;
      if S'Length = 0 then
         return 0;
      end if;
      for C of S loop
         if C not in '0' .. '9' or else N > 100_000 then
            return 0;
         end if;
         N := N * 10 + (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      Ok := True;
      return N;
   end Parse_Nat;

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
      type Local_Array is array (1 .. Max_Locals) of Local_Rec;
      type Locals_Access is access Local_Array;
      type Str_Access is access String;
      procedure Free_Locals is new Ada.Unchecked_Deallocation
        (Local_Array, Locals_Access);
      procedure Free_Str is new Ada.Unchecked_Deallocation
        (String, Str_Access);

      Locals   : Locals_Access;
      NLoc     : Natural := 0;
      Order    : array (1 .. Max_Locals) of Natural := (others => 0);
      Template : Natural := 0;
      Bound    : Boolean := False;

      --  Heap-resident line buffers (milestone 70 chunk 4): a
      --  nesting level's on-stack frame must stay small — five
      --  nested scripts times ~4 KiB of line buffers (plus the
      --  locals table) blew the 48 KiB process stack before the
      --  depth cap fired (store page fault at 0x6FFF_3FF8; that
      --  was the pre-M83 stack at 0x7000_0000 — M83's 256 KiB
      --  stack has headroom, but heap buffers stay regardless).
      --  Allocated after the slurp, freed on the way out;
      --  references use implicit dereference throughout.
      Line  : Str_Access;  --  raw scan line (256)
      XBuf  : Str_Access;  --  expanded line (512)
      LLine : Str_Access;  --  Find_Label's scan line (256)
      VBuf  : Str_Access;  --  Expand's lookup value (256)
      RBuf  : Str_Access;  --  ask reply (120)

      --  Control-flow state (chunk 3). If_Stack records whether
      --  each open if's CURRENT branch executes; Skip_Count is
      --  the number of frames currently skipping (executing iff
      --  zero). Cond is the Amiga condition flag (set by every
      --  if evaluation; ask joins it in chunk 4). Abort is an
      --  interpreter-level error that bypasses Fail_Max (a
      --  raised failat must not excuse a malformed script).
      Max_If     : constant := 8;
      If_Stack   : array (1 .. Max_If) of Boolean := (others => True);
      If_Depth   : Natural := 0;
      Skip_Count : Natural := 0;
      Cond       : Boolean := False;
      Fail_Max   : U64 := Akernel_User.CLI.RC_Error;
      Done       : Boolean := False;
      Abort_Run  : Boolean := False;
      Jumped     : Boolean := False;
      Jump_To    : U64 := 0;

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
                           VL  : Natural;
                           Def : Boolean;
                        begin
                           Lookup (Line (J .. K - 1), Env_Only,
                                   VBuf.all, VL, Def);
                           if not Def then
                              Akernel_User.Console.Put_Line
                                ("bad substitution: <"
                                 & Line (J .. K - 1) & ">");
                              Bad := True;
                           else
                              Put_Str (VBuf (1 .. VL));
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

      --  Push an if frame; Bad (+ message) past 8 deep.
      procedure Push_If (Taken : Boolean; Bad : out Boolean) is
      begin
         Bad := False;
         if If_Depth = Max_If then
            Akernel_User.Console.Put_Line ("if nested too deep (8)");
            Bad := True;
            return;
         end if;
         If_Depth := If_Depth + 1;
         If_Stack (If_Depth) := Taken;
         if not Taken then
            Skip_Count := Skip_Count + 1;
         end if;
      end Push_If;

      --  if [not] ... — Rest is the EXPANDED remainder after
      --  the if keyword. Forms: bare (test the condition flag),
      --  exists <path>, <a> <op> <b> [val], or a command line
      --  (true iff its RC < failat; the RC is consumed). Every
      --  evaluation stores into the condition flag.
      procedure Handle_If (Rest : String; Bad : out Boolean) is
         Invert  : Boolean := False;
         Result  : Boolean := False;
         S_First : Natural := Rest'First;
         WL      : Natural;
         RF      : Natural;
      begin
         Bad := False;
         if Rest'Length > 0 then
            Split_Cmd (Rest, WL, RF);
            if Same_Word (Rest (Rest'First .. WL), "not") then
               Invert := True;
               S_First := RF;
            end if;
         end if;
         if Rest'Length = 0 or else S_First > Rest'Last then
            --  Bare if / if not: the stored condition flag.
            Result := Cond;
         else
            declare
               S : constant String := Rest (S_First .. Rest'Last);
            begin
               Split_Cmd (S, WL, RF);
               declare
                  W1 : constant String := S (S'First .. WL);
                  R1 : constant String :=
                    (if RF > S'Last then "" else S (RF .. S'Last));
               begin
                  if Same_Word (W1, "exists") then
                     if R1'Length = 0 then
                        Akernel_User.Console.Put_Line
                          ("if exists what?");
                        Bad := True;
                        return;
                     end if;
                     declare
                        PF  : Natural;
                        PL  : Natural;
                        Sz  : U64 := 0;
                     begin
                        Trim (R1, PF, PL);
                        --  Stat answers directories too
                        --  (milestone 64), so exists is
                        --  Amiga-true for drawers.
                        Result := Akernel_User.Files.Stat
                          (Akernel_User.CLI.Resolve_Path
                             (R1 (PF .. PL)), Sz) =
                          Akernel_User.Files.Status_Ok;
                     end;
                  elsif R1'Length > 0 then
                     declare
                        WL2 : Natural;
                        RF2 : Natural;
                     begin
                        Split_Cmd (R1, WL2, RF2);
                        declare
                           Op : constant String :=
                             R1 (R1'First .. WL2);
                           R2 : constant String :=
                             (if RF2 > R1'Last then ""
                              else R1 (RF2 .. R1'Last));
                        begin
                           if Same_Word (Op, "eq")
                             or else Same_Word (Op, "ne")
                             or else Same_Word (Op, "gt")
                             or else Same_Word (Op, "ge")
                             or else Same_Word (Op, "lt")
                             or else Same_Word (Op, "le")
                           then
                              --  <a> <op> <b> [val]: b is the
                              --  trimmed remainder; a trailing
                              --  "val" keyword forces numeric.
                              declare
                                 BF : Natural;
                                 BL : Natural;
                                 WF : Natural;
                                 Numeric : Boolean := False;
                              begin
                                 Trim (R2, BF, BL);
                                 if BL < BF then
                                    Akernel_User.Console.Put_Line
                                      ("if: missing value after "
                                       & Op);
                                    Bad := True;
                                    return;
                                 end if;
                                 WF := BL;
                                 while WF > BF
                                   and then R2 (WF - 1) /= ' '
                                 loop
                                    WF := WF - 1;
                                 end loop;
                                 if WF > BF
                                   and then Same_Word
                                     (R2 (WF .. BL), "val")
                                 then
                                    Numeric := True;
                                    BL := WF - 1;
                                    while BL >= BF
                                      and then R2 (BL) = ' '
                                    loop
                                       BL := BL - 1;
                                    end loop;
                                    if BL < BF then
                                       Akernel_User.Console
                                         .Put_Line
                                         ("if: missing value after "
                                          & Op);
                                       Bad := True;
                                       return;
                                    end if;
                                 end if;
                                 if Numeric then
                                    declare
                                       OkA : Boolean;
                                       OkB : Boolean;
                                       NA  : constant Natural :=
                                         Parse_Nat (W1, OkA);
                                       NB  : constant Natural :=
                                         Parse_Nat
                                           (R2 (BF .. BL), OkB);
                                    begin
                                       if not OkA
                                         or else not OkB
                                       then
                                          Akernel_User.Console
                                            .Put_Line
                                            ("if: val needs"
                                             & " numbers");
                                          Bad := True;
                                          return;
                                       end if;
                                       if Same_Word (Op, "eq") then
                                          Result := NA = NB;
                                       elsif Same_Word (Op, "ne")
                                       then
                                          Result := NA /= NB;
                                       elsif Same_Word (Op, "gt")
                                       then
                                          Result := NA > NB;
                                       elsif Same_Word (Op, "ge")
                                       then
                                          Result := NA >= NB;
                                       elsif Same_Word (Op, "lt")
                                       then
                                          Result := NA < NB;
                                       else
                                          Result := NA <= NB;
                                       end if;
                                    end;
                                 else
                                    declare
                                       B : constant String :=
                                         R2 (BF .. BL);
                                    begin
                                       if Same_Word (Op, "eq") then
                                          Result :=
                                            Same_Word (W1, B);
                                       elsif Same_Word (Op, "ne")
                                       then
                                          Result :=
                                            not Same_Word (W1, B);
                                       elsif Same_Word (Op, "gt")
                                       then
                                          Result :=
                                            Lower_Less (B, W1);
                                       elsif Same_Word (Op, "ge")
                                       then
                                          Result :=
                                            not Lower_Less (W1, B);
                                       elsif Same_Word (Op, "lt")
                                       then
                                          Result :=
                                            Lower_Less (W1, B);
                                       else
                                          Result :=
                                            not Lower_Less (B, W1);
                                       end if;
                                    end;
                                 end if;
                              end;
                           else
                              --  Command form: run the subject
                              --  line; true iff RC < failat.
                              Result := Run_Line (S) < Fail_Max;
                           end if;
                        end;
                     end;
                  else
                     --  Single-word command form.
                     Result := Run_Line (S) < Fail_Max;
                  end if;
               end;
            end;
         end if;
         Result := Result xor Invert;
         Cond := Result;
         Push_If (Result, Bad);
      end Handle_If;

      procedure Handle_Else (Bad : out Boolean) is
      begin
         Bad := False;
         if If_Depth = 0 then
            Akernel_User.Console.Put_Line ("else without if");
            Bad := True;
            return;
         end if;
         if If_Stack (If_Depth) then
            If_Stack (If_Depth) := False;
            Skip_Count := Skip_Count + 1;
         else
            If_Stack (If_Depth) := True;
            Skip_Count := Skip_Count - 1;
         end if;
      end Handle_Else;

      procedure Handle_Endif (Bad : out Boolean) is
      begin
         Bad := False;
         if If_Depth = 0 then
            Akernel_User.Console.Put_Line ("endif without if");
            Bad := True;
            return;
         end if;
         if not If_Stack (If_Depth) then
            Skip_Count := Skip_Count - 1;
         end if;
         If_Depth := If_Depth - 1;
      end Handle_Endif;

      --  Scan the buffer line by line for `lab <Label>`
      --  (case-insensitive, comments ignored). Back searches
      --  [0, Cur_Lo), forward [Next_Lo, Size). Target returns
      --  the lab line's start (the lab itself runs as a no-op).
      procedure Find_Label
        (Label   : String;
         Back    : Boolean;
         Cur_Lo  : U64;
         Next_Lo : U64;
         Target  : out U64;
         Found   : out Boolean)
      is
         LF : constant Byte := Byte (Character'Pos (ASCII.LF));
         CR : constant Byte := Byte (Character'Pos (ASCII.CR));
         P : U64 := (if Back then 0 else Next_Lo);
         H : U64;
         Limit : constant U64 := (if Back then Cur_Lo else Size);
      begin
         Found := False;
         Target := 0;
         while P < Limit loop
            H := P;
            while H < Size and then Buf (H) /= LF loop
               H := H + 1;
            end loop;
            declare
               Last : U64 := H;
               Len  : Natural;
            begin
               if Last > P and then Buf (Last - 1) = CR then
                  Last := Last - 1;
               end if;
               Len := Natural (Last - P);
               if Len > 0 and then Len <= LLine.all'Length then
                  for I in 0 .. Len - 1 loop
                     LLine (I + 1) :=
                       Character'Val (Natural (Buf (P + U64 (I))));
                  end loop;
                  if LLine (1) /= ';' then
                     declare
                        WL : Natural;
                        RF : Natural;
                        LL : Natural;
                        XF : Natural;
                     begin
                        Split_Cmd (LLine (1 .. Len), WL, RF);
                        if Same_Word (LLine (1 .. WL), "lab")
                          and then RF <= Len
                        then
                           Split_Cmd (LLine (RF .. Len), LL, XF);
                           if Same_Word (LLine (RF .. LL), Label)
                           then
                              Found := True;
                              Target := P;
                              return;
                           end if;
                        end if;
                     end;
                  end if;
               end if;
            end;
            P := H + 1;
         end loop;
      end Find_Label;

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

      --  Everything big lives on the heap from here on (see the
      --  declarations); no early returns beyond this point so
      --  the frees at the end always run.
      Locals := new Local_Array;
      Line   := new String (1 .. 256);
      XBuf   := new String (1 .. 512);
      LLine  := new String (1 .. 256);
      VBuf   := new String (1 .. 256);
      RBuf   := new String (1 .. 120);

      declare
         Lo : U64 := 0;
         Hi : U64;
         LF : constant Byte := Byte (Character'Pos (ASCII.LF));
         CR : constant Byte := Byte (Character'Pos (ASCII.CR));
         In_Header : Boolean := True;
      begin
         while Lo < Size and then not Done and then not Abort_Run
         loop
            Hi := Lo;
            while Hi < Size and then Buf (Hi) /= LF loop
               Hi := Hi + 1;
            end loop;
            declare
               Last : U64 := Hi;
               Len  : Natural;
            begin
               if Last > Lo and then Buf (Last - 1) = CR then
                  Last := Last - 1;
               end if;
               Len := Natural (Last - Lo);
               --  Parity with the milestone-42 runner: a raw
               --  line over 256 bytes is silently skipped.
               if Len > 0 and then Len <= Line.all'Length then
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
                        Bad     : Boolean := False;
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
                        elsif In_Header
                          and then Line (1) = '.'
                          and then Same_Word (Line (1 .. W_Last),
                                              ".def")
                        then
                           Parse_Def
                             ((if R_First > Len then ""
                               else Line (R_First .. Len)), Bad);
                        elsif Same_Word (Line (1 .. W_Last), "if")
                          or else Same_Word (Line (1 .. W_Last),
                                             "else")
                          or else Same_Word (Line (1 .. W_Last),
                                             "endif")
                        then
                           --  if/else/endif are recognized on the
                           --  RAW first word even while skipping
                           --  (a skipped block's nested ifs must
                           --  still balance, and its lines are
                           --  never expanded).
                           if In_Header and then not Bound then
                              Bind_Args (Bad);
                           end if;
                           In_Header := False;
                           if not Bad then
                              if Same_Word (Line (1 .. W_Last),
                                            "else")
                              then
                                 Handle_Else (Bad);
                              elsif Same_Word (Line (1 .. W_Last),
                                               "endif")
                              then
                                 Handle_Endif (Bad);
                              elsif Skip_Count > 0 then
                                 --  Nested if inside a skipped
                                 --  block: push a dead frame, no
                                 --  evaluation, no expansion.
                                 Push_If (False, Bad);
                              else
                                 declare
                                    XLen : Natural;
                                    XW   : Natural;
                                    XR   : Natural;
                                 begin
                                    Expand (Line (1 .. Len),
                                            XBuf.all, XLen, Bad);
                                    if not Bad then
                                       Split_Cmd (XBuf (1 .. XLen),
                                                  XW, XR);
                                       Handle_If
                                         ((if XR > XLen then ""
                                           else XBuf (XR .. XLen)),
                                          Bad);
                                       if not Bad then
                                          --  The condition RC is
                                          --  consumed by if.
                                          RC := 0;
                                       end if;
                                    end if;
                                 end;
                              end if;
                           end if;
                        else
                           if In_Header and then not Bound then
                              Bind_Args (Bad);
                           end if;
                           In_Header := False;
                           if not Bad and then Skip_Count = 0 then
                              declare
                                 XLen : Natural;
                              begin
                                 Expand (Line (1 .. Len),
                                         XBuf.all, XLen, Bad);
                                 if not Bad and then XLen > 0 then
                                    declare
                                       XW : Natural;
                                       XR : Natural;
                                       XRest : Natural;
                                    begin
                                       Split_Cmd (XBuf (1 .. XLen),
                                                  XW, XR);
                                       XRest :=
                                         (if XR > XLen
                                          then XLen + 1 else XR);
                                       if XBuf (1) = '.'
                                         and then Same_Word
                                           (XBuf (1 .. XW), ".set")
                                       then
                                          Handle_Set
                                            ((if XRest > XLen
                                              then ""
                                              else XBuf (XRest
                                                           .. XLen)),
                                             Bad);
                                          if not Bad then
                                             RC := 0;
                                          end if;
                                       elsif Same_Word
                                         (XBuf (1 .. XW), "lab")
                                       then
                                          RC := 0;  --  no-op
                                       elsif Same_Word
                                         (XBuf (1 .. XW), "skip")
                                       then
                                          declare
                                             SRest : constant
                                               String :=
                                               (if XRest > XLen
                                                then ""
                                                else XBuf (XRest
                                                             .. XLen));
                                             SL    : Natural;
                                             SF    : Natural;
                                             BL    : Natural := 0;
                                             BF    : Natural := 0;
                                             Back  : Boolean :=
                                               False;
                                             Found : Boolean;
                                          begin
                                             if SRest'Length = 0
                                             then
                                                Akernel_User
                                                  .Console.Put_Line
                                                  ("usage: skip"
                                                   & " <label>"
                                                   & " [back]");
                                                Bad := True;
                                             else
                                                Split_Cmd
                                                  (SRest, SL, SF);
                                                if SF
                                                  <= SRest'Last
                                                then
                                                   Split_Cmd
                                                     (SRest
                                                        (SF ..
                                                         SRest'Last),
                                                      BL, BF);
                                                   if Same_Word
                                                     (SRest
                                                        (SF .. BL),
                                                      "back")
                                                   then
                                                      Back := True;
                                                   else
                                                      Akernel_User
                                                        .Console
                                                        .Put_Line
                                                        ("usage:"
                                                         & " skip"
                                                         & " <label>"
                                                         & " [back]");
                                                      Bad := True;
                                                   end if;
                                                end if;
                                                if not Bad then
                                                   Find_Label
                                                     (SRest
                                                        (SRest'First
                                                         .. SL),
                                                      Back,
                                                      Lo, Hi + 1,
                                                      Jump_To,
                                                      Found);
                                                   if Found then
                                                      --  Abandon
                                                      --  any open
                                                      --  if frames:
                                                      --  the loop
                                                      --  idiom
                                                      --  leaks one
                                                      --  per pass.
                                                      If_Depth := 0;
                                                      Skip_Count :=
                                                        0;
                                                      Jumped := True;
                                                      RC := 0;
                                                   else
                                                      Akernel_User
                                                        .Console
                                                        .Put_Line
                                                        ("label not"
                                                         & " found: "
                                                         & SRest
                                                           (SRest
                                                              'First
                                                            .. SL));
                                                      Bad := True;
                                                   end if;
                                                end if;
                                             end if;
                                          end;
                                       elsif Same_Word
                                         (XBuf (1 .. XW), "quit")
                                       then
                                          declare
                                             QRest : constant
                                               String :=
                                               (if XRest > XLen
                                                then ""
                                                else XBuf (XRest
                                                             .. XLen));
                                             Ok : Boolean;
                                             N  : Natural;
                                          begin
                                             if QRest'Length = 0
                                             then
                                                RC := 0;
                                                Done := True;
                                             else
                                                N := Parse_Nat
                                                  (QRest, Ok);
                                                if not Ok then
                                                   Akernel_User
                                                     .Console
                                                     .Put_Line
                                                     ("quit: bad"
                                                      & " return"
                                                      & " code");
                                                   Bad := True;
                                                else
                                                   RC := U64 (N);
                                                   Done := True;
                                                end if;
                                             end if;
                                          end;
                                       elsif Same_Word
                                         (XBuf (1 .. XW), "failat")
                                       then
                                          declare
                                             FRest : constant
                                               String :=
                                               (if XRest > XLen
                                                then ""
                                                else XBuf (XRest
                                                             .. XLen));
                                             Ok : Boolean;
                                             N  : Natural;
                                          begin
                                             N := Parse_Nat
                                               (FRest, Ok);
                                             if not Ok then
                                                Akernel_User
                                                  .Console.Put_Line
                                                  ("usage: failat"
                                                   & " <n>");
                                                Bad := True;
                                             else
                                                Fail_Max :=
                                                  U64 (N);
                                                RC := 0;
                                             end if;
                                          end;
                                       elsif Same_Word
                                         (XBuf (1 .. XW), "echo")
                                         and then not Scripting
                                           .Exec.Has_Metachar
                                             (XBuf (1 .. XLen))
                                       then
                                          declare
                                             Txt : constant
                                               String :=
                                               (if XRest > XLen
                                                then ""
                                                else XBuf (XRest
                                                             .. XLen));
                                             TL : Natural :=
                                               Txt'Last;
                                             WF : Natural;
                                             Noline : Boolean :=
                                               False;
                                          begin
                                             while TL >= Txt'First
                                               and then Txt (TL)
                                                 = ' '
                                             loop
                                                TL := TL - 1;
                                             end loop;
                                             WF := TL;
                                             while WF > Txt'First
                                               and then Txt (WF - 1)
                                                 /= ' '
                                             loop
                                                WF := WF - 1;
                                             end loop;
                                             if TL >= Txt'First
                                               and then WF
                                                 > Txt'First
                                               and then Same_Word
                                                 (Txt (WF .. TL),
                                                  "noline")
                                             then
                                                Noline := True;
                                                TL := WF - 1;
                                                while TL
                                                  >= Txt'First
                                                  and then Txt (TL)
                                                    = ' '
                                                loop
                                                   TL := TL - 1;
                                                end loop;
                                             end if;
                                             if Noline then
                                                Akernel_User.Console
                                                  .Put
                                                  (Txt
                                                     (Txt'First
                                                      .. TL));
                                             elsif TL
                                               >= Txt'First
                                             then
                                                Akernel_User.Console
                                                  .Put_Line
                                                  (Txt
                                                     (Txt'First
                                                      .. TL));
                                             else
                                                Akernel_User.Console
                                                  .Put_Line ("");
                                             end if;
                                             RC := 0;
                                          end;
                                       elsif Same_Word
                                         (XBuf (1 .. XW), "ask")
                                       then
                                          declare
                                             PText : constant
                                               String :=
                                               (if XRest > XLen
                                                then ""
                                                else XBuf (XRest
                                                             .. XLen));
                                             RL    : Natural;
                                          begin
                                             Ask_Line
                                               (PText, RBuf.all,
                                                RL);
                                             Cond := RL > 0
                                               and then
                                                 (RBuf (1) = 'y'
                                                  or else
                                                  RBuf (1) = 'Y');
                                             --  RC_Warn on "no":
                                             --  below the default
                                             --  failat, so the
                                             --  script continues.
                                             RC :=
                                               (if Cond then 0
                                                else Akernel_User
                                                  .CLI.RC_Warn);
                                          end;
                                       else
                                          RC := Run_Line
                                            (XBuf (1 .. XLen));
                                       end if;
                                    end;
                                 end if;
                              end;
                           end if;
                        end if;
                        if Bad then
                           RC := Akernel_User.CLI.RC_Error;
                           Abort_Run := True;
                        end if;
                     end;
                  end if;
               end if;
            end;
            if Jumped then
               Lo := Jump_To;
               Jumped := False;
            else
               Lo := Hi + 1;
            end if;
            exit when Done or else Abort_Run
              or else RC >= Fail_Max;
         end loop;
      end;
      --  An open if at end of script is a malformed script —
      --  AmigaDOS reports "ENDIF expected". A quit overrides
      --  (its RC is the script's answer).
      if not Abort_Run and then not Done and then If_Depth > 0 then
         Akernel_User.Console.Put_Line ("missing endif");
         RC := Akernel_User.CLI.RC_Error;
      end if;
      Free (Buf);
      Free_Locals (Locals);
      Free_Str (Line);
      Free_Str (XBuf);
      Free_Str (LLine);
      Free_Str (VBuf);
      Free_Str (RBuf);
      return RC;
   end Run;

end Scripting.Interp;
