with Akernel_User.Syscalls;
with Akernel_User.Files;
with Trinket.Images;
with Trinket.Widgets;
with Trinket.Window;
with Trinket.Menus;

package body Tdemo_App is
   use Akernel_User.Syscalls;
   use type U64;
   package Widgets renames Trinket.Widgets;
   package Images renames Trinket.Images;
   package Files renames Akernel_User.Files;
   use type Images.Status;

   Win : Trinket.Window.Window;

   --  Milestone 63 showcase: decoded once at startup, blitted by
   --  the widget tree. Keyed blit lets the group face show
   --  through the magenta field (Workbench mask lineage).
   Bars_Img  : Images.Image;
   Keyed_Img : Images.Image;
   Bars_St   : Images.Status;
   Keyed_St  : Images.Status;

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

   procedure Quit_Clicked is
   begin
      Trinket.Window.Request_Quit (Win);
   end Quit_Clicked;

   --  Screen-bar menu (milestone 61): File mirrors the button
   --  row, plus Quit (the close-gadget path).
   procedure Menu_Picked (Id : U64) is
   begin
      if Id = 1 then
         Save_Clicked;
      elsif Id = 2 then
         Revert_Clicked;
      elsif Id = 3 then
         Cancel_Clicked;
      elsif Id = 4 then
         Quit_Clicked;
      end if;
   end Menu_Picked;

   procedure Main is
      Root     : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical, "Trinket Demo");
      File_Grp : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal, "File");
      Text_Grp : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical, "Text", Inset => True);
      Img_Grp  : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal, "Images");
      Btn_Row  : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
      Sz       : U64;
      T0, T1   : U64;
      NS       : U64;
   begin
      --  Uniform ABI handle 2 = fs; tdemo never bound it before
      --  the image showcase (unbound Files answers Bad_Args).
      Files.Bind (2);

      --  Startup spawns tdemo while the disk stack is still
      --  mounting BD0 — wait for the showcase files (bounded;
      --  Amiga apps wait for volumes, the library stays dumb).
      Read_Clock (T0, NS);
      loop
         exit when Files.Stat ("BD0:Tests/Img/bars.bmp", Sz)
           = Files.Status_Ok;
         Read_Clock (T1, NS);
         exit when T1 >= T0 + 5;
         Yield;
      end loop;

      Images.Load ("BD0:Tests/Img/bars.bmp", Bars_Img, Bars_St);
      Images.Load ("BD0:Tests/Img/keyed.bmp", Keyed_Img, Keyed_St);
      if Keyed_St = Images.Ok then
         Keyed_Img.Has_Key := True;
         Keyed_Img.Key := 16#FFFF_00FF#;  --  generator magenta
      end if;

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

      if Bars_St = Images.Ok then
         Widgets.Group (Img_Grp.all).Add (Widgets.New_Image (Bars_Img));
      end if;
      if Keyed_St = Images.Ok then
         Widgets.Group (Img_Grp.all).Add (Widgets.New_Image (Keyed_Img));
      end if;
      if Bars_St /= Images.Ok and then Keyed_St /= Images.Ok then
         Widgets.Group (Img_Grp.all).Add
           (Widgets.New_Label ("Images unavailable"));
      end if;

      Widgets.Group (Btn_Row.all).Add
        (Widgets.New_Button ("Save", Save_Clicked'Access));
      Widgets.Group (Btn_Row.all).Add
        (Widgets.New_Button ("Revert", Revert_Clicked'Access));
      Widgets.Group (Btn_Row.all).Add
        (Widgets.New_Button ("Cancel", Cancel_Clicked'Access));

      Widgets.Group (Root.all).Add (File_Grp);
      Widgets.Group (Root.all).Add (Text_Grp);
      Widgets.Group (Root.all).Add (Img_Grp);
      Widgets.Group (Root.all).Add (Btn_Row);

      if Trinket.Window.Open
        (Win, 3, 400, 380, "Trinket Demo", Root)
      then
         Trinket.Window.Set_Menus
           (Win,
            (1 => Trinket.Menus.M
               ("File", (Trinket.Menus.It (1, "Save"),
                         Trinket.Menus.It (2, "Revert"),
                         Trinket.Menus.It (3, "Cancel"),
                         Trinket.Menus.It (4, "Quit")))));
         Trinket.Window.Set_Menu_Handler (Win, Menu_Picked'Access);
         Debug_Put_Line ("tdemo online");
         Trinket.Window.Run (Win);
         Trinket.Window.Close (Win);
      else
         Debug_Put_Line ("tdemo: window open failed");
      end if;
   end Main;

end Tdemo_App;
