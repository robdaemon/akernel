with Ada.Directories;
with Akernel_User.CLI;
with Akernel_User.Syscalls;
with Akernel_User.Theme;
with Trinket;
with Trinket.Fonts;
with Trinket.Listview;
with Trinket.Paint;
with Trinket.Widgets;
with Trinket.Widgets.Button;
with Trinket.Window;

package body Font_App is
   use Akernel_User.Syscalls;
   use type Akernel_User.Syscalls.U64;
   package Widgets renames Trinket.Widgets;
   package LV renames Trinket.Listview;
   package Fonts renames Trinket.Fonts;
   package Paint renames Trinket.Paint;
   package CLI renames Akernel_User.CLI;
   use type Trinket.Fonts.Handle;

   Win : Trinket.Window.Window;

   --  Font inventory, scanned from Sys:Fonts at startup. Cap 32:
   --  we ship 5 BDFs; the drawer is scanned live so a cap with
   --  6x headroom covers user additions (transient staging —
   --  the picker is short-lived).
   Max_Fonts : constant := 32;
   Max_Path  : constant := 64;

   type Font_Entry is record
      Path     : String (1 .. Max_Path) := (others => ' ');
      Path_Len : Natural := 0;
      Family   : String (1 .. Fonts.Max_Family) := (others => ' ');
      Fam_Len  : Natural := 0;
      Size     : Natural := 0;
   end record;

   Entries   : array (1 .. Max_Fonts) of Font_Entry;
   N_Entries : Natural := 0;
   N_Raw     : Natural := 0;   --  every directory entry seen

   --  Family rows index the entry carrying that family's name;
   --  size rows index their entry directly (Size_Map).
   Fam_Map  : array (1 .. Max_Fonts) of Natural := (others => 0);
   N_Fams   : Natural := 0;
   Size_Map : array (1 .. Max_Fonts) of Natural := (others => 0);
   N_Sizes  : Natural := 0;

   Fam_Lv  : LV.Any_Listview;
   Size_Lv : LV.Any_Listview;

   Cur       : Natural := 0;   --  entry index of the previewed font
   Cur_Path  : String (1 .. Max_Path) := (others => ' ');
   Cur_Len   : Natural := 0;

   --  Live preview: a sunken panel drawing two sample lines in
   --  the loaded preview font (a private Fonts.Handle — the
   --  global UI font is untouched).
   type Preview is new Widgets.Widget with record
      F : Fonts.Handle := Fonts.Null_Handle;
   end record;
   overriding procedure Draw (W : Preview; C : Trinket.Canvas);
   overriding procedure Min_Size (W : Preview; MW, MH : out U64);

   Sample_1 : constant String :=
     "The quick brown fox jumps over the lazy dog";
   Sample_2 : constant String :=
     "ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789";

   Worst_LH : U64 := 16;   --  largest PIXEL_SIZE seen + slack

   overriding procedure Draw (W : Preview; C : Trinket.Canvas) is
      use Akernel_User.Theme;
      LH : U64;
   begin
      Paint.Fill_Rect (C, W.X, W.Y, W.X + W.W, W.Y + W.H, Pane);
      Paint.Bevel2 (C, W.X, W.Y, W.X + W.W, W.Y + W.H,
                    Raised => False);
      if W.F /= Fonts.Null_Handle then
         LH := Fonts.Line_Height (W.F);
         Fonts.Draw_Text
           (C, W.F, W.X + 6, W.Y + 5, Sample_1, Text_Dark);
         Fonts.Draw_Text
           (C, W.F, W.X + 6, W.Y + 5 + LH, Sample_2, Text_Dark);
      end if;
   end Draw;

   overriding procedure Min_Size (W : Preview; MW, MH : out U64) is
      pragma Unreferenced (W);
   begin
      --  Reserve for the tallest scanned font so switching to a
      --  big font after Open never clips (content set after
      --  Open does not renegotiate).
      MW := 120;
      MH := 2 * Worst_LH + 10;
   end Min_Size;

   Pv : Widgets.Any_Widget;

   procedure Show_Font (E : Natural);
   procedure Rebuild_Sizes (Fam_Entry : Natural; Want : Natural);

   --  FAT stores uppercase; the configured path may be typed in
   --  any case.
   function Eq_IC (A, B : String) return Boolean is
      function Up (C : Character) return Character is
        (if C in 'a' .. 'z'
         then Character'Val (Character'Pos (C) - 32) else C);
   begin
      if A'Length /= B'Length then
         return False;
      end if;
      for I in A'Range loop
         if Up (A (I)) /= Up (B (B'First + I - A'First)) then
            return False;
         end if;
      end loop;
      return True;
   end Eq_IC;

   function Is_BDF (N : String) return Boolean is
     (N'Length > 4
      and then (N (N'Last - 3 .. N'Last) = ".BDF"
                or else N (N'Last - 3 .. N'Last) = ".bdf"));

   procedure Scan_Fonts is
      package Dirs renames Ada.Directories;
      Search : Dirs.Search_Type;
      Ent    : Dirs.Directory_Entry_Type;
   begin
      Dirs.Start_Search (Search, "Sys:Fonts", "*");
      while Dirs.More_Entries (Search) loop
         --  Per-entry isolation (fileman idiom): a bad entry
         --  must skip, never truncate the listing.
         begin
            Dirs.Get_Next_Entry (Search, Ent);
            N_Raw := N_Raw + 1;
            if Is_BDF (Dirs.Simple_Name (Ent))
              and then N_Entries < Max_Fonts
            then
               declare
                  Full : constant String :=
                    CLI.Join_Path ("Sys:Fonts", Dirs.Simple_Name (Ent));
                  E : Font_Entry renames Entries (N_Entries + 1);
                  OK : Boolean;
               begin
                  Fonts.Probe
                    (Full, E.Family, E.Fam_Len, E.Size, OK);
                  if OK and then Full'Length <= Max_Path then
                     E.Path (1 .. Full'Length) := Full;
                     E.Path_Len := Full'Length;
                     N_Entries := N_Entries + 1;
                     Worst_LH :=
                       U64'Max (Worst_LH, U64 (E.Size) + 4);
                  end if;
               end;
            end if;
         exception
            when others =>
               null;
         end;
      end loop;
      Dirs.End_Search (Search);
      Debug_Put_Line
        ("prefs/font: scanned" & Natural'Image (N_Entries)
         & " fonts," & Natural'Image (N_Raw) & " raw");
   end Scan_Fonts;

   procedure Build_Families is
      Found : Boolean;
   begin
      for E in 1 .. N_Entries loop
         Found := False;
         for R in 1 .. N_Fams loop
            if Entries (Fam_Map (R)).Family
                 (1 .. Entries (Fam_Map (R)).Fam_Len)
              = Entries (E).Family (1 .. Entries (E).Fam_Len)
            then
               Found := True;
               exit;
            end if;
         end loop;
         if not Found then
            N_Fams := N_Fams + 1;
            Fam_Map (N_Fams) := E;
            LV.Add_Item
              (Fam_Lv.all,
               Entries (E).Family (1 .. Entries (E).Fam_Len));
         end if;
      end loop;
   end Build_Families;

   --  Refill the size list with every entry of Fam_Entry's
   --  family, ascending by pixel size; select Want's row (an
   --  entry index, 0 = first row).
   procedure Rebuild_Sizes (Fam_Entry : Natural; Want : Natural) is
      Fam : constant String :=
        Entries (Fam_Entry).Family (1 .. Entries (Fam_Entry).Fam_Len);
      I     : Natural;
      Tmp   : Natural;
      Sel   : Natural := 0;
   begin
      LV.Clear (Size_Lv.all);
      N_Sizes := 0;
      for E in 1 .. N_Entries loop
         if Entries (E).Family (1 .. Entries (E).Fam_Len) = Fam then
            N_Sizes := N_Sizes + 1;
            Size_Map (N_Sizes) := E;
         end if;
      end loop;
      --  Insertion sort by size (a handful of entries).
      for A in 2 .. N_Sizes loop
         Tmp := Size_Map (A);
         I := A - 1;
         while I >= 1
           and then Entries (Size_Map (I)).Size > Entries (Tmp).Size
         loop
            Size_Map (I + 1) := Size_Map (I);
            I := I - 1;
         end loop;
         Size_Map (I + 1) := Tmp;
      end loop;
      for R in 1 .. N_Sizes loop
         declare
            Img : constant String :=
              Natural'Image (Entries (Size_Map (R)).Size);
         begin
            LV.Add_Item
              (Size_Lv.all, Img (Img'First + 1 .. Img'Last));
         end;
         if Size_Map (R) = Want then
            Sel := R;
         end if;
      end loop;
      if Sel = 0 and then N_Sizes > 0 then
         Sel := 1;
      end if;
      LV.Set_Selected (Size_Lv.all, Sel);
   end Rebuild_Sizes;

   procedure Family_Picked (Index : Natural) is
   begin
      if Index /= 0 then
         Rebuild_Sizes (Fam_Map (Index), Cur);
      end if;
   end Family_Picked;

   procedure Show_Font (E : Natural) is
      Pv_W : Preview renames Preview (Pv.all);
   begin
      Cur := E;
      Cur_Len := Entries (E).Path_Len;
      Cur_Path (1 .. Cur_Len) := Entries (E).Path (1 .. Cur_Len);
      Fonts.Unload (Pv_W.F);
      Pv_W.F := Fonts.Load (Cur_Path (1 .. Cur_Len));
      Pv.Dirty := True;
   end Show_Font;

   procedure Size_Picked (Index : Natural) is
   begin
      if Index /= 0 then
         Show_Font (Size_Map (Index));
      end if;
   end Size_Picked;

   procedure Okay_Clicked is
   begin
      if Cur_Len > 0 then
         declare
            St : constant U64 :=
              CLI.Set_Env ("Font", Cur_Path (1 .. Cur_Len));
            pragma Unreferenced (St);
         begin
            Debug_Put_Line
              ("prefs/font: font = " & Cur_Path (1 .. Cur_Len));
         end;
      end if;
      Trinket.Window.Request_Quit (Win);
   end Okay_Clicked;

   procedure Cancel_Clicked is
   begin
      Trinket.Window.Request_Quit (Win);
   end Cancel_Clicked;

   procedure Main is
      Root    : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical);
      Top_Row : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
      Btn_Row : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
      Env     : constant String := CLI.Get_Env ("Font");
      Current : constant String :=
        (if Env'Length > 0 then Env else "Sys:Fonts/font8x8p.bdf");
      Fam_Row : Natural := 0;
   begin
      Fonts.Init;
      Debug_Put_Line
        ("prefs/font: global from disk = "
         & Boolean'Image (Fonts.Loaded_From_Disk));
      Scan_Fonts;

      --  Preselect the currently configured font.
      Cur := 0;
      for E in 1 .. N_Entries loop
         if Eq_IC (Entries (E).Path (1 .. Entries (E).Path_Len),
                   Current)
         then
            Cur := E;
            exit;
         end if;
      end loop;
      if Cur = 0 and then N_Entries > 0 then
         Cur := 1;
      end if;

      Widgets.Group (Top_Row.all).Add
        (LV.New_Scrolled_List (Fam_Lv, Family_Picked'Access), 3);
      Widgets.Group (Top_Row.all).Add
        (LV.New_Scrolled_List (Size_Lv, Size_Picked'Access), 1);
      Widgets.Group (Root.all).Add (Top_Row, 4);

      Pv := new Preview;
      Widgets.Group (Root.all).Add (Pv, 1);

      Widgets.Group (Btn_Row.all).Add
        (Widgets.Button.New_Button ("Okay", Okay_Clicked'Access));
      Widgets.Group (Btn_Row.all).Add
        (Widgets.Button.New_Button ("Cancel", Cancel_Clicked'Access));
      Widgets.Group (Root.all).Add (Btn_Row, 1);

      Build_Families;
      if Cur /= 0 then
         for R in 1 .. N_Fams loop
            if Fam_Map (R) /= 0
              and then Entries (Fam_Map (R)).Family
                         (1 .. Entries (Fam_Map (R)).Fam_Len)
              = Entries (Cur).Family (1 .. Entries (Cur).Fam_Len)
            then
               Fam_Row := R;
               exit;
            end if;
         end loop;
      end if;

      if Trinket.Window.Open (Win, 3, 320, 260, "Font", Root) then
         --  Preselect AFTER layout: Set_Selected scrolls to make
         --  the row visible, and a zero-height listview (pre-open)
         --  reports Visible_Rows = 1 — selecting then parks Top at
         --  row 1 and hides the first family.
         if Fam_Row /= 0 then
            LV.Set_Selected (Fam_Lv.all, Fam_Row);
         end if;
         Debug_Put_Line ("prefs/font online");
         Trinket.Window.Run (Win);
         Trinket.Window.Close (Win);
      else
         Debug_Put_Line ("prefs/font: window open failed");
      end if;
   end Main;

end Font_App;
