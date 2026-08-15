with Akernel_User.Syscalls;
with Trinket.Widgets;
with Trinket.Window;

package body Tdemo_App is
   use Akernel_User.Syscalls;
   package Widgets renames Trinket.Widgets;

   Win : Trinket.Window.Window;

   procedure Save_Clicked is
   begin
      Debug_Put_Line ("tdemo: Save clicked");
   end Save_Clicked;

   procedure Revert_Clicked is
   begin
      Debug_Put_Line ("tdemo: Revert clicked");
   end Revert_Clicked;

   procedure Cancel_Clicked is
   begin
      Debug_Put_Line ("tdemo: Cancel clicked");
   end Cancel_Clicked;

   procedure Main is
      Root     : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical, "Trinket Demo");
      File_Grp : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal, "File");
      Text_Grp : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical, "Text", Inset => True);
      Btn_Row  : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
   begin
      Widgets.Group (File_Grp.all).Add
        (Widgets.New_Label ("BD0:README.TXT", Inset => True));

      Widgets.Group (Text_Grp.all).Add (Widgets.New_Label ("# Akernel"));
      Widgets.Group (Text_Grp.all).Add
        (Widgets.New_Label ("Trinket widget tree, live."));
      Widgets.Group (Text_Grp.all).Add
        (Widgets.New_Label ("Groups, labels and buttons"));
      Widgets.Group (Text_Grp.all).Add
        (Widgets.New_Label ("draw client-side; Bureau"));
      Widgets.Group (Text_Grp.all).Add
        (Widgets.New_Label ("keeps the chrome."));

      Widgets.Group (Btn_Row.all).Add
        (Widgets.New_Button ("Save", Save_Clicked'Access));
      Widgets.Group (Btn_Row.all).Add
        (Widgets.New_Button ("Revert", Revert_Clicked'Access));
      Widgets.Group (Btn_Row.all).Add
        (Widgets.New_Button ("Cancel", Cancel_Clicked'Access));

      Widgets.Group (Root.all).Add (File_Grp);
      Widgets.Group (Root.all).Add (Text_Grp);
      Widgets.Group (Root.all).Add (Btn_Row);

      if Trinket.Window.Open
        (Win, 3, 400, 300, "Trinket Demo", Root)
      then
         Debug_Put_Line ("tdemo online");
         Trinket.Window.Run (Win);
         Trinket.Window.Close (Win);
      else
         Debug_Put_Line ("tdemo: window open failed");
      end if;
   end Main;

end Tdemo_App;
