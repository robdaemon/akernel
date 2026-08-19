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

   Current_Path  : access String := null;
   List_Widget   : Trinket.Listview.Any_Listview;
   Scroll_Widget : Trinket.Widgets.Any_Widget;
   Path_Label    : Trinket.Widgets.Any_Widget;
   Status_Label  : Trinket.Widgets.Any_Widget;
   Name_Input    : Trinket.Widgets.Any_Widget;

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

   procedure Sync_Scrollbar;
   procedure Scroll_Moved (Pos : Trinket.U64);
   procedure Selection_Changed (Index : Natural);
   procedure Open_Clicked;
   procedure Parent_Clicked;
   procedure Rename_Clicked;
   procedure Copy_Clicked;
   procedure Newdir_Clicked;
   procedure Delete_Clicked;
   procedure Quit_Clicked;
   procedure Menu_Picked (Id : Syscalls.U64);
   procedure Load_Directory (P : String);
   procedure Spawn_Edit (Path : String);

   procedure Sync_Scrollbar is
      Vis : constant Trinket.U64 :=
        Trinket.Listview.Visible_Rows (List_Widget.all);
      Max : constant Trinket.U64 :=
        Trinket.Listview.Max_Top (List_Widget.all);
      Top : constant Trinket.U64 :=
        Trinket.Listview.Top (List_Widget.all);
   begin
      Trinket.Widgets.Set_Range
        (Trinket.Widgets.Scrollbar (Scroll_Widget.all), 0, Max, Vis);
      Trinket.Widgets.Set_Pos
        (Trinket.Widgets.Scrollbar (Scroll_Widget.all), Top);
   end Sync_Scrollbar;

   procedure Scroll_Moved (Pos : Trinket.U64) is
   begin
      Trinket.Listview.Set_Top (List_Widget.all, Pos);
   end Scroll_Moved;

   --  Selecting an entry pre-fills the name field (rename edits
   --  in place, Workbench style) and hands key focus to the
   --  list.
   procedure Selection_Changed (Index : Natural) is
   begin
      Trinket.Widgets.Set_Focused
        (Trinket.Widgets.Input (Name_Input.all), False);
      if Index > 0 then
         Trinket.Widgets.Set_Text
           (Trinket.Widgets.Input (Name_Input.all),
            Trinket.Listview.Get_Item (List_Widget.all, Index));
      end if;
      Sync_Scrollbar;
   end Selection_Changed;

   procedure Set_Status (S : String) is
   begin
      Trinket.Widgets.Set_Text
        (Trinket.Widgets.Label (Status_Label.all), S);
   end Set_Status;

   --  Full path of the selected entry, or "" when nothing is
   --  selected.
   function Selected_Full return String is
      Idx : constant Natural :=
        Trinket.Listview.Selected (List_Widget.all);
   begin
      if Idx = 0 then
         return "";
      end if;
      return CLI.Join_Path
        (Current_Path.all,
         Trinket.Listview.Get_Item (List_Widget.all, Idx));
   end Selected_Full;

   --  The name field as a path: qualified stays as typed, bare
   --  names resolve inside the current directory.
   function Field_Path return String is
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
      return CLI.Join_Path (Current_Path.all, T);
   end Field_Path;

   --  Refresh after a mutating action.
   procedure Reload is
   begin
      Load_Directory (Current_Path.all);
   end Reload;

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
   procedure Load_Directory (P : String) is
      Search : Dirs.Search_Type;
      Ent    : Dirs.Directory_Entry_Type;
      Sniffed : Natural := 0;
   begin
      Current_Path := new String'(P);
      Trinket.Widgets.Set_Text
        (Trinket.Widgets.Label (Path_Label.all), P);
      Trinket.Listview.Clear (List_Widget.all);

      begin
         Dirs.Start_Search (Search, P, "*");
         while Dirs.More_Entries (Search) loop
            --  Per-entry isolation covers Get_Next_Entry too: an
            --  entry whose attributes cannot be read must skip,
            --  never truncate (a-direct's cursor advances before
            --  it raises, so continuing is safe).
            begin
               Dirs.Get_Next_Entry (Search, Ent);
               Trinket.Listview.Add_Item
                 (List_Widget.all, Dirs.Simple_Name (Ent));
            --  Icon pick is PER-ENTRY fault-isolated: a path
            --  that upsets Ada.Directories must never truncate
            --  the listing (Full_Name did exactly that once —
            --  join Simple_Name ourselves, the Open_Clicked
            --  idiom).
            declare
               N    : constant Natural :=
                 Trinket.Listview.Item_Count (List_Widget.all);
               Full : constant String :=
                 CLI.Join_Path (P, Dirs.Simple_Name (Ent));
            begin
               if Dirs.Kind (Full) = Dirs.Directory then
                  if Images.Loaded (Drawer_Img) then
                     Trinket.Listview.Set_Item_Icon
                       (List_Widget.all, N, Drawer_Img'Access);
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
                             (List_Widget.all, N, Tool_Img'Access);
                        end if;
                     else
                        Trinket.Listview.Set_Item_Icon
                          (List_Widget.all, N, File_Img'Access);
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

      if Trinket.Listview.Item_Count (List_Widget.all) > 0 then
         Trinket.Listview.Set_Selected (List_Widget.all, 1);
      end if;
      Sync_Scrollbar;
   end Load_Directory;

   procedure Open_Clicked is
      Idx  : constant Natural :=
        Trinket.Listview.Selected (List_Widget.all);
      Name : String :=
        Trinket.Listview.Get_Item (List_Widget.all, Idx);
      Full : constant String := CLI.Join_Path (Current_Path.all, Name);
   begin
      if Idx = 0 then
         return;
      end if;

      begin
         if Dirs.Exists (Full)
           and then Dirs.Kind (Full) = Dirs.Directory
         then
            Load_Directory (CLI.Normalize_Path (Full));
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
        CLI.Normalize_Path (CLI.Join_Path (Current_Path.all, "/"));
   begin
      Load_Directory (Parent);
   end Parent_Clicked;

   --  Actions (milestone 64): the field carries the destination
   --  (rename target, copy target, new drawer name); Delete
   --  works on the selection alone.
   procedure Rename_Clicked is
      Src : constant String := Selected_Full;
      Dst : constant String := Field_Path;
   begin
      if Src'Length = 0 or else Dst'Length = 0 then
         Set_Status ("Select and name first");
         return;
      end if;
      begin
         Dirs.Rename (Src, Dst);
         Set_Status ("Renamed");
         Reload;
      exception
         when others =>
            Set_Status ("Rename failed");
      end;
   end Rename_Clicked;

   procedure Copy_Clicked is
      Src : constant String := Selected_Full;
      Dst : constant String := Field_Path;
   begin
      if Src'Length = 0 or else Dst'Length = 0 then
         Set_Status ("Select and name first");
         return;
      end if;
      begin
         Dirs.Copy_File (Src, Dst);
         Set_Status ("Copied");
         Reload;
      exception
         when others =>
            Set_Status ("Copy failed");
      end;
   end Copy_Clicked;

   procedure Newdir_Clicked is
      Dst : constant String := Field_Path;
   begin
      if Dst'Length = 0 then
         Set_Status ("Type a drawer name");
         return;
      end if;
      begin
         Dirs.Create_Directory (Dst);
         Set_Status ("Drawer created");
         Reload;
      exception
         when others =>
            Set_Status ("New drawer failed");
      end;
   end Newdir_Clicked;

   procedure Delete_Clicked is
      Src : constant String := Selected_Full;
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
         Reload;
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
   --  rows (actions added in milestone 64).
   procedure Menu_Picked (Id : Syscalls.U64) is
   begin
      if Id = 1 then
         Open_Clicked;
      elsif Id = 2 then
         Parent_Clicked;
      elsif Id = 3 then
         Rename_Clicked;
      elsif Id = 4 then
         Copy_Clicked;
      elsif Id = 5 then
         Newdir_Clicked;
      elsif Id = 6 then
         Delete_Clicked;
      elsif Id = 7 then
         Quit_Clicked;
      end if;
   end Menu_Picked;

   procedure Main is
      Root    : constant Trinket.Widgets.Any_Widget :=
        Trinket.Widgets.New_Group
          (Trinket.Widgets.Vertical, "File Manager");
      Mid_Row : constant Trinket.Widgets.Any_Widget :=
        Trinket.Widgets.New_Group (Trinket.Widgets.Horizontal);
      Btn_Row : constant Trinket.Widgets.Any_Widget :=
        Trinket.Widgets.New_Group (Trinket.Widgets.Horizontal);
      Btn_Row2 : constant Trinket.Widgets.Any_Widget :=
        Trinket.Widgets.New_Group (Trinket.Widgets.Horizontal);
      ISt : Images.Status;
   begin
      CLI.Init;
      Files.Bind (FS_EP);
      Current_Path := new String'(CLI.Get_Cwd);

      --  Deficons: Sys:System/Icons/*.xpm; any failure just
      --  leaves the rows icon-less.
      Images.Load ("BD0:System/Icons/DEFDRAW.XPM", Drawer_Img, ISt);
      Images.Load ("BD0:System/Icons/DEFFILE.XPM", File_Img, ISt);
      Images.Load ("BD0:System/Icons/DEFTOOL.XPM", Tool_Img, ISt);

      Path_Label := Trinket.Widgets.New_Label
        (Current_Path.all, Inset => True);
      List_Widget := Trinket.Listview.New_Listview
        (Selection_Changed'Access);
      Scroll_Widget := Trinket.Widgets.New_Scrollbar (Scroll_Moved'Access);
      Name_Input := Trinket.Widgets.New_Input;
      Status_Label := Trinket.Widgets.New_Label ("", Inset => True);

      Trinket.Widgets.Group (Root.all).Add (Path_Label);
      Trinket.Widgets.Group (Mid_Row.all).Add
        (Trinket.Widgets.Any_Widget (List_Widget));
      Trinket.Widgets.Group (Mid_Row.all).Add (Scroll_Widget);
      --  Added AFTER the list so the reverse key walk lets a
      --  focused input take editing keys first (widgets.ads).
      --  Weights (MUI lineage): the list takes half the window,
      --  labels/field/buttons split the rest evenly.
      Trinket.Widgets.Group (Root.all).Add (Mid_Row, 5);
      Trinket.Widgets.Group (Root.all).Add (Name_Input);
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Open", Open_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Parent", Parent_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Rename", Rename_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Copy To", Copy_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row2.all).Add
        (Trinket.Widgets.New_Button ("New Drawer", Newdir_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row2.all).Add
        (Trinket.Widgets.New_Button ("Delete", Delete_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row2.all).Add
        (Trinket.Widgets.New_Button ("Quit", Quit_Clicked'Access));
      Trinket.Widgets.Group (Root.all).Add (Btn_Row);
      Trinket.Widgets.Group (Root.all).Add (Btn_Row2);
      Trinket.Widgets.Group (Root.all).Add (Status_Label);

      if Trinket.Window.Open
        (Win, Bureau_EP, 560, 400, "File Manager", Root)
      then
         Trinket.Window.Set_Menus
           (Win,
            (1 => Trinket.Menus.M
               ("File", (Trinket.Menus.It (1, "Open"),
                         Trinket.Menus.It (2, "Parent"),
                         Trinket.Menus.It (3, "Rename"),
                         Trinket.Menus.It (4, "Copy To"),
                         Trinket.Menus.It (5, "New Drawer"),
                         Trinket.Menus.It (6, "Delete"),
                         Trinket.Menus.It (7, "Quit")))));
         Trinket.Window.Set_Menu_Handler (Win, Menu_Picked'Access);
         Load_Directory (Current_Path.all);
         Trinket.Window.Run (Win);
         Trinket.Window.Close (Win);
      end if;
   end Main;

end Fileman_App;
