with Akernel_User.CLI;
with Akernel_User.Files;
with Akernel_User.Syscalls;
with Scripting.Exec;
with Trinket.Fonts;
with Trinket.Iconview;
with Trinket.Images;
with Trinket.Menus;
with Trinket.Widgets;
with Trinket.Widgets.Button;
with Trinket.Widgets.Label;
with Trinket.Window;

package body Drawer_App is
   use Akernel_User.Syscalls;
   use type Akernel_User.Syscalls.U64;
   package Widgets renames Trinket.Widgets;
   package IV renames Trinket.Iconview;
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   package Images renames Trinket.Images;

   Bureau_EP : constant U64 := 3;  --  uniform ABI handle

   Attr_CSTR : constant U64 := 16#4353_5452#;  --  'CSTR' fourcc

   Max_Entries : constant := 512;
   --  Sniff budget per load: every entry costs an Open+Read; a
   --  huge drawer must not stall the GUI on first paint
   --  (fileman's Max_Sniff reasoning).
   Max_Sniff   : constant := 64;

   Win_H : Trinket.Window.Window;

   --  Current drawer path (fully qualified, e.g. "Sys:System").
   Cur_Path : String (1 .. 255) := (others => ' ');
   Cur_Len  : Natural := 0;

   --  Entry metadata, parallel to the iconview's item order.
   type Entry_Rec is record
      Name    : String (1 .. 24) := (others => ' ');
      Len     : Natural := 0;
      Is_Dir  : Boolean := False;
      Is_Tool : Boolean := False;
   end record;
   Entries : array (1 .. Max_Entries) of Entry_Rec;
   N_Entries : Natural := 0;

   --  Icons: the 32x32 deficons, plus per-entry customs loaded
   --  through the ICON attribute (freed on every reload).
   Def_Drawer : aliased Images.Image;
   Def_File   : aliased Images.Image;
   Def_Tool   : aliased Images.Image;
   type Custom_Array is array (1 .. Max_Entries) of aliased Images.Image;
   Customs : Custom_Array;

   Icons    : IV.Any_Iconview;
   Path_Lab : Widgets.Any_Widget;

   function Cur return String is (Cur_Path (1 .. Cur_Len));

   procedure Load_Deficons is
      St : Images.Status;
   begin
      Images.Load ("Sys:System/Icons32/DRAWER.XPM", Def_Drawer, St);
      Images.Load ("Sys:System/Icons32/FILE.XPM", Def_File, St);
      Images.Load ("Sys:System/Icons32/TOOL.XPM", Def_Tool, St);
   end Load_Deficons;

   --  ELF magic decides tool vs plain file (fileman's rule).
   function Is_Elf (Path : String) return Boolean is
      Size  : U64 := 0;
      Count : U64 := 0;
      B4    : String (1 .. 4) := "    ";
      St    : U64;
   begin
      St := Files.Open (Path, Size);
      if St = Files.Status_Ok and then Size >= 4 then
         St := Files.Read (Path, 0, B4'Address, 4, Count);
      end if;
      return Count = 4
        and then B4 (1) = Character'Val (16#7F#)
        and then B4 (2 .. 4) = "ELF";
   end Is_Elf;

   --  The entry's ICON attribute (CSTR path to an XPM), "" when
   --  absent/unreadable.
   --  Attr reads cost a full path resolution each (~100 ms on
   --  FAT32). The FAT32 driver answers Bad_Args for attr ops
   --  (unknown op) — that means the VOLUME has no attribute
   --  support, so stop asking for the rest of the drawer.
   --  BeFS attr-less files answer Not_Found instead, which must
   --  NOT latch (the next file may carry an ICON). Reset on
   --  every navigation.
   No_Attrs : Boolean := False;

   function Icon_Attr (Path : String) return String is
      Buf   : String (1 .. 128) := (others => Character'Val (0));
      Count : U64 := 0;
      Size  : U64 := 0;
      Typ   : U64 := 0;
      St    : U64;
   begin
      if No_Attrs then
         return "";
      end if;
      St := Files.Attr_Read
        (Path, "ICON", Buf'Address, U64 (Buf'Length),
         Count, Size, Typ);
      if St = Files.Status_Bad_Args then
         No_Attrs := True;
         return "";
      elsif St /= Files.Status_Ok or else Count = 0 then
         return "";
      end if;
      declare
         Last : Natural := Natural (Count);
      begin
         if Last > Buf'Length then
            Last := Buf'Length;
         end if;
         --  CSTR attributes may carry a trailing NUL.
         if Buf (Last) = Character'Val (0) then
            Last := Last - 1;
         end if;
         if Last = 0 then
            return "";
         end if;
         return Buf (1 .. Last);
      end;
   end Icon_Attr;

   procedure Free_Customs is
   begin
      for I in 1 .. N_Entries loop
         Images.Free (Customs (I));
      end loop;
   end Free_Customs;

   --  One scan pass; Dirs_Only picks which half. Per-entry
   --  fault isolation: one odd path must never truncate the
   --  listing (fileman's a-directories burn).
   procedure Scan_Pass (Dirs_Only : Boolean; Sniffed : in out Natural) is
      Idx  : U64 := 0;
      E_Nm : String (1 .. 256);
      E_L  : Natural;
      E_D  : Boolean;
      E_S  : U64;
      St   : U64;
   begin
      --  Enumerate via Files.Read_Dir (M94): it returns each
      --  entry's is-directory flag and size for free, so no
      --  per-entry Stat is needed. (Ada.Directories.Kind routes
      --  through libc stat(), ~100 ms+ per call under boot load —
      --  the pre-open scan of Sys: root took ~3.7 s.) Per-entry
      --  fault isolation stays (fileman's a-directories burn).
      loop
         St := Files.Read_Dir (Cur, Idx, E_Nm, E_L, E_D, E_S);
         exit when St /= Files.Status_Ok;
         Idx := Idx + 1;
         begin
            if E_D = Dirs_Only and then N_Entries < Max_Entries then
               N_Entries := N_Entries + 1;
               declare
                  E         : Entry_Rec renames Entries (N_Entries);
                  Leaf      : constant String := E_Nm (1 .. E_L);
                  Full      : constant String :=
                    CLI.Join_Path (Cur, Leaf);
                  N         : constant Natural :=
                    Natural'Min (Leaf'Length, E.Name'Length);
                  Icon_Path : constant String :=
                    (if Sniffed <= Max_Sniff then Icon_Attr (Full)
                     else "");
                  ISt       : Images.Status;
               begin
                  E.Len := N;
                  if N > 0 then
                     E.Name (1 .. N) :=
                       Leaf (Leaf'First .. Leaf'First + N - 1);
                  end if;
                  E.Is_Dir := E_D;
                  E.Is_Tool := False;
                  if not E_D then
                     --  M94: sniff every file (budgeted). A file
                     --  with a custom ICON attr (the M93 GUI-app
                     --  attrs: Fileman/Terminal/Edit/Font/
                     --  Screenmode) must still be recognized as a
                     --  tool — the icon only picks the glyph, the
                     --  launch path follows Is_Tool.
                     if Sniffed < Max_Sniff then
                        Sniffed := Sniffed + 1;
                        E.Is_Tool := Is_Elf (Full);
                     end if;
                  end if;
                  if Icon_Path'Length > 0 then
                     Images.Load
                       (Icon_Path, Customs (N_Entries), ISt);
                  end if;
                  if Images.Loaded (Customs (N_Entries)) then
                     IV.Add_Item
                       (Icons.all, Leaf,
                        Customs (N_Entries)'Access);
                  elsif E_D then
                     IV.Add_Item
                       (Icons.all, Leaf, Def_Drawer'Access);
                  else
                     IV.Add_Item
                       (Icons.all, Leaf,
                        (if E.Is_Tool then Def_Tool'Access
                         else Def_File'Access));
                  end if;
               end;
            end if;
         exception
            when others =>
               null;   --  one odd entry, no icon cell
         end;
      end loop;
   end Scan_Pass;

   --  Geometry persistence: DRAWER:GEOM = "WxH" (content size)
   --  on the CURRENT drawer. Silent no-op where attributes do
   --  not exist (FAT32) — the exact same call is journaled on
   --  BeFS once M93 makes Sys: a BeFS volume.
   procedure Save_Geom (W, H : U64) is
      WI : constant String := U64'Image (W);
      HI : constant String := U64'Image (H);
      V  : constant String :=
        WI (WI'First + 1 .. WI'Last) & "x"
        & HI (HI'First + 1 .. HI'Last);
      Buf  : String (1 .. 16) := (others => ' ');
      St   : U64;
   begin
      if V'Length > Buf'Length then
         return;
      end if;
      Buf (1 .. V'Length) := V;
      St := Files.Attr_Write
        (Cur, "DRAWER:GEOM", Attr_CSTR, Buf'Address,
         U64 (V'Length));
      pragma Unreferenced (St);
   end Save_Geom;

   --  Saved geometry for Path, 0x0 when absent/unparseable.
   procedure Load_Geom (Path : String; W, H : out U64) is
      Buf   : String (1 .. 16) := (others => Character'Val (0));
      Count : U64 := 0;
      Size  : U64 := 0;
      Typ   : U64 := 0;
      St    : U64;
      X     : Natural := 0;
      Acc   : U64 := 0;
      W2    : U64 := 0;
   begin
      W := 0;
      H := 0;
      St := Files.Attr_Read
        (Path, "DRAWER:GEOM", Buf'Address, U64 (Buf'Length),
         Count, Size, Typ);
      if St /= Files.Status_Ok or else Count = 0 then
         return;
      end if;
      --  Parse "WxH" by hand (no Text_IO on this path).
      for I in 1 .. Natural (Count) loop
         exit when I > Buf'Length;
         if Buf (I) in '0' .. '9' then
            Acc := Acc * 10
              + U64 (Character'Pos (Buf (I)) - Character'Pos ('0'));
         elsif Buf (I) = 'x' and then X = 0 then
            X := I;
            W2 := Acc;
            Acc := 0;
         end if;
      end loop;
      if X > 0 and then W2 > 0 and then Acc > 0 then
         W := W2;
         H := Acc;
      end if;
   end Load_Geom;

   procedure Reload is
      Sniffed : Natural := 0;
   begin
      Free_Customs;
      N_Entries := 0;
      IV.Clear (Icons.all);
      --  Drawers first, then files: the Workbench order.
      Scan_Pass (Dirs_Only => True, Sniffed => Sniffed);
      Scan_Pass (Dirs_Only => False, Sniffed => Sniffed);
      Widgets.Label.Set_Text
        (Widgets.Label.Label (Path_Lab.all), Cur);
   end Reload;

   procedure Navigate (Path : String) is
   begin
      if Path'Length > Cur_Path'Length then
         return;
      end if;
      Cur_Len := Path'Length;
      Cur_Path (1 .. Cur_Len) := Path;
      No_Attrs := False;
      Reload;
   end Navigate;

   --  Parent drawer: cut the last component at the last '/'
   --  (or ':'); a volume root is its own parent. (Normalize_Path
   --  deliberately ignores TRAILING empty components — "c/" is
   --  c, not its parent — so the bare-"/" idiom is no help
   --  here.)
   function Parent_Of (Path : String) return String is
      Last : Natural := 0;
   begin
      for I in Path'Range loop
         if Path (I) = '/' or else Path (I) = ':' then
            Last := I;
         end if;
      end loop;
      if Last = 0 then
         return Path;
      elsif Path (Last) = ':' then
         return Path (Path'First .. Last);   --  keep the colon
      else
         return Path (Path'First .. Last - 1);  --  drop the '/'
      end if;
    end Parent_Of;

   procedure Parent_Clicked is
   begin
      Navigate (Parent_Of (Cur));
   end Parent_Clicked;

   procedure Entry_Opened (Index : Natural) is
      Proc : U64;
   begin
      if Index = 0 or else Index > N_Entries then
         return;
      end if;
      declare
         E : Entry_Rec renames Entries (Index);
         Full : constant String :=
           CLI.Join_Path (Cur, E.Name (1 .. E.Len));
      begin
         if E.Is_Dir then
            Navigate (Full);
         elsif E.Is_Tool then
            --  Launch with the full uniform ABI (Spawn_Cmd grants
            --  console/fs/bureau/args/libmgr/elevation). The child
            --  cap is parked, never reaped — the v1 launcher does
            --  not track children (kernel teardown reclaims).
            Proc := Scripting.Exec.Spawn_Cmd (Full, "", "", "");
         else
            Proc := Scripting.Exec.Spawn_Cmd
              ("Sys:System/Edit", Full, "", "");
         end if;
      end;
      pragma Unreferenced (Proc);
   end Entry_Opened;

   procedure On_Resize (New_W, New_H : U64) is
   begin
      Save_Geom (New_W, New_H);
   end On_Resize;

   procedure Menu_Picked (Id : U64) is
   begin
      if Id = 1 then
         Reload;               --  Refresh
      elsif Id = 2 then
         Parent_Clicked;
      end if;
   end Menu_Picked;

   procedure Main is
      Root   : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical);
      Top_Row : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
      Open_W : U64 := 480;
      Open_H : U64 := 320;
      GW, GH : U64;
      Time0  : constant U64 := Akernel_User.Syscalls.Read_Time;
   begin
      Trinket.Fonts.Init;
      Load_Deficons;
      Debug_Put_Line ("drawer: deficons done t="
                      & Akernel_User.Syscalls.U64'Image
                        (Akernel_User.Syscalls.Read_Time - Time0));

      declare
         A : constant String :=
           (if CLI.Arg_Count >= 1 then CLI.Argument (1) else "Sys:");
         P : constant String := CLI.Normalize_Path (A);
      begin
         if P'Length > Cur_Path'Length then
            Debug_Put_Line ("drawer: path too long");
            return;
         end if;
         Cur_Len := P'Length;
         Cur_Path (1 .. Cur_Len) := P;
      end;

      Load_Geom (Cur, GW, GH);
      if GW > 0 and then GH > 0 then
         Open_W := GW;
         Open_H := GH;
      end if;

      Path_Lab := Widgets.Label.New_Label (Cur);
      Widgets.Group (Top_Row.all).Add
        (Widgets.Button.New_Button ("Parent", Parent_Clicked'Access), 1);
      --  The path label takes the row's slack (big weight); the
      --  Parent button stays at its content width (weight 1 thin,
      --  MUI-style weights — a 1:1 split would balloon the button).
      Widgets.Group (Top_Row.all).Add (Path_Lab, 20);
      --  The icons view takes the window's vertical slack; the
      --  top row stays at content height. Group weights split
      --  only the EXTRA above the children's minimums, and the
      --  scrolled icons' Min_Size is one cell — at 1:1 the row
      --  was stretched to ~half the window, so the Parent button
      --  (the row fills its kids to full height) rendered as a
      --  half-window slab. Weight 20 (same ratio as the label
      --  inside the row) keeps the top row near its ~28 px
      --  content minimum even when the drawer is zoomed.
      Widgets.Group (Root.all).Add (Top_Row, 1);
      Widgets.Group (Root.all).Add
        (IV.New_Scrolled_Icons (Icons), 20);

      --  Scan BEFORE opening: the scan costs ~1-2 s of FAT path
      --  resolutions, and a black window that fills in late
      --  reads as broken. The window appears populated.
      Reload;
      Debug_Put_Line ("drawer: scan done t="
                      & Akernel_User.Syscalls.U64'Image
                        (Akernel_User.Syscalls.Read_Time - Time0));

      if Trinket.Window.Open
        (Win_H, Bureau_EP, Open_W, Open_H, "Drawer", Root)
      then
         Debug_Put_Line ("drawer: open done t="
                         & Akernel_User.Syscalls.U64'Image
                           (Akernel_User.Syscalls.Read_Time - Time0));
         Trinket.Window.Set_Menus
           (Win_H,
            (1 => Trinket.Menus.M
               ("Drawer", (Trinket.Menus.It (1, "Refresh"),
                           Trinket.Menus.It (2, "Parent")))));
         Trinket.Window.Set_Menu_Handler (Win_H, Menu_Picked'Access);
         Trinket.Window.Set_Resize_Handler (Win_H, On_Resize'Access);
         IV.Set_On_Double_Click (Icons.all, Entry_Opened'Access);
         Debug_Put_Line ("drawer online: " & Cur);
         Trinket.Window.Run (Win_H);
         Trinket.Window.Close (Win_H);
      else
         Debug_Put_Line ("drawer: window open failed");
      end if;
      Free_Customs;
   end Main;

end Drawer_App;
