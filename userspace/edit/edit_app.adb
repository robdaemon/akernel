with Ada.Text_IO;
with Akernel_User.Syscalls;
with Akernel_User.CLI;
with Trinket;
with Trinket.Widgets;
with Trinket.Text_Edit;
with Trinket.Window;

package body Edit_App is
   use Akernel_User.Syscalls;
   use type Akernel_User.Syscalls.U64;
   package Widgets renames Trinket.Widgets;
   package TE renames Trinket.Text_Edit;

   Win : Trinket.Window.Window;

   --  Built in Main, referenced from the library-level
   --  callbacks.
   Edit_Box : TE.Any_Text_Edit;
   Scroller : Widgets.Any_Widget;
   Path     : access String := null;

   procedure Save_Clicked is
   begin
      if Path = null then
         Debug_Put_Line ("edit: no path, nothing to save");
         return;
      end if;
      declare
         use Ada.Text_IO;
         F : File_Type;
      begin
         --  Stream_IO-style truncate: Text_IO Create overwrites.
         Create (F, Out_File, Path.all);
         for I in 1 .. TE.Line_Count (Edit_Box.all) loop
            Put_Line (F, TE.Get_Line (Edit_Box.all, I));
         end loop;
         Close (F);
         TE.Clear_Modified (Edit_Box.all);
         Debug_Put_Line ("edit: saved " & Path.all);
      exception
         when others =>
            Debug_Put_Line ("edit: save failed " & Path.all);
      end;
   end Save_Clicked;

   procedure Quit_Clicked is
   begin
      Trinket.Window.Request_Quit (Win);
   end Quit_Clicked;

   procedure Scroll_Moved (Pos : U64) is
   begin
      TE.Set_Top (Edit_Box.all, Pos);
   end Scroll_Moved;

   procedure Sync_Scrollbar is
      N    : constant U64 := U64 (TE.Line_Count (Edit_Box.all));
      Vis  : constant U64 := TE.Visible_Rows (Edit_Box.all);
      MaxT : constant U64 := (if N > Vis then N - Vis else 0);
   begin
      Widgets.Set_Range (Widgets.Scrollbar (Scroller.all),
                         0, MaxT, Vis);
      Widgets.Set_Pos (Widgets.Scrollbar (Scroller.all),
                       TE.Top_Line (Edit_Box.all));
   end Sync_Scrollbar;

   procedure Load (P : String) is
      use Ada.Text_IO;
      F : File_Type;
   begin
      Open (F, In_File, P);
      TE.Clear (Edit_Box.all);
      while not End_Of_File (F) loop
         TE.Append_Line (Edit_Box.all, Get_Line (F));
      end loop;
      Close (F);
      Debug_Put_Line ("edit: loaded " & P);
   exception
      when others =>
         --  Missing/unreadable file: start empty, keep the path
         --  so Save creates it.
         TE.Clear (Edit_Box.all);
   end Load;

   procedure Main is
      Root    : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical, "Edit");
      Mid_Row : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
      Btn_Row : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
      Path_L  : Widgets.Any_Widget;
   begin
      Edit_Box := TE.Any_Text_Edit (TE.New_Text_Edit);
      Scroller := Widgets.New_Scrollbar (Scroll_Moved'Access);

      if Akernel_User.CLI.Arg_Count >= 1 then
         Path := new String'(Akernel_User.CLI.Argument (1));
      end if;

      Path_L := Widgets.New_Label
        ((if Path = null then "(new file)" else Path.all),
         Inset => True);
      Widgets.Group (Root.all).Add (Path_L);
      Widgets.Group (Mid_Row.all).Add (Widgets.Any_Widget (Edit_Box));
      Widgets.Group (Mid_Row.all).Add (Scroller);
      Widgets.Group (Root.all).Add (Mid_Row);
      Widgets.Group (Btn_Row.all).Add
        (Widgets.New_Button ("Save", Save_Clicked'Access));
      Widgets.Group (Btn_Row.all).Add
        (Widgets.New_Button ("Quit", Quit_Clicked'Access));
      Widgets.Group (Root.all).Add (Btn_Row);

      if Path /= null then
         Load (Path.all);
      end if;

      if Trinket.Window.Open
        (Win, 3, 460, 340, "Edit", Root)
      then
         Sync_Scrollbar;
         Debug_Put_Line ("edit online");
         Trinket.Window.Run (Win);
         Trinket.Window.Close (Win);
      else
         Debug_Put_Line ("edit: window open failed");
      end if;
   end Main;

end Edit_App;
