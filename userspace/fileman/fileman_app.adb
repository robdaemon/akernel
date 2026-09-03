with Ada.Directories;
with System;
with System.Storage_Elements;
with Akernel_User.CLI;
with Akernel_User.Syscalls;
with Akernel_User.Files;
with Trinket;
with Trinket.Images;
with Trinket.Widgets;
with Trinket.Listview;
with Trinket.Window;
with Trinket.Menus;

package body Fileman_App is

   package CLI renames Akernel_User.CLI;
   package Dirs renames Ada.Directories;
   package Syscalls renames Akernel_User.Syscalls;
   package Files renames Akernel_User.Files;
   package Images renames Trinket.Images;

   use type Syscalls.U64;
   use type Trinket.U64;
   use type Dirs.File_Kind;

   --  Uniform program ABI for this Startup-spawned program.
   Console_EP : constant Syscalls.U64 := 1;
   FS_EP      : constant Syscalls.U64 := 2;
   Bureau_EP  : constant Syscalls.U64 := 3;
   --  Elevation handle 4 is granted but not used here.

   Win : Trinket.Window.Window;

   --  M84: Directory-Opus-style dual-pane lister. Each pane owns
   --  its current path, an editable path gadget above the list
   --  (Enter navigates that pane), the listview and its
   --  scrollbar. Clicking anywhere in a pane makes it ACTIVE;
   --  the button bar and the name field operate on the active
   --  pane. Copy/Move default to "selection -> other pane".
   type Pane_Rec is record
      Path       : access String := null;
      List       : Trinket.Listview.Any_Listview;
      Scroll     : Trinket.Widgets.Any_Widget;
      Path_Input : Trinket.Widgets.Any_Widget;
   end record;
   Panes  : array (1 .. 2) of Pane_Rec;
   Active : Positive := 1;

   Status_Label : Trinket.Widgets.Any_Widget;
   Name_Input   : Trinket.Widgets.Any_Widget;

   --  Deficons (milestone 64): Workbench-style default icons,
   --  XPM text assets loaded from Sys:System/Icons/ once at
   --  startup. The listview borrows them; they live as long as
   --  the app. Absent icons degrade to plain text rows.
   Drawer_Img : aliased Images.Image;
   File_Img   : aliased Images.Image;
   Tool_Img   : aliased Images.Image;

   --  Sniff the ELF magic to tell tools from projects; bounded
   --  so a giant directory never turns into an RPC storm.
   Max_Sniff : constant := 256;

   --  Root group with pane-aware key routing (M84). Both
   --  listviews consume the navigation keys and Group's reverse
   --  add-order walk would always steer them to ONE pane, so
   --  route explicitly: a focused Input first (it gates on
   --  Focused itself), then the active pane's list, then the
   --  other pane's list.
   type Root_Group is new Trinket.Widgets.Group with null record;
   overriding function On_Key
     (W : access Root_Group; Code : Trinket.U64) return Boolean;

   function On_Key
     (W : access Root_Group; Code : Trinket.U64) return Boolean
   is
      pragma Unreferenced (W);
      function Try_Input
        (Any : Trinket.Widgets.Any_Widget) return Boolean
      is
      begin
         return Trinket.Widgets.Is_Focused
                  (Trinket.Widgets.Input (Any.all))
           and then Any.On_Key (Code);
      end Try_Input;
   begin
      if Try_Input (Panes (1).Path_Input)
        or else Try_Input (Panes (2).Path_Input)
        or else Try_Input (Name_Input)
      then
         return True;
      end if;
      if Panes (Active).List.On_Key (Code) then
         return True;
      end if;
      return Panes (3 - Active).List.On_Key (Code);
   end On_Key;

   procedure Set_Status (S : String);
   procedure Set_Active (P : Positive);
   procedure Sync_Scrollbar (P : Positive);
   procedure Scroll_Moved_L (Pos : Trinket.U64);
   procedure Scroll_Moved_R (Pos : Trinket.U64);
   procedure Selection_Changed_L (Index : Natural);
   procedure Selection_Changed_R (Index : Natural);
   procedure Press_L;
   procedure Press_R;
   procedure Path_Commit_L;
   procedure Path_Commit_R;
   procedure Open_Clicked;
   procedure Parent_Clicked;
   procedure Copy_Clicked;
   procedure Move_Clicked;
   procedure Rename_Clicked;
   procedure Swap_Clicked;
   procedure Newdir_Clicked;
   procedure Delete_Clicked;
   procedure Quit_Clicked;
   procedure Menu_Picked (Id : Syscalls.U64);
   procedure Load_Directory (P : Positive; Path : String);
   procedure Reload (P : Positive);
   procedure Spawn_Edit (Path : String);

   procedure Set_Status (S : String) is
   begin
      Trinket.Widgets.Set_Text
        (Trinket.Widgets.Label (Status_Label.all), S);
   end Set_Status;

   --  Pane activation: click or selection in a pane makes it the
   --  button bar's target; the status line carries the marker.
   procedure Set_Active (P : Positive) is
   begin
      if P /= Active then
         Active := P;
         Set_Status
           ((if P = 1 then "Left pane active"
             else "Right pane active"));
      end if;
   end Set_Active;

   procedure Sync_Scrollbar (P : Positive) is
      Vis : constant Trinket.U64 :=
        Trinket.Listview.Visible_Rows (Panes (P).List.all);
      Max : constant Trinket.U64 :=
        Trinket.Listview.Max_Top (Panes (P).List.all);
      Top : constant Trinket.U64 :=
        Trinket.Listview.Top (Panes (P).List.all);
   begin
      Trinket.Widgets.Set_Range
        (Trinket.Widgets.Scrollbar (Panes (P).Scroll.all),
         0, Max, Vis);
      Trinket.Widgets.Set_Pos
        (Trinket.Widgets.Scrollbar (Panes (P).Scroll.all), Top);
   end Sync_Scrollbar;

   procedure Scroll_Moved_L (Pos : Trinket.U64) is
   begin
      Trinket.Listview.Set_Top (Panes (1).List.all, Pos);
   end Scroll_Moved_L;

   procedure Scroll_Moved_R (Pos : Trinket.U64) is
   begin
      Trinket.Listview.Set_Top (Panes (2).List.all, Pos);
   end Scroll_Moved_R;

   --  Selecting an entry activates its pane, pre-fills the name
   --  field (rename edits in place, Workbench style) and drops
   --  input focus so the arrows belong to the list again.
   procedure Selection_Changed (P : Positive; Index : Natural) is
   begin
      Set_Active (P);
      Trinket.Widgets.Set_Focused
        (Trinket.Widgets.Input (Panes (1).Path_Input.all), False);
      Trinket.Widgets.Set_Focused
        (Trinket.Widgets.Input (Panes (2).Path_Input.all), False);
      Trinket.Widgets.Set_Focused
        (Trinket.Widgets.Input (Name_Input.all), False);
      if Index > 0 then
         Trinket.Widgets.Set_Text
           (Trinket.Widgets.Input (Name_Input.all),
            Trinket.Listview.Get_Item (Panes (P).List.all, Index));
      end if;
      Sync_Scrollbar (P);
   end Selection_Changed;

   procedure Selection_Changed_L (Index : Natural) is
   begin
      Selection_Changed (1, Index);
   end Selection_Changed_L;

   procedure Selection_Changed_R (Index : Natural) is
   begin
      Selection_Changed (2, Index);
   end Selection_Changed_R;

   procedure Press_L is
   begin
      Set_Active (1);
   end Press_L;

   procedure Press_R is
   begin
      Set_Active (2);
   end Press_R;

   --  Full path of the selected entry in pane P, or "" when
   --  nothing is selected.
   function Selected_Full (P : Positive) return String is
      Idx : constant Natural :=
        Trinket.Listview.Selected (Panes (P).List.all);
   begin
      if Idx = 0 then
         return "";
      end if;
      return CLI.Join_Path
        (Panes (P).Path.all,
         Trinket.Listview.Get_Item (Panes (P).List.all, Idx));
   end Selected_Full;

   --  The name field as a path: qualified stays as typed, bare
   --  names resolve inside pane P's directory.
   function Field_Path (P : Positive) return String is
      T : constant String :=
        Trinket.Widgets.Get_Text
          (Trinket.Widgets.Input (Name_Input.all));
   begin
      if T'Length = 0 then
         return "";
      end if;
      for Ch of T loop
         if Ch = ':' then
            return T;
         end if;
      end loop;
      return CLI.Join_Path (Panes (P).Path.all, T);
   end Field_Path;

   --  Refresh pane P after a mutating action.
   procedure Reload (P : Positive) is
   begin
      Load_Directory (P, Panes (P).Path.all);
   end Reload;

   --  Path gadget commit: a ':' anywhere keeps the text
   --  qualified (volume switch included), a bare name resolves
   --  against the pane's own directory. Enter must name a
   --  drawer; anything else reverts the gadget.
   procedure Path_Commit (P : Positive) is
      T : constant String :=
        Trinket.Widgets.Get_Text
          (Trinket.Widgets.Input (Panes (P).Path_Input.all));
      Qualified : Boolean := False;
   begin
      if T'Length = 0 then
         Trinket.Widgets.Set_Text
           (Trinket.Widgets.Input (Panes (P).Path_Input.all),
            Panes (P).Path.all);
         return;
      end if;
      for Ch of T loop
         if Ch = ':' then
            Qualified := True;
         end if;
      end loop;
      declare
         Target : constant String :=
           CLI.Normalize_Path
             ((if Qualified then T
               else CLI.Join_Path (Panes (P).Path.all, T)));
      begin
         if Dirs.Exists (Target)
           and then Dirs.Kind (Target) = Dirs.Directory
         then
            Load_Directory (P, Target);
            Set_Active (P);
            --  Editing is done; arrows belong to the list.
            Trinket.Widgets.Set_Focused
              (Trinket.Widgets.Input (Panes (P).Path_Input.all),
               False);
         else
            Set_Status ("No such drawer");
            Trinket.Widgets.Set_Text
              (Trinket.Widgets.Input (Panes (P).Path_Input.all),
               Panes (P).Path.all);
         end if;
      exception
         when others =>
            Set_Status ("No such drawer");
            Trinket.Widgets.Set_Text
              (Trinket.Widgets.Input (Panes (P).Path_Input.all),
               Panes (P).Path.all);
      end;
   end Path_Commit;

   procedure Path_Commit_L is
   begin
      Path_Commit (1);
   end Path_Commit_L;

   procedure Path_Commit_R is
   begin
      Path_Commit (2);
   end Path_Commit_R;

   procedure Spawn_Edit (Path : String) is
      Stage_VA : constant Syscalls.U64 := 16#5E00_0000#;
      Image_Path : constant String := "BD0:System/Edit";
      Size    : Syscalls.U64 := 0;
      Pages   : Syscalls.U64;
      Off     : Syscalls.U64 := 0;
      Chunk   : Syscalls.U64;
      Count   : Syscalls.U64 := 0;
      Mem_Cap : Syscalls.U64;
      Proc_Cap : Syscalls.U64;
      Args_Cap : Syscalls.U64;
      Result  : Syscalls.U64;
      St      : Syscalls.U64;
   begin
      St := Files.Stat (Image_Path, Size);
      if St /= Files.Status_Ok or else Size = 0 then
         return;
      end if;

      Pages := (Size + 4095) / 4096;
      Mem_Cap := Syscalls.Mem_Alloc (Pages);
      if Mem_Cap = Syscalls.Syscall_Failed then
         return;
      end if;

      if Syscalls.Mem_Map (Syscalls.Address_Space_Cap, Mem_Cap,
                           Stage_VA, 0, Pages * 4096, 3) /= 0
      then
         Result := Syscalls.Cap_Delete (Mem_Cap);
         return;
      end if;

      St := Files.Open (Image_Path, Size);
      while St = Files.Status_Ok and then Off < Size loop
         Chunk := Syscalls.U64'Min (Size - Off, 32768);
         St := Files.Read
           (Image_Path, Off,
            System.Storage_Elements.To_Address
              (System.Storage_Elements.Integer_Address
                 (Stage_VA + Off)),
            Chunk, Count);
         exit when St /= Files.Status_Ok or else Count /= Chunk;
         Off := Off + Chunk;
      end loop;

      Result := Syscalls.Mem_Unmap
        (Syscalls.Address_Space_Cap, Stage_VA, Pages * 4096);

      if Off < Size then
         Result := Syscalls.Cap_Delete (Mem_Cap);
         return;
      end if;

      Args_Cap := Syscalls.Mem_Alloc (1);
      if Args_Cap = Syscalls.Syscall_Failed then
         Result := Syscalls.Cap_Delete (Mem_Cap);
         return;
      end if;

      if Syscalls.Mem_Map (Syscalls.Address_Space_Cap, Args_Cap,
                           Syscalls.Args_VA, 0, 4096, 3) = 0
      then
         declare
            Page : String (1 .. 4096)
              with Address => System.Storage_Elements.To_Address
                (System.Storage_Elements.Integer_Address
                   (Syscalls.Args_VA));
         begin
            Page := (others => Character'Val (0));
            Page (1 .. Path'Length) := Path;
         end;
         Result := Syscalls.Mem_Unmap
           (Syscalls.Address_Space_Cap, Syscalls.Args_VA, 4096);
      end if;

      Syscalls.Set_Grant (0, Console_EP, Syscalls.Right_Send, 0);
      Syscalls.Set_Grant (1, FS_EP, Syscalls.Right_Send, 0);
      Syscalls.Set_Grant (2, Bureau_EP, Syscalls.Right_Send, 0);
      Syscalls.Set_Grant (3, Args_Cap,
                          Syscalls.Right_Map + Syscalls.Right_Read, 0);
      Result := Syscalls.Spawn (Mem_Cap, 4, Proc_Cap);
      Result := Syscalls.Cap_Delete (Args_Cap);
      Result := Syscalls.Cap_Delete (Mem_Cap);
      pragma Unreferenced (Result);
   end Spawn_Edit;

   --  Directory rows with deficons: drawers get the drawer,
   --  ELF images the tool, everything else the plain file.
   procedure Load_Directory (P : Positive; Path : String) is
      Search : Dirs.Search_Type;
      Ent    : Dirs.Directory_Entry_Type;
      Sniffed : Natural := 0;
   begin
      Panes (P).Path := new String'(Path);
      Trinket.Widgets.Set_Text
        (Trinket.Widgets.Input (Panes (P).Path_Input.all), Path);
      Trinket.Listview.Clear (Panes (P).List.all);

      begin
         Dirs.Start_Search (Search, Path, "*");
         while Dirs.More_Entries (Search) loop
            --  Per-entry isolation covers Get_Next_Entry too: an
            --  entry whose attributes cannot be read must skip,
            --  never truncate (a-direct's cursor advances before
            --  it raises, so continuing is safe).
            begin
               Dirs.Get_Next_Entry (Search, Ent);
               Trinket.Listview.Add_Item
                 (Panes (P).List.all, Dirs.Simple_Name (Ent));
            --  Icon pick is PER-ENTRY fault-isolated: a path
            --  that upsets Ada.Directories must never truncate
            --  the listing (Full_Name did exactly that once —
            --  join Simple_Name ourselves, the Open_Clicked
            --  idiom).
            declare
               N    : constant Natural :=
                 Trinket.Listview.Item_Count (Panes (P).List.all);
               Full : constant String :=
                 CLI.Join_Path (Path, Dirs.Simple_Name (Ent));
            begin
               if Dirs.Kind (Full) = Dirs.Directory then
                  if Images.Loaded (Drawer_Img) then
                     Trinket.Listview.Set_Item_Icon
                       (Panes (P).List.all, N, Drawer_Img'Access);
                  end if;
               elsif Sniffed < Max_Sniff
                 and then Images.Loaded (File_Img)
               then
                  --  Tool vs project: the ELF magic decides.
                  Sniffed := Sniffed + 1;
                  declare
                     Size  : Syscalls.U64 := 0;
                     Count : Syscalls.U64 := 0;
                     B4    : String (1 .. 4) := "    ";
                     St    : Syscalls.U64;
                  begin
                     St := Files.Open (Full, Size);
                     if St = Files.Status_Ok and then Size >= 4 then
                        St := Files.Read
                          (Full, 0, B4'Address, 4, Count);
                     end if;
                     if Count = 4
                       and then B4 (1) = Character'Val (16#7F#)
                       and then B4 (2 .. 4) = "ELF"
                     then
                        if Images.Loaded (Tool_Img) then
                           Trinket.Listview.Set_Item_Icon
                             (Panes (P).List.all, N, Tool_Img'Access);
                        end if;
                     else
                        Trinket.Listview.Set_Item_Icon
                          (Panes (P).List.all, N, File_Img'Access);
                     end if;
                  end;
               end if;
            exception
               when others =>
                  null;   --  one odd entry, no icon
            end;
            exception
               when others =>
                  null;   --  one odd entry, no row
            end;
         end loop;
         Dirs.End_Search (Search);
      exception
         when Dirs.Name_Error | Dirs.Use_Error =>
            null;
      end;

      if Trinket.Listview.Item_Count (Panes (P).List.all) > 0 then
         Trinket.Listview.Set_Selected (Panes (P).List.all, 1);
      end if;
      Sync_Scrollbar (P);
   end Load_Directory;

   procedure Open_Clicked is
      Idx  : constant Natural :=
        Trinket.Listview.Selected (Panes (Active).List.all);
      Name : String :=
        Trinket.Listview.Get_Item (Panes (Active).List.all, Idx);
      Full : constant String :=
        CLI.Join_Path (Panes (Active).Path.all, Name);
   begin
      if Idx = 0 then
         return;
      end if;

      begin
         if Dirs.Exists (Full)
           and then Dirs.Kind (Full) = Dirs.Directory
         then
            Load_Directory (Active, CLI.Normalize_Path (Full));
         else
            Spawn_Edit (Full);
         end if;
      exception
         when Dirs.Name_Error | Dirs.Use_Error =>
            null;
      end;
   end Open_Clicked;

   procedure Parent_Clicked is
      Parent : constant String :=
        CLI.Normalize_Path
          (CLI.Join_Path (Panes (Active).Path.all, "/"));
   begin
      Load_Directory (Active, Parent);
   end Parent_Clicked;

   --  Destination of a Copy/Move: the name field when typed,
   --  else the OTHER pane's directory under the same simple
   --  name (the Dopus default).
   function Copy_Dest (Src : String) return String is
      Dst : constant String := Field_Path (Active);
   begin
      if Dst'Length > 0 then
         return Dst;
      end if;
      return CLI.Join_Path
        (Panes (3 - Active).Path.all, Dirs.Simple_Name (Src));
   end Copy_Dest;

   procedure Copy_Clicked is
      Src : constant String := Selected_Full (Active);
   begin
      if Src'Length = 0 then
         Set_Status ("Select first");
         return;
      end if;
      begin
         Dirs.Copy_File (Src, Copy_Dest (Src));
         Set_Status ("Copied");
         Reload (3 - Active);
         if Panes (3 - Active).Path.all = Panes (Active).Path.all then
            Reload (Active);
         end if;
      exception
         when others =>
            Set_Status ("Copy failed");
      end;
   end Copy_Clicked;

   --  Move: same-volume renames ride the fs rename op (drawers
   --  included); cross-volume falls back to copy + delete and
   --  is files-only.
   procedure Move_Clicked is
      Src : constant String := Selected_Full (Active);
   begin
      if Src'Length = 0 then
         Set_Status ("Select first");
         return;
      end if;
      declare
         Dst : constant String := Copy_Dest (Src);
      begin
         Dirs.Rename (Src, Dst);
         Set_Status ("Moved");
      exception
         when others =>
            if Dirs.Exists (Src)
              and then Dirs.Kind (Src) = Dirs.Directory
            then
               Set_Status ("Move failed (drawer)");
               return;
            end if;
            begin
               Dirs.Copy_File (Src, Dst);
               Dirs.Delete_File (Src);
               Set_Status ("Moved");
            exception
               when others =>
                  Set_Status ("Move failed");
                  return;
            end;
      end;
      Reload (1);
      Reload (2);
   end Move_Clicked;

   procedure Rename_Clicked is
      Src : constant String := Selected_Full (Active);
      Dst : constant String := Field_Path (Active);
   begin
      if Src'Length = 0 or else Dst'Length = 0 then
         Set_Status ("Select and name first");
         return;
      end if;
      begin
         Dirs.Rename (Src, Dst);
         Set_Status ("Renamed");
         Reload (Active);
      exception
         when others =>
            Set_Status ("Rename failed");
      end;
   end Rename_Clicked;

   --  Swap: exchange the panes' directories (the Dopus
   --  left<->right flip); selections reset with the reload.
   procedure Swap_Clicked is
      S1 : constant String := Panes (1).Path.all;
      S2 : constant String := Panes (2).Path.all;
   begin
      Load_Directory (1, S2);
      Load_Directory (2, S1);
      Set_Status ("Panes swapped");
   end Swap_Clicked;

   procedure Newdir_Clicked is
      Dst : constant String := Field_Path (Active);
   begin
      if Dst'Length = 0 then
         Set_Status ("Type a drawer name");
         return;
      end if;
      begin
         Dirs.Create_Directory (Dst);
         Set_Status ("Drawer created");
         Reload (Active);
      exception
         when others =>
            Set_Status ("New drawer failed");
      end;
   end Newdir_Clicked;

   procedure Delete_Clicked is
      Src : constant String := Selected_Full (Active);
   begin
      if Src'Length = 0 then
         Set_Status ("Select first");
         return;
      end if;
      begin
         if Dirs.Exists (Src)
           and then Dirs.Kind (Src) = Dirs.Directory
         then
            Dirs.Delete_Directory (Src);   --  empty drawers only
         else
            Dirs.Delete_File (Src);
         end if;
         Set_Status ("Deleted");
         Reload (Active);
      exception
         when others =>
            Set_Status ("Delete failed");
      end;
   end Delete_Clicked;

   procedure Quit_Clicked is
   begin
      Trinket.Window.Request_Quit (Win);
   end Quit_Clicked;

   --  Screen-bar menu (milestone 61): File mirrors the button
   --  bar (M84: all nine actions, one row).
   procedure Menu_Picked (Id : Syscalls.U64) is
   begin
      if Id = 1 then
         Open_Clicked;
      elsif Id = 2 then
         Parent_Clicked;
      elsif Id = 3 then
         Copy_Clicked;
      elsif Id = 4 then
         Move_Clicked;
      elsif Id = 5 then
         Rename_Clicked;
      elsif Id = 6 then
         Swap_Clicked;
      elsif Id = 7 then
         Newdir_Clicked;
      elsif Id = 8 then
         Delete_Clicked;
      elsif Id = 9 then
         Quit_Clicked;
      end if;
   end Menu_Picked;

   procedure Main is
      Root : constant Trinket.Widgets.Any_Widget := new Root_Group'
        (X => 0, Y => 0, W => 0, H => 0, Dirty => True,
         Dir       => Trinket.Widgets.Vertical,
         Title     => "File Manager            ",
         Title_Len => 12,
         Inset     => False,
         Kids      => (others => null),
         Wts       => (others => 1),
         N         => 0);
      Panes_Row : constant Trinket.Widgets.Any_Widget :=
        Trinket.Widgets.New_Group (Trinket.Widgets.Horizontal);
      Btn_Row : constant Trinket.Widgets.Any_Widget :=
        Trinket.Widgets.New_Group (Trinket.Widgets.Horizontal);
      ISt : Images.Status;
   begin
      CLI.Init;
      Files.Bind (FS_EP);
      Panes (1).Path := new String'(CLI.Get_Cwd);
      Panes (2).Path := new String'(CLI.Boot_Volume);

      --  Deficons: Sys:System/Icons/*.xpm; any failure just
      --  leaves the rows icon-less.
      Images.Load ("BD0:System/Icons/DEFDRAW.XPM", Drawer_Img, ISt);
      Images.Load ("BD0:System/Icons/DEFFILE.XPM", File_Img, ISt);
      Images.Load ("BD0:System/Icons/DEFTOOL.XPM", Tool_Img, ISt);

      --  Per pane: path gadget on top, list+scrollbar below.
      for P in 1 .. 2 loop
         declare
            Pane_Grp : constant Trinket.Widgets.Any_Widget :=
              Trinket.Widgets.New_Group (Trinket.Widgets.Vertical);
            Mid : constant Trinket.Widgets.Any_Widget :=
              Trinket.Widgets.New_Group (Trinket.Widgets.Horizontal);
         begin
            Panes (P).Path_Input := Trinket.Widgets.New_Input;
            if P = 1 then
               Trinket.Widgets.Input
                 (Panes (P).Path_Input.all).On_Commit :=
                   Path_Commit_L'Access;
               Panes (P).List := Trinket.Listview.New_Listview
                 (Selection_Changed_L'Access);
               Trinket.Listview.Set_On_Press
                 (Panes (P).List.all, Press_L'Access);
               Panes (P).Scroll :=
                 Trinket.Widgets.New_Scrollbar (Scroll_Moved_L'Access);
            else
               Trinket.Widgets.Input
                 (Panes (P).Path_Input.all).On_Commit :=
                   Path_Commit_R'Access;
               Panes (P).List := Trinket.Listview.New_Listview
                 (Selection_Changed_R'Access);
               Trinket.Listview.Set_On_Press
                 (Panes (P).List.all, Press_R'Access);
               Panes (P).Scroll :=
                 Trinket.Widgets.New_Scrollbar (Scroll_Moved_R'Access);
            end if;
            Trinket.Widgets.Group (Mid.all).Add
              (Trinket.Widgets.Any_Widget (Panes (P).List));
            Trinket.Widgets.Group (Mid.all).Add (Panes (P).Scroll);
            Trinket.Widgets.Group (Pane_Grp.all).Add
              (Panes (P).Path_Input);
            Trinket.Widgets.Group (Pane_Grp.all).Add (Mid, 6);
            Trinket.Widgets.Group (Panes_Row.all).Add (Pane_Grp);
         end;
      end loop;

      Name_Input := Trinket.Widgets.New_Input;
      Status_Label := Trinket.Widgets.New_Label ("", Inset => True);

      --  Weights (MUI lineage): the panes take the bulk of the
      --  window; field/buttons/status split the rest evenly.
      --  Buttons: nine at weight 1 = equal width (Dopus bar).
      Trinket.Widgets.Group (Root.all).Add (Panes_Row, 6);
      Trinket.Widgets.Group (Root.all).Add (Name_Input);
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Open", Open_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Parent", Parent_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Copy", Copy_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Move", Move_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Rename", Rename_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Swap", Swap_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button
           ("New Drawer", Newdir_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Delete", Delete_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Quit", Quit_Clicked'Access));
      Trinket.Widgets.Group (Root.all).Add (Btn_Row);
      Trinket.Widgets.Group (Root.all).Add (Status_Label);

      if Trinket.Window.Open
        (Win, Bureau_EP, 720, 440, "File Manager", Root)
      then
         Trinket.Window.Set_Menus
           (Win,
            (1 => Trinket.Menus.M
               ("File", (Trinket.Menus.It (1, "Open"),
                         Trinket.Menus.It (2, "Parent"),
                         Trinket.Menus.It (3, "Copy"),
                         Trinket.Menus.It (4, "Move"),
                         Trinket.Menus.It (5, "Rename"),
                         Trinket.Menus.It (6, "Swap"),
                         Trinket.Menus.It (7, "New Drawer"),
                         Trinket.Menus.It (8, "Delete"),
                         Trinket.Menus.It (9, "Quit")))));
         Trinket.Window.Set_Menu_Handler (Win, Menu_Picked'Access);
         Load_Directory (1, Panes (1).Path.all);
         Load_Directory (2, Panes (2).Path.all);
         --  The initial loads' auto-selections fire the pane-
         --  activation callbacks; the left pane starts active.
         Active := 1;
         Set_Status ("Left pane active");
         Trinket.Window.Run (Win);
         Trinket.Window.Close (Win);
      end if;
   end Main;

end Fileman_App;
