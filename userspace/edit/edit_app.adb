with Ada.Text_IO;
with Aegir_User.Syscalls;
with Aegir_User.CLI;
with Aegir_User.Clipboard;
with Trinket;
with Trinket.Widgets;
with Trinket.Widgets.Tabs;
with Trinket.Text_Edit;
with Trinket.Window;
with Trinket.Menus;
with Trinket.File_Requester;
with Trinket.Message_Box;

--  Edit (multi-file, milestone 9x): Text Edit is a tabbed editor —
--  one tab per document, the filename on the tab. 'edit a.txt
--  b.txt' opens each file in its own tab with its own editor and
--  save path. File menu: New (Alt+N) adds an untitled tab, Open
--  (Alt+O) picks a file in the shared requester and opens it in a
--  new tab, Save (Alt+S) writes the ACTIVE tab, Save As re-picks
--  a target path and renames the tab, Quit (Alt+Q) or the close
--  gadget leaves. Edit menu: Cut/Copy/Paste/Select All (Ctrl+X/C/
--  V/A) through the system clipboard (Sys:Libs/Clipboard).
package body Edit_App is
   use Aegir_User.Syscalls;
   use type Aegir_User.Syscalls.U64;
   package Widgets renames Trinket.Widgets;
   package TE renames Trinket.Text_Edit;
   use type Widgets.Any_Widget;
   use type TE.Any_Text_Edit;

   Win    : Trinket.Window.Window;
   Tabs_W : Widgets.Any_Widget;

   Max_Docs : constant := 8;

   --  Named access type: anonymous-access parameters would fail the
   --  runtime accessibility check when Docs (library level) stores a
   --  'new' from a nested subprogram (PROGRAM_ERROR: accessibility
   --  check failed). Named access allocates on the heap at the type's
   --  level, no checks.
   type String_Acc is access String;

   type Doc is record
      Box  : TE.Any_Text_Edit;        --  per-tab editor
      Path : String_Acc;               --  full path (null = untitled)
   end record;

   Docs      : array (1 .. Max_Docs) of Doc;
   Doc_Count : Natural := 0;
   Current   : Natural := 1;   --  1-based active tab

   procedure Add_Doc (P : String_Acc);   --  body below the actions

   --  Filename for a tab: the basename after the last '/'.
   function Tab_Name (P : String_Acc) return String is
   begin
      if P = null then
         return "(new file)";
      end if;
      for I in reverse P.all'Range loop
         if P.all (I) = '/' then
            return P.all (I + 1 .. P.all'Last);
         end if;
      end loop;
      return P.all;
   end Tab_Name;

   --  Directory part of a path: up to the last '/'; a bare
   --  volume ("Sys:foo" -> "Sys:", "Sys:" -> "Sys:").
   function Dir_Of (P : String) return String is
   begin
      for I in reverse P'Range loop
         if P (I) = '/' then
            if I > P'First then
               return P (P'First .. I - 1);
            end if;
            return P (P'First .. I - 1);
         end if;
      end loop;
      for I in P'Range loop
         if P (I) = ':' then
            return P (P'First .. I);
         end if;
      end loop;
      return "Sys:";
   end Dir_Of;

   --  Retitle tab Index with S (bounded by the tab text cell).
   procedure Set_Tab_Label (Index : Natural; S : String) is
      L : Widgets.Text_Rec renames
        Widgets.Tabs.Tabs (Tabs_W.all).Labels (Index);
   begin
      L.Len := Natural'Min (S'Length, L.Buf'Length);
      if L.Len > 0 then
         L.Buf (1 .. L.Len) := S (S'First .. S'First + L.Len - 1);
      end if;
      Widgets.Tabs.Tabs (Tabs_W.all).Dirty := True;
   end Set_Tab_Label;

   --  M9z unsaved-buffer plumbing: per-doc dirty state is the
   --  Text_Edit Modified flag; the tab label carries a '*' prefix
   --  while the doc is dirty, kept live via the modified callback.

   function Is_Dirty (Idx : Natural) return Boolean is
     (Idx in 1 .. Doc_Count
      and then TE.Modified (Docs (Idx).Box.all));

   function Doc_Name (Idx : Natural) return String is
     (if Docs (Idx).Path = null then "(new file)"
      else Docs (Idx).Path.all);

   --  Refresh tab Idx's label from its dirty state.
   procedure Update_Tab (Idx : Natural) is
   begin
      if Idx in 1 .. Doc_Count and then Tabs_W /= null then
         Set_Tab_Label (Idx,
                        (if Is_Dirty (Idx) then "*" else "")
                        & Tab_Name (Docs (Idx).Path));
      end if;
   end Update_Tab;

   --  Modified callback (one per editor): find the doc and refresh
   --  its tab star.
   procedure Doc_Modified (Ed : access TE.Text_Edit) is
   begin
      for J in 1 .. Doc_Count loop
         if Docs (J).Box = TE.Any_Text_Edit (Ed) then
            Update_Tab (J);
            return;
         end if;
      end loop;
   end Doc_Modified;

   --  Write every line of the ACTIVE document to Path.
   procedure Write_Doc_To (Path : String) is
      use Ada.Text_IO;
      F : File_Type;
      D : Doc renames Docs (Current);
   begin
      if Doc_Count = 0 then
         return;
      end if;
      Create (F, Out_File, Path);
      for I in 1 .. TE.Line_Count (D.Box.all) loop
         Put_Line (F, TE.Get_Line (D.Box.all, I));
      end loop;
      Close (F);
      TE.Clear_Modified (D.Box.all);
      Debug_Put_Line ("edit: saved " & Path);
   exception
      when others =>
         Debug_Put_Line ("edit: save failed " & Path);
   end Write_Doc_To;

   procedure Save_Clicked is
   begin
      if Doc_Count = 0 then
         return;
      end if;
      if Docs (Current).Path = null then
         Debug_Put_Line ("edit: no path, nothing to save");
         return;
      end if;
      Write_Doc_To (Docs (Current).Path.all);
      Update_Tab (Current);
   end Save_Clicked;

   --  M9z quit-dialog plumbing (Message_Box): Save / Save All /
   --  Cancel per dirty doc. Message_Box exits the dialog BEFORE
   --  On_Quit_Choice runs, so chaining the next prompt queues it
   --  onto the exiting modal.
   Prompt_Doc : Natural := 0;   --  the doc the open dialog names
   procedure Prompt_Quit_Doc (Idx : Natural);  --  body after On_Quit_Choice
   --  Docs the user dropped with "Don't Save" in the CURRENT quit
   --  pass: the chain skips them (they stay open+dirty if a later
   --  Cancel aborts the pass). Cleared on Cancel and on a fresh
   --  Try_Quit.
   Quit_Skip : array (1 .. Max_Docs) of Boolean := (others => False);

   procedure Save_Doc (Idx : Natural) is
      Save_Cur : constant Natural := Current;
   begin
      if Docs (Idx).Path = null then
         Debug_Put_Line
           ("edit: cannot save untitled doc (use Save As)");
         return;
      end if;
      Current := Idx;
      Write_Doc_To (Docs (Idx).Path.all);
      Current := Save_Cur;
      Update_Tab (Idx);
   end Save_Doc;

   procedure Focus_Doc (Idx : Natural) is
   begin
      if Idx in 1 .. Doc_Count then
         Current := Idx;
         Widgets.Tabs.Set_Selected
           (Widgets.Tabs.Tabs (Tabs_W.all), Idx);
      end if;
   end Focus_Doc;

   --  First dirty doc the current pass has not dropped.
   function Next_Pending return Natural is
   begin
      for J in 1 .. Doc_Count loop
         if Is_Dirty (J) and then not Quit_Skip (J) then
            return J;
         end if;
      end loop;
      return 0;
   end Next_Pending;

   procedure On_Quit_Choice (Choice : Natural) is
      Idx : constant Natural := Prompt_Doc;
      Nxt : Natural;
   begin
      Prompt_Doc := 0;
      if Idx not in 1 .. Doc_Count then
         return;
      end if;
      if Choice = 0 or else Choice = 4 then
         --  Dismissed / Cancel: abandon the whole quit pass.
         Quit_Skip := (others => False);
         return;
      elsif Choice = 1 then
         --  Save this doc, then keep going.
         Save_Doc (Idx);
         if Is_Dirty (Idx) then
            --  Untitled or a failed write: park here (Save As).
            Quit_Skip := (others => False);
            Focus_Doc (Idx);
            return;
         end if;
      elsif Choice = 2 then
         --  Save All (skipping docs already dropped).
         for J in 1 .. Doc_Count loop
            if Is_Dirty (J) and then not Quit_Skip (J) then
               Save_Doc (J);
            end if;
         end loop;
      else
         --  Choice = 3: Don't Save this doc (drop it for this quit).
         Quit_Skip (Idx) := True;
      end if;
      Nxt := Next_Pending;
      if Nxt = 0 then
         Quit_Skip := (others => False);
         Trinket.Window.Request_Quit (Win);
      else
         Prompt_Quit_Doc (Nxt);
      end if;
   end On_Quit_Choice;

   procedure Prompt_Quit_Doc (Idx : Natural) is
   begin
      Prompt_Doc := Idx;
      Trinket.Message_Box.Request
        (Win,
         "Save changes?",
         "Would you like to save changes to " & Doc_Name (Idx) & "?",
         "Save|Save All|Don't Save|Cancel",
         On_Quit_Choice'Access);
   end Prompt_Quit_Doc;

   --  M9z: Quit goes through the dirty-buffer check (Save / Save
   --  All / Don't Save / Cancel per dirty doc) instead of quitting
   --  blindly.
   procedure Try_Quit is
      Idx : Natural;
   begin
      Quit_Skip := (others => False);   --  a fresh quit pass
      if Doc_Count = 0 then
         Trinket.Window.Request_Quit (Win);
         return;
      end if;
      Idx := 0;
      if Is_Dirty (Current) then
         Idx := Current;
      else
         for J in 1 .. Doc_Count loop
            if Is_Dirty (J) then
               Idx := J;
               exit;
            end if;
         end loop;
      end if;
      if Idx = 0 then
         Trinket.Window.Request_Quit (Win);
      else
         Prompt_Quit_Doc (Idx);
      end if;
   end Try_Quit;

   procedure Quit_Clicked is
   begin
      Try_Quit;
   end Quit_Clicked;

   procedure New_Doc_Action is
   begin
      Add_Doc (null);
   end New_Doc_Action;

   --  Requester results (fired from the event loop after the
   --  modal panel closes or cancels).
   SaveAs_Doc : Natural := 0;

   procedure On_Open_Pick (Picked : Boolean; Path : String) is
   begin
      if Picked and then Path'Length > 0 then
         Add_Doc (new String'(Path));
      end if;
   end On_Open_Pick;

   procedure On_Save_As_Pick (Picked : Boolean; Path : String) is
      Idx : constant Natural := SaveAs_Doc;
   begin
      if not (Picked and then Path'Length > 0)
        or else Idx = 0 or else Idx > Doc_Count
      then
         return;
      end if;
      Write_Doc_To (Path);
      Docs (Idx).Path := new String'(Path);
      Update_Tab (Idx);
   end On_Save_As_Pick;

   procedure Open_Action is
   begin
      Trinket.File_Requester.Request
        (Win,
         Trinket.File_Requester.Pick_Open,
         (if Docs (Current).Path = null
          then "Sys:"
          else Dir_Of (Docs (Current).Path.all)),
         On_Open_Pick'Access);
   end Open_Action;

   procedure Save_As_Action is
   begin
      if Doc_Count = 0 then
         return;
      end if;
      SaveAs_Doc := Current;
      Trinket.File_Requester.Request
        (Win,
         Trinket.File_Requester.Pick_Save_As,
         (if Docs (Current).Path = null
          then "Sys:"
          else Dir_Of (Docs (Current).Path.all)),
         On_Save_As_Pick'Access);
   end Save_As_Action;

   --  File menu (Amiga screen bar — right-click) + Edit menu
   --  (clipboard milestone): ids 11..14.
   Clipboard_Cap : U64 := 0;

   function Ensure_Clipboard return Boolean is
   begin
      if Clipboard_Cap = 0 then
         Clipboard_Cap := Aegir_User.Clipboard.Open;
         if Clipboard_Cap = 0 then
            Debug_Put_Line ("edit: clipboard open failed");
         end if;
      end if;
      return Clipboard_Cap /= 0;
   end Ensure_Clipboard;

   procedure Edit_Cut is
   begin
      if Doc_Count = 0
        or else not TE.Has_Selection (Docs (Current).Box.all)
        or else not Ensure_Clipboard
      then
         return;
      end if;
      declare
         Sel : constant String :=
           TE.Selected_Text (Docs (Current).Box.all);
      begin
         if Aegir_User.Clipboard.Put (Clipboard_Cap, Sel)
           = Aegir_User.Clipboard.Status_Ok
         then
            TE.Delete_Selected (Docs (Current).Box.all);
         end if;
      end;
   end Edit_Cut;

   procedure Edit_Copy is
   begin
      if Doc_Count = 0
        or else not TE.Has_Selection (Docs (Current).Box.all)
        or else not Ensure_Clipboard
      then
         return;
      end if;
      declare
         Sel : constant String :=
           TE.Selected_Text (Docs (Current).Box.all);
         St  : constant U64 :=
           Aegir_User.Clipboard.Put (Clipboard_Cap, Sel);
      begin
         if St /= Aegir_User.Clipboard.Status_Ok then
            Debug_Put_Line ("edit: clipboard put failed");
         end if;
      end;
   end Edit_Copy;

   procedure Edit_Paste is
      Buf : constant String_Acc :=
        new String (1 .. Aegir_User.Clipboard.Clipboard_Max);
      Len : Natural := 0;
      St  : U64;
   begin
      if Doc_Count = 0 or else not Ensure_Clipboard then
         return;
      end if;
      Buf (Buf'Range) := (others => ' ');
      St := Aegir_User.Clipboard.Get
        (Clipboard_Cap, Buf.all, Len);
      if St = Aegir_User.Clipboard.Status_Ok and then Len > 0 then
         TE.Insert_Text (Docs (Current).Box.all, Buf (1 .. Len));
      end if;
   end Edit_Paste;

   procedure Edit_Select_All is
   begin
      if Doc_Count > 0 then
         TE.Select_All (Docs (Current).Box.all);
      end if;
   end Edit_Select_All;

   procedure Menu_Picked (Id : U64) is
   begin
      if Id = 1 then
         Save_Clicked;
      elsif Id = 2 then
         Quit_Clicked;
      elsif Id = 3 then
         New_Doc_Action;
      elsif Id = 4 then
         Open_Action;
      elsif Id = 5 then
         Save_As_Action;
      elsif Id = 11 then
         Edit_Cut;
      elsif Id = 12 then
         Edit_Copy;
      elsif Id = 13 then
         Edit_Paste;
      elsif Id = 14 then
         Edit_Select_All;
      end if;
   end Menu_Picked;

   --  Tab switch: Save (Alt+S) and the per-doc state follow the
   --  active tab.
   procedure Tab_Moved (Index : Natural) is
   begin
      if Index >= 1 and then Index <= Doc_Count then
         Current := Index;
      end if;
   end Tab_Moved;

   procedure Load (D : in out Doc) is
      use Ada.Text_IO;
      F : File_Type;
   begin
      Open (F, In_File, D.Path.all);
      TE.Clear (D.Box.all);
      while not End_Of_File (F) loop
         TE.Append_Line (D.Box.all, Get_Line (F));
      end loop;
      Close (F);
      Debug_Put_Line ("edit: loaded " & D.Path.all);
   exception
      when others =>
         --  Missing/unreadable file: start empty, keep the path
         --  so Save creates it.
         TE.Clear (D.Box.all);
   end Load;

   procedure Add_Doc (P : String_Acc) is
      Frame : Widgets.Any_Widget;
   begin
      if Doc_Count = Max_Docs then
         Debug_Put_Line ("edit: too many documents");
         return;
      end if;
      Doc_Count := Doc_Count + 1;
      Docs (Doc_Count).Path := P;
      --  M87e: the editor component brings its own flush
      --  scrollbars (vertical right, horizontal under the text).
      Frame := TE.New_Scrolled_Editor (Docs (Doc_Count).Box);
      Widgets.Tabs.Add_Tab
        (Widgets.Tabs.Tabs (Tabs_W.all), Tab_Name (P), Frame);
      if P /= null then
         Load (Docs (Doc_Count));
      end if;
      --  M9z: keep the tab's dirty star live.
      TE.Set_Modified_Callback
        (Docs (Doc_Count).Box.all, Doc_Modified'Access);
      --  The new document becomes the active tab.
      Current := Doc_Count;
      Widgets.Tabs.Set_Selected
        (Widgets.Tabs.Tabs (Tabs_W.all), Doc_Count);
   end Add_Doc;

   procedure Main is
   begin
      Tabs_W := Widgets.Tabs.New_Tabs (Tab_Moved'Access);

      if Aegir_User.CLI.Arg_Count >= 1 then
         for I in 1 .. Aegir_User.CLI.Arg_Count loop
            Add_Doc (new String'(Aegir_User.CLI.Argument (I)));
         end loop;
      else
         Add_Doc (null);   --  untitled "(new file)" tab
      end if;

      if Trinket.Window.Open
        (Win, 3, 620, 400, "Edit", Tabs_W)
      then
         Trinket.Window.Set_Menus
           (Win,
            (1 => Trinket.Menus.M
               ("File", (Trinket.Menus.It (3, "New", 'n', Alt => True),
                         Trinket.Menus.It (4, "Open", 'o', Alt => True),
                         Trinket.Menus.Sep,
                         Trinket.Menus.It (1, "Save", 's', Alt => True),
                         Trinket.Menus.It (5, "Save As"),
                         Trinket.Menus.Sep,
                         Trinket.Menus.It (2, "Quit", 'q',
                                           Alt => True))),
             2 => Trinket.Menus.M
               ("Edit", (Trinket.Menus.It (11, "Cut", 'x',
                                            Alt => True),
                         Trinket.Menus.It (12, "Copy", 'c',
                                            Alt => True),
                         Trinket.Menus.It (13, "Paste", 'v',
                                            Alt => True),
                         Trinket.Menus.Sep,
                         Trinket.Menus.It (14, "Select All", 'a',
                                            Alt => True)))));
         Trinket.Window.Set_Menu_Handler (Win, Menu_Picked'Access);
         Trinket.Window.Set_Quit_Handler (Win, Try_Quit'Access);
         Debug_Put_Line ("edit online");
         Trinket.Window.Run (Win);
         Trinket.Window.Close (Win);
      else
         Debug_Put_Line ("edit: window open failed");
      end if;
   end Main;

end Edit_App;
