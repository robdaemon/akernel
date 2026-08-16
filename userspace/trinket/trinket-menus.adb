package body Trinket.Menus is

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

end Trinket.Menus;
