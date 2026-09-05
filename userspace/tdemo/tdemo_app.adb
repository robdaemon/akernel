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
   use type Widgets.Any_Widget;

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

    ----------------------------------------------------------------------
    --  Milestone 68 showcase: the Work button kicks a background
    --  worker task that loads and decodes an image off the event
    --  thread (file IO + BMP decode), then Posts the result to the
    --  window's app port; the dispatch thread swaps the decoded
    --  image into the widget tree. Only the event-dispatch thread
    --  touches widgets (the Swing invokeLater shape, design item 5
    --  of docs/runtime/tasking.md).
    ----------------------------------------------------------------------

    Status_Lbl : Widgets.Any_Widget;
    Img_Widget : Widgets.Any_Widget;
    Work_Gauge : Widgets.Any_Widget;

    --  M87b showcase: the slider positions the gauge directly.
    procedure Slider_Moved (Pos : U64) is
    begin
       Widgets.Gauge (Work_Gauge.all).Set_Fraction (Pos, 100);
    end Slider_Moved;

    --  M86e showcase: the three radios in the "Choices" group
    --  share this set, so selecting one clears the others.
    Choice_Set : aliased Widgets.Radio_Set;

    procedure Choice_Toggled (On : Boolean) is
    begin
       Debug_Put_Line ("tdemo: choice toggled" & Boolean'Image (On));
    end Choice_Toggled;

    --  M87e showcase: tab switches report on the status line.
    procedure Tab_Moved (Index : Natural) is
       S : constant String := "tab" & Natural'Image (Index);
    begin
       Widgets.Label (Status_Lbl.all).Set_Text (S);
    end Tab_Moved;

    --  Worker gate: the worker task creates its own gate
    --  notification, publishes the handle, then blocks in
    --  Ntfn_Wait — no CPU burned while idle (protected entries are
    --  not in the user runtime profile, so the gate follows the
    --  fuzz_port pattern).
    Work_Gate : U64 := 0 with Volatile;

    --  Image handoff: the worker loads into Worker_Img; the
    --  dispatch thread swaps it into Img_Widget and frees the
    --  previously borrowed image (Swap_Img). Worker_Img's stale
    --  pointer after a swap aliases Swap_Img — never freed by the
    --  worker, overwritten (not freed) by the next Load. Busy is
    --  dispatch-thread-only: clicks during a job are dropped.
    Worker_Img : Images.Image;
    Swap_Img   : Images.Image;
    Busy       : Boolean := False;

    task Worker;

    task body Worker is
       Bits   : U64;
       St     : Images.Status;
       Ignore : U64;
    begin
       Work_Gate := Ntfn_Create;
       loop
          Bits := Ntfn_Wait (Work_Gate);
          exit when Bits = Syscall_Failed;
          Images.Load ("BD0:Tests/Img/bars.bmp", Worker_Img, St);
          Ignore := Boolean'Pos
            (Trinket.Window.Post
               (Win, 1,
                U64 (Images.Status'Pos (St)), Worker_Img.W, Worker_Img.H));
       end loop;
    end Worker;

    procedure Work_Clicked is
       Ignore : U64;
    begin
       if Busy or else Work_Gate = 0 then
          return;
       end if;
       Busy := True;
       Widgets.Label (Status_Lbl.all).Set_Text ("loading...");
       Widgets.Gauge (Work_Gauge.all).Set_Fraction (1, 2);
       Ignore := Ntfn_Signal (Work_Gate, 1);
    end Work_Clicked;

    --  App-port messages, dispatched on the event-dispatch thread.
    procedure App_Message (Code, A0, A1, A2 : U64) is
    begin
       if Code = 1 then
          Busy := False;
          if A0 = U64 (Images.Status'Pos (Images.Ok))
            and then Img_Widget /= null
          then
             Widgets.Image_Widget (Img_Widget.all).Set_Image (Worker_Img);
             Images.Free (Swap_Img);
             Swap_Img := Worker_Img;
             Widgets.Label (Status_Lbl.all).Set_Text
               ("decoded" & A1'Image & " x" & A2'Image);
             Widgets.Gauge (Work_Gauge.all).Set_Fraction (1, 1);
          elsif A0 /= U64 (Images.Status'Pos (Images.Ok)) then
             Widgets.Label (Status_Lbl.all).Set_Text
               ("load failed:" & A0'Image);
             Widgets.Gauge (Work_Gauge.all).Set_Fraction (0, 1);
          end if;
       end if;
    end App_Message;


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
       Work_Grp : constant Widgets.Any_Widget :=
         Widgets.New_Group (Widgets.Horizontal, "Worker");
       Choice_Grp : constant Widgets.Any_Widget :=
         Widgets.New_Group (Widgets.Horizontal, "Choices");
       Font_Grp : constant Widgets.Any_Widget :=
         Widgets.New_Group (Widgets.Horizontal, "Font");
       Btn_Row  : constant Widgets.Any_Widget :=
         Widgets.New_Group (Widgets.Horizontal);
       --  M87e showcase: a two-page tab strip; switches report
       --  on the Worker group's status line. Pages are built
       --  below; kid order in Root = add order.
       Tabs_W   : constant Widgets.Any_Widget :=
         Widgets.New_Tabs (Tab_Moved'Access);
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

       --  The worker task publishes its gate handle at start; on
       --  SMP it may not have run yet (bounded wait — the Work
       --  button simply no-ops until the gate exists).
       Read_Clock (T0, NS);
       while Work_Gate = 0 loop
          Read_Clock (T1, NS);
          exit when T1 >= T0 + 5;
          Yield;
       end loop;


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
          Img_Widget := Widgets.New_Image (Bars_Img);
          Swap_Img := Bars_Img;
          Widgets.Group (Img_Grp.all).Add (Img_Widget);
       end if;
      if Keyed_St = Images.Ok then
         Widgets.Group (Img_Grp.all).Add (Widgets.New_Image (Keyed_Img));
      end if;
      if Bars_St /= Images.Ok and then Keyed_St /= Images.Ok then
         Widgets.Group (Img_Grp.all).Add
           (Widgets.New_Label ("Images unavailable"));
      end if;

       Status_Lbl := Widgets.New_Label ("idle", Inset => True);
       Work_Gauge := Widgets.New_Gauge;
       Widgets.Group (Work_Grp.all).Add
         (Widgets.New_Button ("Work", Work_Clicked'Access));
       Widgets.Group (Work_Grp.all).Add (Status_Lbl);
       Widgets.Group (Work_Grp.all).Add (Work_Gauge);
       Widgets.Group (Work_Grp.all).Add
         (Widgets.New_Slider (0, 100, Slider_Moved'Access));

       Widgets.Group (Btn_Row.all).Add
         (Widgets.New_Button ("Save", Save_Clicked'Access));
      Widgets.Group (Btn_Row.all).Add
        (Widgets.New_Button ("Revert", Revert_Clicked'Access));
      Widgets.Group (Btn_Row.all).Add
        (Widgets.New_Button ("Cancel", Cancel_Clicked'Access));
      --  M86c: a ghosted button to show the disabled state.
      Widgets.Group (Btn_Row.all).Add
        (Widgets.New_Button ("Ghost", Disabled => True));

      --  M86e: toggles — two checkboxes and a three-way radio
      --  set (Choice_Set enforces mutual exclusion).
      Widgets.Group (Choice_Grp.all).Add
        (Widgets.New_Checkbox
           ("Bold", Checked => True,
            On_Change => Choice_Toggled'Access));
      Widgets.Group (Choice_Grp.all).Add
        (Widgets.New_Checkbox
           ("Italic", On_Change => Choice_Toggled'Access));
      Widgets.Group (Choice_Grp.all).Add
        (Widgets.New_Radio
           ("Left", Choice_Set'Access, Selected => True,
            On_Change => Choice_Toggled'Access));
      Widgets.Group (Choice_Grp.all).Add
        (Widgets.New_Radio
           ("Center", Choice_Set'Access,
            On_Change => Choice_Toggled'Access));
      Widgets.Group (Choice_Grp.all).Add
        (Widgets.New_Radio
           ("Right", Choice_Set'Access,
            On_Change => Choice_Toggled'Access));

       --  M86f: the proportional default font — narrow i/l vs
       --  wide W/M in one string shows the per-glyph advance.
       Widgets.Group (Font_Grp.all).Add
         (Widgets.New_Label ("iiii llll vs WWW MMM"));

       --  Weights now only split the SLACK over each group's
       --  content minimum (M86g): Text (5 labels) and Images
       --  (64x48 bitmaps) keep the tall slices; the button rows
       --  and toggles stay thin.
       Widgets.Group (Root.all).Add (File_Grp, 3);
       Widgets.Group (Root.all).Add (Text_Grp, 6);
       Widgets.Group (Root.all).Add (Img_Grp, 6);
       Widgets.Group (Root.all).Add (Work_Grp, 4);
       Widgets.Group (Root.all).Add (Choice_Grp, 4);
       --  M87d showcase: the etched rule between groups.
       Widgets.Group (Root.all).Add (Widgets.New_Separator);
       Widgets.Group (Root.all).Add (Font_Grp, 3);
       --  M87e: the tab strip between the groups and the
       --  button row.
       declare
          Page1 : constant Widgets.Any_Widget :=
            Widgets.New_Group (Widgets.Vertical);
          Page2 : constant Widgets.Any_Widget :=
            Widgets.New_Group (Widgets.Vertical);
       begin
          Widgets.Group (Page1.all).Add
            (Widgets.New_Label ("First tab page"));
          Widgets.Group (Page1.all).Add
            (Widgets.New_Label ("labels, centered",
             Widgets.Center));
          Widgets.Group (Page2.all).Add
            (Widgets.New_Label ("Second tab page"));
          Widgets.Group (Page2.all).Add
            (Widgets.New_Label ("pages swap on click"));
          Widgets.Tabs (Tabs_W.all).Add_Tab ("One", Page1);
          Widgets.Tabs (Tabs_W.all).Add_Tab ("Two", Page2);
       end;
       Widgets.Group (Root.all).Add (Tabs_W, 3);
       Widgets.Group (Root.all).Add (Btn_Row, 4);

       if Trinket.Window.Open
         (Win, 3, 400, 420, "Trinket Demo", Root)
       then
          Trinket.Window.Set_App_Handler (Win, App_Message'Access);
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
