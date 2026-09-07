with Ada.Text_IO;
with Akernel_User.Syscalls;
with Akernel_User.CLI;
with Trinket;
with Trinket.Widgets;
with Trinket.Widgets.Tabs;
with Trinket.Text_Edit;
with Trinket.Window;
with Trinket.Menus;

--  Edit (multi-file, milestone 9x): Text Edit is a tabbed editor —
--  one tab per document, the filename on the tab. 'edit a.txt
--  b.txt' opens each file in its own tab with its own editor and
--  save path; File > Save (Alt+S) writes the ACTIVE tab, File >
--  Quit (Alt+Q) or the close gadget leaves. No argument starts an
--  untitled "(new file)" tab.
package body Edit_App is
   use Akernel_User.Syscalls;
   use type Akernel_User.Syscalls.U64;
   package Widgets renames Trinket.Widgets;
   package TE renames Trinket.Text_Edit;

   Win   : Trinket.Window.Window;
   Tabs_W : Widgets.Any_Widget;

   Max_Docs : constant := 8;

   type Doc is record
      Box  : TE.Any_Text_Edit;        --  per-tab editor
      Path : access String := null;   --  full path (null = untitled)
   end record;

   Docs      : array (1 .. Max_Docs) of Doc;
   Doc_Count : Natural := 0;
   Current   : Natural := 1;   --  1-based active tab

   --  Filename for a tab: the basename after the last '/'.
   function Tab_Name (P : access String) return String is
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

   procedure Save_Clicked is
   begin
      if Doc_Count = 0 then
         return;
      end if;
      if Docs (Current).Path = null then
         Debug_Put_Line ("edit: no path, nothing to save");
         return;
      end if;
      declare
         use Ada.Text_IO;
         F : File_Type;
         D : Doc renames Docs (Current);
      begin
         --  Stream_IO-style truncate: Text_IO Create overwrites.
         Create (F, Out_File, D.Path.all);
         for I in 1 .. TE.Line_Count (D.Box.all) loop
            Put_Line (F, TE.Get_Line (D.Box.all, I));
         end loop;
         Close (F);
         TE.Clear_Modified (D.Box.all);
         Debug_Put_Line ("edit: saved " & D.Path.all);
      exception
         when others =>
            Debug_Put_Line ("edit: save failed " & Docs (Current).Path.all);
      end;
   end Save_Clicked;

   procedure Quit_Clicked is
   begin
      Trinket.Window.Request_Quit (Win);
   end Quit_Clicked;

   --  Milestone 61: File menu (Amiga screen bar — right-click).
   procedure Menu_Picked (Id : U64) is
   begin
      if Id = 1 then
         Save_Clicked;
      elsif Id = 2 then
         Quit_Clicked;
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

   procedure Add_Doc (P : access String) is
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
      if Doc_Count = 1 then
         Widgets.Tabs.Set_Selected
           (Widgets.Tabs.Tabs (Tabs_W.all), 1);
      end if;
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
        (Win, 3, 520, 360, "Edit", Tabs_W)
      then
         Trinket.Window.Set_Menus
           (Win,
            (1 => Trinket.Menus.M
               ("File", (Trinket.Menus.It (1, "Save", 's', Alt => True),
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
