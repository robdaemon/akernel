with Akernel_User.CLI;
with Akernel_User.Files;
with Akernel_User.Syscalls;
with Akernel_User.Window;
with System.Storage_Elements;
with Trinket.Fonts;
with Trinket.Iconview;
with Trinket.Images;
with Trinket.Menus;
with Trinket.Widgets;
with Trinket.Window;

package body Desktop_App is
   use Akernel_User.Syscalls;
   use type Akernel_User.Syscalls.U64;
   package Widgets renames Trinket.Widgets;
   package CLI renames Akernel_User.CLI;
   package Files renames Akernel_User.Files;
   package IV renames Trinket.Iconview;
   package Images renames Trinket.Images;
   package Win renames Akernel_User.Window;

   Console_EP : constant U64 := 1;  --  uniform ABI handles
   FS_EP      : constant U64 := 2;
   Bureau_EP  : constant U64 := 3;
   --  M94: Startup programs now receive the full command ABI —
   --  elevation at own handle 5, netserv at 6 (args at 4) — so
   --  Desktop can hand its children the same uniform layout.
   Elevated_EP : constant U64 := 5;
   Net_EP      : constant U64 := 6;

   Win_H : Trinket.Window.Window;

   Max_Volumes : constant := 32;

   --  Volume names, parallel to the iconview's item order.
   type Name_Rec is record
      Text : String (1 .. 16) := (others => ' ');
      Len  : Natural := 0;
   end record;
   Volumes : array (1 .. Max_Volumes) of Name_Rec;
   N_Volumes : Natural := 0;

   Volume_Icon : aliased Images.Image;

   Icons : IV.Any_Iconview;

   --  Poll the fileserver's volume table (Op_List_Volumes).
   --  fs-driver volumes only, and among those only real DISKS:
   --  virtual filesystems (Proc, Net) and boot-file volumes
   --  answer Op_Volume_Info with Bad_Args — capacity is the
   --  discriminator, no new wire op needed.
   procedure Reload is
      Idx   : U64 := 0;
      Name  : String (1 .. 24);
      N_Len : Natural;
      Kind  : U64;
      St    : U64;
      Total, Free, Clust : U64;
   begin
      IV.Clear (Icons.all);
      N_Volumes := 0;
      loop
         St := Files.Volume_List (Idx, Name, N_Len, Kind);
         exit when St /= Files.Status_Ok;
         if Kind = Files.Vol_Kind_FS
           and then Files.Volume_Info
             (Name (Name'First .. Name'First + N_Len - 1) & ":",
              Total, Free, Clust) = Files.Status_Ok
           and then N_Volumes < Max_Volumes
         then
            N_Volumes := N_Volumes + 1;
            declare
               V  : Name_Rec renames Volumes (N_Volumes);
               N  : constant Natural :=
                 Natural'Min (N_Len, V.Text'Length);
            begin
               V.Len := N;
               if N > 0 then
                  V.Text (1 .. N) := Name (Name'First .. Name'First + N - 1);
               end if;
               IV.Add_Item
                 (Icons.all, V.Text (1 .. V.Len), Volume_Icon'Access);
            end;
         end if;
         Idx := Idx + 1;
      end loop;
   end Reload;

   --  Double-click: open the volume in a Drawer window. Startup
   --  programs now hold the full command ABI (elevation at 5,
   --  netserv at 6), so spawn the Drawer with that same uniform
   --  6-handle layout — the Drawer can then Scripting.Spawn_Cmd
   --  its own children (M92's 4-handle workaround retired).
   procedure Spawn_Drawer (Path : String) is
      Stage_VA : constant U64 := 16#5E00_0000#;
      Image_Path : constant String := "Sys:System/Drawer";
      Size    : U64 := 0;
      Pages   : U64;
      Off     : U64 := 0;
      Chunk   : U64;
      Count   : U64 := 0;
      Mem_Cap : U64;
      Proc_Cap : U64;
      Args_Cap : U64;
      Result  : U64;
      St      : U64;
   begin
      St := Files.Stat (Image_Path, Size);
      if St /= Files.Status_Ok or else Size = 0 then
         Debug_Put_Line ("desktop: drawer image missing");
         return;
      end if;

      Pages := (Size + 4095) / 4096;
      Mem_Cap := Mem_Alloc (Pages);
      if Mem_Cap = Syscall_Failed then
         return;
      end if;

      if Mem_Map (Address_Space_Cap, Mem_Cap,
                  Stage_VA, 0, Pages * 4096, 3) /= 0
      then
         Result := Cap_Delete (Mem_Cap);
         return;
      end if;

      St := Files.Open (Image_Path, Size);
      while St = Files.Status_Ok and then Off < Size loop
         Chunk := U64'Min (Size - Off, 32768);
         St := Files.Read
           (Image_Path, Off,
            System.Storage_Elements.To_Address
              (System.Storage_Elements.Integer_Address
                 (Stage_VA + Off)),
            Chunk, Count);
         exit when St /= Files.Status_Ok or else Count /= Chunk;
         Off := Off + Chunk;
      end loop;

      Result := Mem_Unmap (Address_Space_Cap, Stage_VA, Pages * 4096);

      if Off < Size then
         Result := Cap_Delete (Mem_Cap);
         return;
      end if;

      Args_Cap := Mem_Alloc (1);
      if Args_Cap = Syscall_Failed then
         Result := Cap_Delete (Mem_Cap);
         return;
      end if;

      if Mem_Map (Address_Space_Cap, Args_Cap,
                  Args_VA, 0, 4096, 3) = 0
      then
         declare
            Page : String (1 .. 4096)
              with Address => System.Storage_Elements.To_Address
                (System.Storage_Elements.Integer_Address (Args_VA));
         begin
            Page := (others => Character'Val (0));
            Page (1 .. Path'Length) := Path;
         end;
         Result := Mem_Unmap (Address_Space_Cap, Args_VA, 4096);
      end if;

      Set_Grant (0, Console_EP, Right_Send, 0);
      Set_Grant (1, FS_EP, Right_Send, 0);
      Set_Grant (2, Bureau_EP, Right_Send, 0);
      Set_Grant (3, Args_Cap, Right_Map + Right_Read, 0);
      Set_Grant (4, Elevated_EP, Right_Send, 0);
      Set_Grant (5, Net_EP, Right_Send, 0);
      if Spawn (Mem_Cap, 6, Proc_Cap) /= Spawn_Ok
        or else Proc_Cap = 0
      then
         Debug_Put_Line ("desktop: drawer spawn failed");
      end if;
      Result := Cap_Delete (Args_Cap);
      Result := Cap_Delete (Mem_Cap);
      pragma Unreferenced (Result);
   end Spawn_Drawer;

   procedure Volume_Opened (Index : Natural) is
   begin
      if Index = 0 or else Index > N_Volumes then
         return;
      end if;
      Spawn_Drawer (Volumes (Index).Text (1 .. Volumes (Index).Len) & ":");
   end Volume_Opened;

   procedure Menu_Picked (Id : U64) is
   begin
      if Id = 1 then
         Reload;               --  Refresh
      end if;
   end Menu_Picked;

   procedure Main is
      Scr_W : U64 := 0;
      Scr_H : U64 := 0;
      St    : U64;
      ISt   : Images.Status;
   begin
      Icons := IV.New_Iconview;
      declare
         Root : constant Widgets.Any_Widget :=
           Widgets.Any_Widget (Icons);
      begin
      CLI.Init;
      Files.Bind (2);
      Trinket.Fonts.Init;
      Images.Load ("Sys:System/Icons32/VOLUME.XPM", Volume_Icon, ISt);
      if not Images.Loaded (Volume_Icon) then
         Debug_Put_Line ("desktop: volume icon missing");
         return;
      end if;

      --  Current screen geometry (pure query).
      St := Win.Set_Screen_Mode (Bureau_EP, 0, 0, Scr_W, Scr_H);
      if St /= Win.Status_Ok or else Scr_W = 0
        or else Scr_H <= Win.Screen_Bar_H + 2
      then
         Debug_Put_Line ("desktop: screen mode query failed");
         return;
      end if;

      Reload;

      --  The backdrop: full screen below the bar, borderless,
      --  never raises. Mode switches re-fill the screen through
      --  the kind-6 handshake (Trinket answers it).
      if Trinket.Window.Open
        (Win_H, Bureau_EP,
         Scr_W, Scr_H - Win.Screen_Bar_H - 1,
         "Desktop", Root,
         Resizable => False,
         Flags     => Win.Flag_Backdrop or Win.Flag_Borderless,
         Pos_X     => 0,
         Pos_Y     => Win.Screen_Bar_H + 1)
      then
         Trinket.Window.Set_Menus
           (Win_H,
            (1 => Trinket.Menus.M
               ("Desktop", (1 => Trinket.Menus.It (1, "Refresh")))));
         Trinket.Window.Set_Menu_Handler (Win_H, Menu_Picked'Access);
         IV.Set_On_Double_Click (Icons.all, Volume_Opened'Access);
         Debug_Put_Line ("desktop online");
         Trinket.Window.Run (Win_H);
         Trinket.Window.Close (Win_H);
      else
         Debug_Put_Line ("desktop: window open failed");
      end if;
      end;
   end Main;

end Desktop_App;
