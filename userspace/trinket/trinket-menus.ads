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

with System;

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
      --  Keyboard shortcut (milestone 9x): Shortcut = NUL means
      --  none. The character is matched against the seat key
      --  stream's translated character (case as typed — Shift is
      --  folded into it), optionally qualified by Ctrl and/or
      --  Alt. No-qualifier shortcuts fire on the bare key, so
      --  typing clients should prefer a qualified key.
      Shortcut      : Character := Character'Val (0);
      Shortcut_Ctrl : Boolean := False;
      Shortcut_Alt  : Boolean := False;
      --  A separator is a divider row: it has no Id and is never
      --  hovered, picked or accelerated.
      Is_Separator  : Boolean := False;
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

   --  Item with a keyboard shortcut (Id, Label, Shortcut
   --  character; qualifiers default off).
   function It
     (Id : U64; Label : String; Shortcut : Character;
      Ctrl : Boolean := False; Alt : Boolean := False;
      Disabled : Boolean := False)
      return Item_Spec;

   --  A divider row between items.
   function Sep return Item_Spec;

   function M (Title : String; Items : Item_Array) return Menu_Spec;

   --  Serialize the tree into the 4096-byte page at Page using
   --  the Op_Set_Menus wire layout (akernel_user-window.ads).
   --  Trinket.Window.Set_Menus is alloc/map/Serialize/mint/call;
   --  raw-protocol clients (terminal, demo) map their own page,
   --  Serialize, mint Map+Read+Transfer and call
   --  Akernel_User.Window.Surface_Set_Menus themselves.
   procedure Serialize (Menus : Menu_Array; Page : System.Address);

end Trinket.Menus;
