with Ada.Directories;
with System;
with System.Storage_Elements;
with Akernel_User.CLI;
with Akernel_User.Syscalls;
with Akernel_User.Files;
with Trinket;
with Trinket.Widgets;
with Trinket.Listview;
with Trinket.Window;

package body Fileman_App is

   package CLI renames Akernel_User.CLI;
   package Dirs renames Ada.Directories;
   package Syscalls renames Akernel_User.Syscalls;
   package Files renames Akernel_User.Files;

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

   procedure Sync_Scrollbar;
   procedure Scroll_Moved (Pos : Trinket.U64);
   procedure Selection_Changed (Index : Natural);
   procedure Open_Clicked;
   procedure Parent_Clicked;
   procedure Quit_Clicked;
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

   procedure Selection_Changed (Index : Natural) is
      pragma Unreferenced (Index);
   begin
      Sync_Scrollbar;
   end Selection_Changed;

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
      Files.Bind (FS_EP);

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

   procedure Load_Directory (P : String) is
      Search : Dirs.Search_Type;
      Ent    : Dirs.Directory_Entry_Type;
   begin
      Current_Path := new String'(P);
      Trinket.Widgets.Set_Text
        (Trinket.Widgets.Label (Path_Label.all), P);
      Trinket.Listview.Clear (List_Widget.all);

      begin
         Dirs.Start_Search (Search, P, "*");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Ent);
            Trinket.Listview.Add_Item
              (List_Widget.all, Dirs.Simple_Name (Ent));
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

   procedure Quit_Clicked is
   begin
      Trinket.Window.Request_Quit (Win);
   end Quit_Clicked;

   procedure Main is
      Root    : constant Trinket.Widgets.Any_Widget :=
        Trinket.Widgets.New_Group
          (Trinket.Widgets.Vertical, "File Manager");
      Mid_Row : constant Trinket.Widgets.Any_Widget :=
        Trinket.Widgets.New_Group (Trinket.Widgets.Horizontal);
      Btn_Row : constant Trinket.Widgets.Any_Widget :=
        Trinket.Widgets.New_Group (Trinket.Widgets.Horizontal);
   begin
      CLI.Init;
      Current_Path := new String'(CLI.Get_Cwd);

      Path_Label := Trinket.Widgets.New_Label
        (Current_Path.all, Inset => True);
      List_Widget := Trinket.Listview.New_Listview
        (Selection_Changed'Access);
      Scroll_Widget := Trinket.Widgets.New_Scrollbar (Scroll_Moved'Access);

      Trinket.Widgets.Group (Root.all).Add (Path_Label);
      Trinket.Widgets.Group (Mid_Row.all).Add
        (Trinket.Widgets.Any_Widget (List_Widget));
      Trinket.Widgets.Group (Mid_Row.all).Add (Scroll_Widget);
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Open", Open_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Parent", Parent_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.New_Button ("Quit", Quit_Clicked'Access));
      Trinket.Widgets.Group (Root.all).Add (Mid_Row);
      Trinket.Widgets.Group (Root.all).Add (Btn_Row);

      if Trinket.Window.Open
        (Win, Bureau_EP, 400, 340, "File Manager", Root)
      then
         Load_Directory (Current_Path.all);
         Trinket.Window.Run (Win);
         Trinket.Window.Close (Win);
      end if;
   end Main;

end Fileman_App;
