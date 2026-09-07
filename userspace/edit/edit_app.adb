with Ada.Text_IO;
with Akernel_User.Syscalls;
with Akernel_User.CLI;
with Trinket;
with Trinket.Widgets;
with Trinket.Widgets.Label;
with Trinket.Widgets.Button;
with Trinket.Text_Edit;
with Trinket.Window;
with Trinket.Menus;

package body Edit_App is
   use Akernel_User.Syscalls;
   use type Akernel_User.Syscalls.U64;
   package Widgets renames Trinket.Widgets;
   package TE renames Trinket.Text_Edit;

   Win : Trinket.Window.Window;

   --  Built in Main, referenced from the library-level
   --  callbacks.  The scrollbars are part of the editor
   --  component (M87e): New_Scrolled_Editor wires them.
   Edit_Box : TE.Any_Text_Edit;
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

   --  Milestone 61: File menu (Amiga screen bar — right-click).
   procedure Menu_Picked (Id : U64) is
   begin
      if Id = 1 then
         Save_Clicked;
      elsif Id = 2 then
         Quit_Clicked;
      end if;
   end Menu_Picked;

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
      Frame   : Widgets.Any_Widget;
      Btn_Row : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
      Path_L  : Widgets.Any_Widget;
   begin
      --  M87e: the editor component brings its own flush
      --  scrollbars (vertical right, horizontal under the text).
      Frame := TE.New_Scrolled_Editor (Edit_Box);

      if Akernel_User.CLI.Arg_Count >= 1 then
         Path := new String'(Akernel_User.CLI.Argument (1));
      end if;

      Path_L := Widgets.Label.New_Label
        ((if Path = null then "(new file)" else Path.all),
         Inset => True);
      Widgets.Group (Root.all).Add (Path_L);
      Widgets.Group (Root.all).Add (Frame);
      Widgets.Group (Btn_Row.all).Add
        (Widgets.Button.New_Button ("Save", Save_Clicked'Access));
      Widgets.Group (Btn_Row.all).Add
        (Widgets.Button.New_Button ("Quit", Quit_Clicked'Access));
      Widgets.Group (Root.all).Add (Btn_Row);

      if Path /= null then
         Load (Path.all);
      end if;

      if Trinket.Window.Open
        (Win, 3, 460, 340, "Edit", Root)
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
