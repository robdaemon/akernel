--  Trinket menus (milestone 61): declarative menu-tree specs
--  for the Bureau screen bar. Menus are CHROME — Bureau renders
--  and operates them (Amiga screen-bar lineage, RMB opens, see
--  akernel_user-window.ads); a client only declares the tree
--  once (Trinket.Window.Set_Menus) and receives item picks as
--  Id callbacks (Trinket.Window.Set_Menu_Handler). This package
--  is pure declaration: serialization lives in Trinket.Window.
--
--     File_Menu : constant Trinket.Menus.Menu_Array :=
--       (1 => Trinket.Menus.M
--          ("File", (Trinket.Menus.It (1, "Save"),
--                    Trinket.Menus.It (2, "Quit"))));

package Trinket.Menus is

   Max_Menus  : constant := 8;
   Max_Items  : constant := 32;  --  total across all menus
   Max_Per_Menu : constant := 16;
   Max_Title  : constant := 16;  --  chars
   Max_Label  : constant := 24;  --  chars

   type Item_Spec is record
      Id       : U64 := 0;       --  echoed back on pick
      Label    : String (1 .. Max_Label) := (others => ' ');
      Label_Len : Natural := 0;
      Disabled : Boolean := False;  --  ghosted, unpickable
   end record;

   type Item_Array is array (Positive range <>) of Item_Spec;

   type Menu_Spec is record
      Title     : String (1 .. Max_Title) := (others => ' ');
      Title_Len : Natural := 0;
      Items     : Item_Array (1 .. Max_Per_Menu);
      Count     : Natural := 0;
   end record;

   type Menu_Array is array (Positive range <>) of Menu_Spec;

   function It
     (Id : U64; Label : String; Disabled : Boolean := False)
      return Item_Spec;

   function M (Title : String; Items : Item_Array) return Menu_Spec;

end Trinket.Menus;
