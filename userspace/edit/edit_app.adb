with Ada.Text_IO;
with Akernel_User.Syscalls;
with Akernel_User.CLI;
with Trinket;
with Trinket.Widgets;
with Trinket.Widgets.Tabs;
with Trinket.Text_Edit;
with Trinket.Window;
with Trinket.Menus;
with Trinket.File_Requester;

--  Edit (multi-file, milestone 9x): Text Edit is a tabbed editor —
--  one tab per document, the filename on the tab. 'edit a.txt
--  b.txt' opens each file in its own tab with its own editor and
--  save path. File menu: New (Alt+N) adds an untitled tab, Open
--  (Alt+O) picks a file in the shared requester and opens it in a
--  new tab, Save (Alt+S) writes the ACTIVE tab, Save As re-picks
--  a target path and renames the tab, Quit (Alt+Q) or the close
--  gadget leaves.
package body Edit_App is
   use Akernel_User.Syscalls;
   use type Akernel_User.Syscalls.U64;
   package Widgets renames Trinket.Widgets;
   package TE renames Trinket.Text_Edit;

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
   end Save_Clicked;

   procedure Quit_Clicked is
   begin
      Trinket.Window.Request_Quit (Win);
   end Quit_Clicked;

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

   procedure New_Doc_Action is
   begin
      Add_Doc (null);
   end New_Doc_Action;

   procedure Open_Action is
      PBuf : String (1 .. 255);
      PLen : Natural;
   begin
      if Trinket.File_Requester.Run
        (Win,
         Trinket.File_Requester.Pick_Open,
         (if Docs (Current).Path = null
          then "Sys:"
          else Dir_Of (Docs (Current).Path.all)),
         PBuf, PLen)
      then
         if PLen > 0 then
            Add_Doc (new String'(PBuf (1 .. PLen)));
         end if;
      end if;
   end Open_Action;

   procedure Save_As_Action is
      PBuf : String (1 .. 255);
      PLen : Natural;
   begin
      if Doc_Count = 0 then
         return;
      end if;
      if Trinket.File_Requester.Run
        (Win,
         Trinket.File_Requester.Pick_Save_As,
         (if Docs (Current).Path = null
          then "Sys:"
          else Dir_Of (Docs (Current).Path.all)),
         PBuf, PLen)
      then
         if PLen > 0 then
            Write_Doc_To (PBuf (1 .. PLen));
            Docs (Current).Path := new String'(PBuf (1 .. PLen));
            Set_Tab_Label (Current, Tab_Name (Docs (Current).Path));
         end if;
      end if;
   end Save_As_Action;

   --  File menu (Amiga screen bar — right-click).
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
      --  The new document becomes the active tab.
      Current := Doc_Count;
      Widgets.Tabs.Set_Selected
        (Widgets.Tabs.Tabs (Tabs_W.all), Doc_Count);
   end Add_Doc;

   procedure Main is
   begin
      Tabs_W := Widgets.Tabs.New_Tabs (Tab_Moved'Access);

      if Akernel_User.CLI.Arg_Count >= 1 then
         for I in 1 .. Akernel_User.CLI.Arg_Count loop
            Add_Doc (new String'(Akernel_User.CLI.Argument (I)));
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
                                           Alt => True)))));
         Trinket.Window.Set_Menu_Handler (Win, Menu_Picked'Access);
         Debug_Put_Line ("edit online");
         Trinket.Window.Run (Win);
         Trinket.Window.Close (Win);
      else
         Debug_Put_Line ("edit: window open failed");
      end if;
   end Main;

end Edit_App;
