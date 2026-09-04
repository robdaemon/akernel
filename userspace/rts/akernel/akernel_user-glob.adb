package body Akernel_User.Glob is

   function Up (C : Character) return Character is
     (if C in 'a' .. 'z'
      then Character'Val (Character'Pos (C) - 32) else C);

   function Is_Special (C : Character) return Boolean is
     (C = '?' or C = '*' or C = '%' or C = '#' or C = '('
      or C = ')' or C = '|' or C = '~' or C = ''');

   ------------------------------------------------------------------

   function Is_Pattern (Pattern : String) return Boolean is
   begin
      for C of Pattern loop
         if Is_Special (C) then
            return True;
         end if;
      end loop;
      return False;
   end Is_Pattern;

   ------------------------------------------------------------------
   --  MS: match pattern slice P (Pi .. Pe) against EXACTLY the
   --  string slice S (Si .. Se) — anchored at both ends.  Pe <
   --  Pi denotes an empty pattern slice, Se < Si an empty string
   --  slice (callers pass S'First - 1 as Se for an empty Name, so
   --  empty slices occur at any position).

   function MS
     (P : String; Pi, Pe : Natural;
      S : String; Si, Se : Natural) return Boolean;

   --  Index of the ')' closing the '(' at Open, honouring
   --  escapes; groups do not nest.  Returns 0 when unterminated.
   function Group_End (P : String; Open, Pe : Natural) return Natural is
      I : Natural := Open + 1;
   begin
      while I <= Pe loop
         if P (I) = ''' and I < Pe then
            I := I + 2;
         elsif P (I) = ')' then
            return I;
         else
            I := I + 1;
         end if;
      end loop;
      return 0;
   end Group_End;

   --  Match the group alternatives inside P (Open .. Close)
   --  (Open at '(', Close at ')') against exactly S (Si .. Se).
   function Group_Match
     (P : String; Open, Close : Natural;
      S : String; Si, Se : Natural) return Boolean
   is
      Alt : Natural := Open + 1;
      I   : Natural := Open + 1;
   begin
      while I <= Close loop
         if I = Close or else P (I) = '|' then
            if MS (P, Alt, I - 1, S, Si, Se) then
               return True;
            end if;
            Alt := I + 1;
         elsif P (I) = ''' and I + 1 < Close then
            I := I + 1;  --  escaped char: never a delimiter
         end if;
         I := I + 1;
      end loop;
      return False;
   end Group_Match;

   --  One repetition of the '#' item starting at P (Item)
   --  against exactly S (Si .. Se).
   function Item_Match
     (P : String; Item, Pe : Natural;
      S : String; Si, Se : Natural) return Boolean
   is
   begin
      if Item > Pe then
         return False;
      end if;
      case P (Item) is
         when '(' =>
            declare
               Close : constant Natural := Group_End (P, Item, Pe);
            begin
               return Close /= 0
                 and then Group_Match (P, Item, Close, S, Si, Se);
            end;
         when ''' =>
            return Item + 1 <= Pe and then Si = Se
              and then Up (S (Si)) = Up (P (Item + 1));
         when '?' =>
            return Si = Se;
         when '%' =>
            return Si > Se;
         when others =>
            return Si = Se
              and then Up (S (Si)) = Up (P (Item));
      end case;
   end Item_Match;

   function MS
     (P : String; Pi, Pe : Natural;
      S : String; Si, Se : Natural) return Boolean
   is
   begin
      if Pi > Pe then
         return Si > Se;
      end if;
      case P (Pi) is
         when ''' =>
            --  Escape: the next char is literal.
            return Pi < Pe
              and then Si <= Se
              and then Up (S (Si)) = Up (P (Pi + 1))
              and then MS (P, Pi + 2, Pe, S, Si + 1, Se);
         when '?' =>
            return Si <= Se
              and then MS (P, Pi + 1, Pe, S, Si + 1, Se);
         when '%' =>
            return MS (P, Pi + 1, Pe, S, Si, Se);
         when '~' =>
            --  Negates the rest of the pattern at this level.
            return not MS (P, Pi + 1, Pe, S, Si, Se);
         when '(' =>
            declare
               Close : constant Natural := Group_End (P, Pi, Pe);
            begin
               if Close = 0 then
                  return False;  --  unterminated: never matches
               end if;
               --  The group may consume any prefix of the
               --  remaining string; try every split.
               for K in Si .. Se + 1 loop
                  if Group_Match (P, Pi, Close, S, Si, K - 1)
                    and then MS (P, Close + 1, Pe, S, K, Se)
                  then
                     return True;
                  end if;
               end loop;
               return False;
            end;
         when '*' =>
            --  Shorthand for #?: zero chars, or any char and *.
            return MS (P, Pi + 1, Pe, S, Si, Se)
              or else (Si <= Se
                       and then MS (P, Pi, Pe, S, Si + 1, Se));
         when '#' =>
            --  Zero or more of the item at Pi + 1.
            declare
               After : Natural;  --  first index past the item
            begin
               if Pi + 1 > Pe then
                  return False;  --  '#' with no item
               elsif P (Pi + 1) = '(' then
                  declare
                     Close : constant Natural :=
                       Group_End (P, Pi + 1, Pe);
                  begin
                     if Close = 0 then
                        return False;
                     end if;
                     After := Close + 1;
                  end;
               elsif P (Pi + 1) = ''' then
                  After := Pi + 3;
               else
                  After := Pi + 2;
               end if;
               --  Zero repetitions:
               if MS (P, After, Pe, S, Si, Se) then
                  return True;
               end if;
               --  One repetition, then repeat.  Only groups
               --  consume a variable number of chars; every
               --  other item consumes exactly one ('%' consumes
               --  zero and is covered by the zero case above).
               for K in Si + 1 .. Se + 1 loop
                  exit when P (Pi + 1) /= '(' and then K > Si + 1;
                  if Item_Match (P, Pi + 1, Pe, S, Si, K - 1)
                    and then MS (P, Pi, Pe, S, K, Se)
                  then
                     return True;
                  end if;
               end loop;
               return False;
            end;
         when others =>
            return Si <= Se
              and then Up (S (Si)) = Up (P (Pi))
              and then MS (P, Pi + 1, Pe, S, Si + 1, Se);
      end case;
   end MS;

   ------------------------------------------------------------------

   function Match (Pattern, Name : String) return Boolean is
   begin
      if Pattern'Length = 0 then
         return Name'Length = 0;
      end if;
      return MS (Pattern, Pattern'First, Pattern'Last,
                 Name, Name'First, Name'Last);
   end Match;

end Akernel_User.Glob;
