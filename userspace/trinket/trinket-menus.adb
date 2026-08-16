with Interfaces;

package body Trinket.Menus is
   use type U64;

   function It
     (Id : U64; Label : String; Disabled : Boolean := False)
      return Item_Spec
   is
      R : Item_Spec;
   begin
      R.Id := Id;
      R.Disabled := Disabled;
      R.Label_Len := Natural'Min (Label'Length, Max_Label);
      R.Label (1 .. R.Label_Len) :=
        Label (Label'First .. Label'First + R.Label_Len - 1);
      return R;
   end It;

   function M (Title : String; Items : Item_Array) return Menu_Spec is
      R : Menu_Spec;
   begin
      R.Title_Len := Natural'Min (Title'Length, Max_Title);
      R.Title (1 .. R.Title_Len) :=
        Title (Title'First .. Title'First + R.Title_Len - 1);
      R.Count := Natural'Min (Items'Length, Max_Per_Menu);
      R.Items (1 .. R.Count) :=
        Items (Items'First .. Items'First + R.Count - 1);
      return R;
   end M;

   procedure Serialize (Menus : Menu_Array; Page : System.Address) is
      type Word_Array is array (U64 range 0 .. 511) of U64
        with Volatile_Components;
      P      : Word_Array with Address => Page;
      N      : Natural := 0;
      First  : array (1 .. Max_Menus) of Natural;

      procedure Put_Bytes
        (W_Idx : U64; S : String; Len : Natural) is
      begin
         for K in 0 .. Len - 1 loop
            P (W_Idx + U64 (K / 8)) := P (W_Idx + U64 (K / 8))
              or Interfaces.Shift_Left
                (U64 (Character'Pos (S (S'First + K))),
                 (K mod 8) * 8);
         end loop;
      end Put_Bytes;
   begin
      P := (others => 0);
      --  Total item count + per-menu first indices.
      for I in 1 .. Natural'Min (Menus'Length, Max_Menus)
      loop
         First (I) := N;
         N := N + Menus (Menus'First + I - 1).Count;
      end loop;
      if N > Max_Items then
         N := Max_Items;  --  clamp; Bureau bounds-checks too
      end if;
      P (0) := U64 (Natural'Min (Menus'Length, Max_Menus));
      P (1) := U64 (N);
      declare
         M_Count : constant Natural :=
           Natural'Min (Menus'Length, Max_Menus);
         W_Idx   : U64;
         Left    : Natural;
      begin
         for I in 1 .. M_Count loop
            W_Idx := 2 + U64 (I - 1) * 4;
            Put_Bytes (W_Idx,
                       Menus (Menus'First + I - 1).Title,
                       Menus (Menus'First + I - 1).Title_Len);
            P (W_Idx + 2) := U64 (First (I));
            --  Clamp the count against the total-items budget.
            Left := N - Natural'Min (First (I), N);
            P (W_Idx + 3) :=
              U64 (Natural'Min (Menus (Menus'First + I - 1).Count,
                                Left));
         end loop;
         declare
            It_Idx : Natural := 0;
         begin
            for I in 1 .. M_Count loop
               for J in 1 .. Menus (Menus'First + I - 1).Count loop
                  exit when It_Idx >= N;
                  W_Idx := 2 + U64 (M_Count) * 4 + U64 (It_Idx) * 4;
                  declare
                     It : Item_Spec renames
                       Menus (Menus'First + I - 1).Items (J);
                  begin
                     Put_Bytes (W_Idx, It.Label, It.Label_Len);
                     P (W_Idx + 3) :=
                       (It.Id and 16#FFFF_FFFF#)
                       or (if It.Disabled then 2 ** 32 else 0);
                  end;
                  It_Idx := It_Idx + 1;
               end loop;
            end loop;
         end;
      end;
   end Serialize;

end Trinket.Menus;
