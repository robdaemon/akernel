with Ada.Directories;
with System;
with System.Storage_Elements;
with Akernel_User.CLI;
with Akernel_User.Syscalls;
with Akernel_User.Files;
with Trinket;
with Trinket.Images;
with Trinket.Widgets;
with Trinket.Widgets.Input;
with Trinket.Widgets.Label;
with Trinket.Widgets.Button;
with Trinket.Listview;
with Trinket.Window;
with Trinket.Menus;

package body Fileman_App is

   package CLI renames Akernel_User.CLI;
   package Dirs renames Ada.Directories;
   package Syscalls renames Akernel_User.Syscalls;
   package Files renames Akernel_User.Files;
   package Images renames Trinket.Images;

   use type Syscalls.U64;
   use type Trinket.U64;
   use type Dirs.File_Kind;

   --  Uniform program ABI for this Startup-spawned program.
   Console_EP : constant Syscalls.U64 := 1;
   FS_EP      : constant Syscalls.U64 := 2;
   Bureau_EP  : constant Syscalls.U64 := 3;
   --  M94: Startup programs receive the full command ABI — args at
   --  4, elevation at 5, netserv at 6 — so children (Edit etc.)
   --  are spawned with that same uniform layout.
   Elevated_EP : constant Syscalls.U64 := 5;
   Net_EP      : constant Syscalls.U64 := 6;

   Win : Trinket.Window.Window;

   --  M84: Directory-Opus-style dual-pane lister. Each pane owns
   --  its current path, an editable path gadget above the list
   --  (Enter navigates that pane), the listview and its
   --  scrollbar. Clicking anywhere in a pane makes it ACTIVE;
   --  the button bar and the name field operate on the active
   --  pane. Copy/Move default to "selection -> other pane".
   type Pane_Rec is record
      Path       : access String := null;
      List       : Trinket.Listview.Any_Listview;
      Path_Input : Trinket.Widgets.Any_Widget;
   end record;
   Panes  : array (1 .. 2) of Pane_Rec;
   Active : Positive := 1;

   Status_Label : Trinket.Widgets.Any_Widget;
   Name_Input   : Trinket.Widgets.Any_Widget;

   --  Deficons (milestone 64): Workbench-style default icons,
   --  XPM text assets loaded from Sys:System/Icons/ once at
   --  startup. The listview borrows them; they live as long as
   --  the app. Absent icons degrade to plain text rows.
   Drawer_Img : aliased Images.Image;
   File_Img   : aliased Images.Image;
   Tool_Img   : aliased Images.Image;

   --  Sniff the ELF magic to tell tools from projects; bounded
   --  so a giant directory never turns into an RPC storm.
   Max_Sniff : constant := 256;

   --  Root group with pane-aware key routing (M84). Both
   --  listviews consume the navigation keys and Group's reverse
   --  add-order walk would always steer them to ONE pane, so
   --  route explicitly: a focused Input first (it gates on
   --  Focused itself), then the active pane's list, then the
   --  other pane's list.
   type Root_Group is new Trinket.Widgets.Group with null record;
   overriding function On_Key
     (W : access Root_Group; Code : Trinket.U64) return Boolean;

   function On_Key
     (W : access Root_Group; Code : Trinket.U64) return Boolean
   is
      pragma Unreferenced (W);
      function Try_Input
        (Any : Trinket.Widgets.Any_Widget) return Boolean
      is
      begin
         return Any.all.Is_Focused
           and then Any.On_Key (Code);
      end Try_Input;
   begin
      if Try_Input (Panes (1).Path_Input)
        or else Try_Input (Panes (2).Path_Input)
        or else Try_Input (Name_Input)
      then
         return True;
      end if;
      if Panes (Active).List.On_Key (Code) then
         return True;
      end if;
      return Panes (3 - Active).List.On_Key (Code);
   end On_Key;

   procedure Set_Status (S : String);
   procedure Set_Active (P : Positive);
   procedure Selection_Changed_L (Index : Natural);
   procedure Selection_Changed_R (Index : Natural);
   procedure Press_L;
   procedure Press_R;
   procedure Path_Commit_L;
   procedure Path_Commit_R;
   procedure Open_Clicked;
   procedure Double_L (Index : Natural);
   procedure Double_R (Index : Natural);
   procedure Parent_Clicked;
   procedure Copy_Clicked;
   procedure Move_Clicked;
   procedure Rename_Clicked;
   procedure Swap_Clicked;
   procedure Newdir_Clicked;
   procedure Delete_Clicked;
   procedure Quit_Clicked;
   procedure Menu_Picked (Id : Syscalls.U64);
   procedure Load_Directory (P : Positive; Path : String);
   procedure Reload (P : Positive);
   procedure Spawn_Edit (Path : String);

   --  Phase B incremental fill (see the bodies).
   App_Code_Fill : constant Syscalls.U64 := 1;
   procedure Fill_More (Code, A0, A1, A2 : Syscalls.U64);

   procedure Set_Status (S : String) is
   begin
      Trinket.Widgets.Label.Set_Text
        (Trinket.Widgets.Label.Label (Status_Label.all), S);
   end Set_Status;

   --  Pane activation: click or selection in a pane makes it the
   --  button bar's target; the status line carries the marker.
   procedure Set_Active (P : Positive) is
   begin
      if P /= Active then
         Active := P;
         Set_Status
           ((if P = 1 then "Left pane active"
             else "Right pane active"));
      end if;
   end Set_Active;

   --  Selecting an entry activates its pane, pre-fills the name
   --  field (rename edits in place, Workbench style) and drops
   --  input focus so the arrows belong to the list again.
   procedure Selection_Changed (P : Positive; Index : Natural) is
   begin
      Set_Active (P);
      Panes (1).Path_Input.all.Set_Focused (False);
      Panes (2).Path_Input.all.Set_Focused (False);
      Name_Input.all.Set_Focused (False);
      if Index > 0 then
         Trinket.Widgets.Input.Set_Text
           (Trinket.Widgets.Input.Input (Name_Input.all),
            Trinket.Listview.Get_Item (Panes (P).List.all, Index));
      end if;
   end Selection_Changed;

   procedure Selection_Changed_L (Index : Natural) is
   begin
      Selection_Changed (1, Index);
   end Selection_Changed_L;

   procedure Selection_Changed_R (Index : Natural) is
   begin
      Selection_Changed (2, Index);
   end Selection_Changed_R;

   procedure Press_L is
   begin
      Set_Active (1);
   end Press_L;

   procedure Press_R is
   begin
      Set_Active (2);
   end Press_R;

   --  Full path of the selected entry in pane P, or "" when
   --  nothing is selected.
   function Selected_Full (P : Positive) return String is
      Idx : constant Natural :=
        Trinket.Listview.Selected (Panes (P).List.all);
   begin
      if Idx = 0 then
         return "";
      end if;
      return CLI.Join_Path
        (Panes (P).Path.all,
         Trinket.Listview.Get_Item (Panes (P).List.all, Idx));
   end Selected_Full;

   --  The name field as a path: qualified stays as typed, bare
   --  names resolve inside pane P's directory.
   function Field_Path (P : Positive) return String is
      T : constant String :=
        Trinket.Widgets.Input.Get_Text
          (Trinket.Widgets.Input.Input (Name_Input.all));
   begin
      if T'Length = 0 then
         return "";
      end if;
      for Ch of T loop
         if Ch = ':' then
            return T;
         end if;
      end loop;
      return CLI.Join_Path (Panes (P).Path.all, T);
   end Field_Path;

   --  Refresh pane P after a mutating action.
   procedure Reload (P : Positive) is
   begin
      Load_Directory (P, Panes (P).Path.all);
   end Reload;

   --  Path gadget commit: a ':' anywhere keeps the text
   --  qualified (volume switch included), a bare name resolves
   --  against the pane's own directory. Enter must name a
   --  drawer; anything else reverts the gadget.
   procedure Path_Commit (P : Positive) is
      T : constant String :=
        Trinket.Widgets.Input.Get_Text
          (Trinket.Widgets.Input.Input (Panes (P).Path_Input.all));
      Qualified : Boolean := False;
   begin
      if T'Length = 0 then
         Trinket.Widgets.Input.Set_Text
           (Trinket.Widgets.Input.Input (Panes (P).Path_Input.all),
            Panes (P).Path.all);
         return;
      end if;
      for Ch of T loop
         if Ch = ':' then
            Qualified := True;
         end if;
      end loop;
      declare
         Target : constant String :=
           CLI.Normalize_Path
             ((if Qualified then T
               else CLI.Join_Path (Panes (P).Path.all, T)));
      begin
         if Dirs.Exists (Target)
           and then Dirs.Kind (Target) = Dirs.Directory
         then
            Load_Directory (P, Target);
            Set_Active (P);
            --  Editing is done; arrows belong to the list.
            Panes (P).Path_Input.all.Set_Focused (False);
         else
            Set_Status ("No such drawer");
            Trinket.Widgets.Input.Set_Text
              (Trinket.Widgets.Input.Input (Panes (P).Path_Input.all),
               Panes (P).Path.all);
         end if;
      exception
         when others =>
            Set_Status ("No such drawer");
            Trinket.Widgets.Input.Set_Text
              (Trinket.Widgets.Input.Input (Panes (P).Path_Input.all),
               Panes (P).Path.all);
      end;
   end Path_Commit;

   procedure Path_Commit_L is
   begin
      Path_Commit (1);
   end Path_Commit_L;

   procedure Path_Commit_R is
   begin
      Path_Commit (2);
   end Path_Commit_R;

   procedure Spawn_Edit (Path : String) is
      Stage_VA : constant Syscalls.U64 := 16#5E00_0000#;
      --  Child-args STAGING VA, NOT Syscalls.Args_VA (0x4800_0000):
      --  since M94 every Startup program holds its own args page at
      --  handle 4, lazily mapped at 0x4800_0000 by CLI.Init; a second
      --  map there for the child's args page fails, so spawned Edits
      --  got no filename. Mirrors Scripting.Exec's Args_Stage_VA
      --  (0x5440_0000); free in this app's VA map.
      Args_Stage_VA : constant Syscalls.U64 := 16#5440_0000#;
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
                           Args_Stage_VA, 0, 4096, 3) = 0
      then
         declare
            Page : String (1 .. 4096)
              with Address => System.Storage_Elements.To_Address
                (System.Storage_Elements.Integer_Address
                   (Args_Stage_VA));
         begin
            Page := (others => Character'Val (0));
            Page (1 .. Path'Length) := Path;
         end;
         Result := Syscalls.Mem_Unmap
           (Syscalls.Address_Space_Cap, Args_Stage_VA, 4096);
      end if;

      Syscalls.Set_Grant (0, Console_EP, Syscalls.Right_Send, 0);
      Syscalls.Set_Grant (1, FS_EP, Syscalls.Right_Send, 0);
      Syscalls.Set_Grant (2, Bureau_EP, Syscalls.Right_Send, 0);
      Syscalls.Set_Grant (3, Args_Cap,
                          Syscalls.Right_Map + Syscalls.Right_Read, 0);
      Syscalls.Set_Grant (4, Elevated_EP, Syscalls.Right_Send, 0);
      Syscalls.Set_Grant (5, Net_EP, Syscalls.Right_Send, 0);
      Result := Syscalls.Spawn (Mem_Cap, 6, Proc_Cap);
      Result := Syscalls.Cap_Delete (Args_Cap);
      Result := Syscalls.Cap_Delete (Mem_Cap);
      pragma Unreferenced (Result);
   end Spawn_Edit;

   --  Incremental directory fill (Phase B) with a SORTED listing:
   --  entries are buffered during the pumped read, then committed
   --  in folders-first, name order matching the volume's case
   --  behavior once the whole directory has been enumerated. The
   --  first chunk reads synchronously; the rest is pumped one
   --  chunk per loop turn via the app port (self-posted
   --  App_Code_Fill), so opening a huge drawer never freezes the
   --  UI — the pane fills (sorted) when its read completes. The
   --  enumeration is index-based Files.Read_Dir (the M94 drawer
   --  idiom): each entry's is-directory flag and size come back
   --  for free — no per-entry libc stat() — and the cursor is
   --  resumable across calls, so no OS search handle needs
   --  parking. ALL file-server and widget work stays on the
   --  event-loop thread: Files.Bind's single client buffer cap is
   --  process-wide, so a background task would race the click
   --  handlers' own reads (the reason this is a pump, not a
   --  worker thread).
   Fill_Chunk_Size : constant := 32;

   --  Sorted listing (user request): entries are BUFFERED during
   --  the pumped read, then committed sorted — folders first, then
   --  by name with a comparator matching the volume's case
   --  behavior (Files.Volume_Case: BeFS folds nothing, FAT/initrd
   --  fold). A sorted view cannot stream rows as they are read, so
   --  a pane fills once its directory has been fully enumerated
   --  (the pump keeps the window live; a 'Reading...' status shows
   --  while a large directory is pending).
   Max_Rows : constant := 512;   --  lister cap (drawer's Max_Entries)

   type Row_Rec is record
      Name   : String (1 .. 255) := (others => ' ');
      Len    : Natural := 0;
      Is_Dir : Boolean := False;
      Is_Tool : Boolean := False;  --  ELF magic (tool glyph)
   end record;
   Rows : array (1 .. 2, 1 .. Max_Rows) of Row_Rec;

   type Fill_State is record
      Active  : Boolean := False;
      Idx     : Syscalls.U64 := 0;  --  next Read_Dir index
      Sniffed : Natural := 0;       --  ELF sniffs in this listing
      Rows    : Natural := 0;       --  buffered entries so far
      CI      : Boolean := False;   --  volume folds case
   end record;
   Fill : array (1 .. 2) of Fill_State;

   --  Startup-fill telemetry (the drawer's t= convention): the
   --  fully-filled instant, so a slow initial listing is visible
   --  in the boot log. Only the STARTUP fills are tracked; later
   --  navigations stay quiet.
   Load_T0   : Syscalls.U64 := 0;
   Track_Startup : Boolean := False;

   function Pane_Rows return Natural is
     (Trinket.Listview.Item_Count (Panes (1).List.all)
        + Trinket.Listview.Item_Count (Panes (2).List.all));

   --  ELF magic decides tool vs plain file (the drawer's rule).
   function Is_Elf (Path : String) return Boolean is
      Size  : Syscalls.U64 := 0;
      Count : Syscalls.U64 := 0;
      B4    : String (1 .. 4) := "    ";
      St    : Syscalls.U64;
   begin
      St := Files.Open (Path, Size);
      if St = Files.Status_Ok and then Size >= 4 then
         St := Files.Read (Path, 0, B4'Address, 4, Count);
      end if;
      return Count = 4
        and then B4 (1) = Character'Val (16#7F#)
        and then B4 (2 .. 4) = "ELF";
   end Is_Elf;

   --  Buffer one entry of pane P's listing (name + kind + sniffed
   --  tool bit). Nothing touches the listview during the read.
   procedure Record_Row (P : Positive; Leaf : String;
                         Is_Dir : Boolean) is
   begin
      if Fill (P).Rows >= Max_Rows then
         return;   --  lister cap: the surplus is not shown
      end if;
      Fill (P).Rows := Fill (P).Rows + 1;
      declare
         R : Row_Rec renames Rows (P, Fill (P).Rows);
         N : constant Natural :=
           Natural'Min (Leaf'Length, R.Name'Length);
      begin
         R.Len := N;
         if N > 0 then
            R.Name (1 .. N) :=
              Leaf (Leaf'First .. Leaf'First + N - 1);
         end if;
         R.Is_Dir := Is_Dir;
         R.Is_Tool := False;
         if not Is_Dir and then Fill (P).Sniffed < Max_Sniff then
            Fill (P).Sniffed := Fill (P).Sniffed + 1;
            R.Is_Tool := Is_Elf
              (CLI.Join_Path (Panes (P).Path.all, Leaf));
         end if;
      end;
   exception
      when others =>
         null;   --  one odd entry, no row
   end Record_Row;

   --  Folders first, then name order; CI folds ASCII case first
   --  (dictionary order on case-insensitive volumes), otherwise a
   --  plain byte compare (BeFS). Longer name sorts after when the
   --  shared prefix ties.
   function Before (A, B : Row_Rec; CI : Boolean) return Boolean is
   begin
      if A.Is_Dir /= B.Is_Dir then
         return A.Is_Dir;
      end if;
      for I in 1 .. Natural'Min (A.Len, B.Len) loop
         declare
            CA : Character := A.Name (I);
            CB : Character := B.Name (I);
         begin
            if CI then
               if CA in 'a' .. 'z' then
                  CA := Character'Val (Character'Pos (CA) - 32);
               end if;
               if CB in 'a' .. 'z' then
                  CB := Character'Val (Character'Pos (CB) - 32);
               end if;
            end if;
            if CA /= CB then
               return CA < CB;
            end if;
         end;
      end loop;
      return A.Len < B.Len;
   end Before;

   --  Sort pane P's buffer (insertion sort; <= Max_Rows) and add
   --  the rows to the listview with their glyphs, then select
   --  row 1. Runs when the pane's enumeration completes.
   procedure Commit_Rows (P : Positive) is
      N : constant Natural := Fill (P).Rows;
   begin
      for I in 2 .. N loop
         declare
            T : Row_Rec := Rows (P, I);
            J : Natural := I;
         begin
            while J > 1 and then
              not Before (Rows (P, J - 1), T, Fill (P).CI)
            loop
               Rows (P, J) := Rows (P, J - 1);
               J := J - 1;
            end loop;
            Rows (P, J) := T;
         end;
      end loop;
      for I in 1 .. N loop
         declare
            R : Row_Rec renames Rows (P, I);
         begin
            --  Row index == I: the list was cleared when the fill
            --  started and nothing else adds while it runs.
            Trinket.Listview.Add_Item
              (Panes (P).List.all, R.Name (1 .. R.Len));
            if R.Is_Dir then
               if Images.Loaded (Drawer_Img) then
                  Trinket.Listview.Set_Item_Icon
                    (Panes (P).List.all, I, Drawer_Img'Access);
               end if;
            elsif R.Is_Tool and then Images.Loaded (Tool_Img) then
               Trinket.Listview.Set_Item_Icon
                 (Panes (P).List.all, I, Tool_Img'Access);
            elsif Images.Loaded (File_Img) then
               Trinket.Listview.Set_Item_Icon
                 (Panes (P).List.all, I, File_Img'Access);
            end if;
         end;
      end loop;
      Fill (P).Rows := 0;
      if N > 0 then
         Trinket.Listview.Set_Selected (Panes (P).List.all, 1);
      end if;
      if not Fill (P).Active
        and then not Fill (3 - P).Active
      then
         Set_Status
           ((if Active = 1 then "Left pane active"
             else "Right pane active"));
      end if;
   end Commit_Rows;

   --  Buffer up to Fill_Chunk_Size pending entries of pane P's
   --  listing; at the end of the directory, sort and commit.
   procedure Fill_Chunk (P : Positive) is
      Idx  : Syscalls.U64 := Fill (P).Idx;
      E_Nm : String (1 .. 256);
      E_L  : Natural;
      E_D  : Boolean;
      E_S  : Syscalls.U64;
      St   : Syscalls.U64;
      Done : Natural := 0;
   begin
      while Fill (P).Active and then Done < Fill_Chunk_Size loop
         St := Files.Read_Dir
           (Panes (P).Path.all, Idx, E_Nm, E_L, E_D, E_S);
         if St /= Files.Status_Ok then
            --  Not_Found = end of the directory.
            Fill (P).Active := False;
         else
            Idx := Idx + 1;
            Done := Done + 1;
            Record_Row (P, E_Nm (1 .. E_L), E_D);
         end if;
      end loop;
      Fill (P).Idx := Idx;
      if not Fill (P).Active then
         Commit_Rows (P);
      end if;
   end Fill_Chunk;

   --  Begin a (possibly chunked) listing of Path in pane P: the
   --  first chunk reads synchronously; remaining chunks are
   --  pumped by the event loop. Rows appear sorted once the whole
   --  directory has been read.
   procedure Start_Fill (P : Positive; Path : String) is
   begin
      Panes (P).Path := new String'(Path);
      Trinket.Widgets.Input.Set_Text
        (Trinket.Widgets.Input.Input (Panes (P).Path_Input.all), Path);
      Trinket.Listview.Clear (Panes (P).List.all);
      Fill (P) := (Active => True, Idx => 0, Sniffed => 0,
                   Rows => 0, CI => False);
      declare
         CI : Boolean := False;
      begin
         if Files.Volume_Case (Path, CI) = Files.Status_Ok then
            Fill (P).CI := CI;
         end if;
      end;
      Fill_Chunk (P);
      if Fill (P).Active then
         Set_Status ("Reading " & Path & "...");
         --  Wake the event loop to pump the remaining chunks.
         if not Trinket.Window.Post (Win, App_Code_Fill, 0, 0, 0) then
            null;   --  ring full: a self-post is already pending
         end if;
      end if;
   end Start_Fill;

   --  Event-loop pump: one chunk per active pane per turn. Runs
   --  on the window thread only (widget- and FS-safe); posts
   --  itself until both listings are complete.
   procedure Fill_More (Code, A0, A1, A2 : Syscalls.U64) is
   begin
      if Code /= App_Code_Fill then
         return;
      end if;
      for P in 1 .. 2 loop
         if Fill (P).Active then
            Fill_Chunk (P);
         end if;
      end loop;
      if Fill (1).Active or else Fill (2).Active then
         if not Trinket.Window.Post (Win, App_Code_Fill, 0, 0, 0) then
            null;   --  ring full: a self-post is already pending
         end if;
      elsif Track_Startup then
         Track_Startup := False;
         Syscalls.Debug_Put_Line ("fileman: filled " & Natural'Image (Pane_Rows)
                         & " rows t="
                         & Syscalls.U64'Image
                           (Syscalls.Read_Time - Load_T0));
      end if;
   end Fill_More;

   procedure Load_Directory (P : Positive; Path : String) is
   begin
      Start_Fill (P, Path);
   end Load_Directory;

   --  Open entry Index of pane P: drawers navigate, files go to
   --  the editor.  Shared by the Open button and the listview's
   --  double-click callback (M84c).
   procedure Open_Item (P : Positive; Index : Natural) is
      Name : String :=
        Trinket.Listview.Get_Item (Panes (P).List.all, Index);
      Full : constant String :=
        CLI.Join_Path (Panes (P).Path.all, Name);
   begin
      if Index = 0 then
         return;
      end if;

      begin
         if Dirs.Exists (Full)
           and then Dirs.Kind (Full) = Dirs.Directory
         then
            Load_Directory (P, CLI.Normalize_Path (Full));
         else
            Spawn_Edit (Full);
         end if;
      exception
         when Dirs.Name_Error | Dirs.Use_Error =>
            null;
      end;
   end Open_Item;

   procedure Open_Clicked is
   begin
      Open_Item
        (Active, Trinket.Listview.Selected (Panes (Active).List.all));
   end Open_Clicked;

   procedure Double_L (Index : Natural) is
   begin
      Open_Item (1, Index);
   end Double_L;

   procedure Double_R (Index : Natural) is
   begin
      Open_Item (2, Index);
   end Double_R;

   procedure Parent_Clicked is
      Parent : constant String :=
        CLI.Normalize_Path
          (CLI.Join_Path (Panes (Active).Path.all, "/"));
   begin
      Load_Directory (Active, Parent);
   end Parent_Clicked;

   --  Destination of a Copy/Move: the name field when typed,
   --  else the OTHER pane's directory under the same simple
   --  name (the Dopus default).
   function Copy_Dest (Src : String) return String is
      Dst : constant String := Field_Path (Active);
   begin
      if Dst'Length > 0 then
         return Dst;
      end if;
      return CLI.Join_Path
        (Panes (3 - Active).Path.all, Dirs.Simple_Name (Src));
   end Copy_Dest;

   procedure Copy_Clicked is
      Src : constant String := Selected_Full (Active);
   begin
      if Src'Length = 0 then
         Set_Status ("Select first");
         return;
      end if;
      begin
         Dirs.Copy_File (Src, Copy_Dest (Src));
         Set_Status ("Copied");
         Reload (3 - Active);
         if Panes (3 - Active).Path.all = Panes (Active).Path.all then
            Reload (Active);
         end if;
      exception
         when others =>
            Set_Status ("Copy failed");
      end;
   end Copy_Clicked;

   --  Move: same-volume renames ride the fs rename op (drawers
   --  included); cross-volume falls back to copy + delete and
   --  is files-only.
   procedure Move_Clicked is
      Src : constant String := Selected_Full (Active);
   begin
      if Src'Length = 0 then
         Set_Status ("Select first");
         return;
      end if;
      declare
         Dst : constant String := Copy_Dest (Src);
      begin
         Dirs.Rename (Src, Dst);
         Set_Status ("Moved");
      exception
         when others =>
            if Dirs.Exists (Src)
              and then Dirs.Kind (Src) = Dirs.Directory
            then
               Set_Status ("Move failed (drawer)");
               return;
            end if;
            begin
               Dirs.Copy_File (Src, Dst);
               Dirs.Delete_File (Src);
               Set_Status ("Moved");
            exception
               when others =>
                  Set_Status ("Move failed");
                  return;
            end;
      end;
      Reload (1);
      Reload (2);
   end Move_Clicked;

   procedure Rename_Clicked is
      Src : constant String := Selected_Full (Active);
      Dst : constant String := Field_Path (Active);
   begin
      if Src'Length = 0 or else Dst'Length = 0 then
         Set_Status ("Select and name first");
         return;
      end if;
      begin
         Dirs.Rename (Src, Dst);
         Set_Status ("Renamed");
         Reload (Active);
      exception
         when others =>
            Set_Status ("Rename failed");
      end;
   end Rename_Clicked;

   --  Swap: exchange the panes' directories (the Dopus
   --  left<->right flip); selections reset with the reload.
   procedure Swap_Clicked is
      S1 : constant String := Panes (1).Path.all;
      S2 : constant String := Panes (2).Path.all;
   begin
      Load_Directory (1, S2);
      Load_Directory (2, S1);
      Set_Status ("Panes swapped");
   end Swap_Clicked;

   procedure Newdir_Clicked is
      Dst : constant String := Field_Path (Active);
   begin
      if Dst'Length = 0 then
         Set_Status ("Type a drawer name");
         return;
      end if;
      begin
         Dirs.Create_Directory (Dst);
         Set_Status ("Drawer created");
         Reload (Active);
      exception
         when others =>
            Set_Status ("New drawer failed");
      end;
   end Newdir_Clicked;

   procedure Delete_Clicked is
      Src : constant String := Selected_Full (Active);
   begin
      if Src'Length = 0 then
         Set_Status ("Select first");
         return;
      end if;
      begin
         if Dirs.Exists (Src)
           and then Dirs.Kind (Src) = Dirs.Directory
         then
            Dirs.Delete_Directory (Src);   --  empty drawers only
         else
            Dirs.Delete_File (Src);
         end if;
         Set_Status ("Deleted");
         Reload (Active);
      exception
         when others =>
            Set_Status ("Delete failed");
      end;
   end Delete_Clicked;

   procedure Quit_Clicked is
   begin
      Trinket.Window.Request_Quit (Win);
   end Quit_Clicked;

   --  Screen-bar menu (milestone 61): File mirrors the button
   --  bar (M84: all nine actions, one row).
   procedure Menu_Picked (Id : Syscalls.U64) is
   begin
      if Id = 1 then
         Open_Clicked;
      elsif Id = 2 then
         Parent_Clicked;
      elsif Id = 3 then
         Copy_Clicked;
      elsif Id = 4 then
         Move_Clicked;
      elsif Id = 5 then
         Rename_Clicked;
      elsif Id = 6 then
         Swap_Clicked;
      elsif Id = 7 then
         Newdir_Clicked;
      elsif Id = 8 then
         Delete_Clicked;
      elsif Id = 9 then
         Quit_Clicked;
      end if;
   end Menu_Picked;

   procedure Main is
      Root : constant Trinket.Widgets.Any_Widget := new Root_Group'
        (X => 0, Y => 0, W => 0, H => 0, Dirty => True,
         Tab_Rank  => 0,
         Focused   => False,
         Dir       => Trinket.Widgets.Vertical,
         Title     => "File Manager            ",
         Title_Len => 12,
         Inset     => False,
         Kids      => (others => null),
         Wts       => (others => 1),
         N         => 0);
      Panes_Row : constant Trinket.Widgets.Any_Widget :=
        Trinket.Widgets.New_Group (Trinket.Widgets.Horizontal);
      Btn_Row : constant Trinket.Widgets.Any_Widget :=
        Trinket.Widgets.New_Group (Trinket.Widgets.Horizontal);
      ISt : Images.Status;
   begin
      CLI.Init;
      Files.Bind (FS_EP);
      Panes (1).Path := new String'(CLI.Get_Cwd);
      Panes (2).Path := new String'(CLI.Boot_Volume);

      --  Deficons: Sys:System/Icons/*.xpm; any failure just
      --  leaves the rows icon-less.
      Images.Load ("BD0:System/Icons/DEFDRAW.XPM", Drawer_Img, ISt);
      Images.Load ("BD0:System/Icons/DEFFILE.XPM", File_Img, ISt);
      Images.Load ("BD0:System/Icons/DEFTOOL.XPM", Tool_Img, ISt);

      --  Per pane: path gadget on top, scrolled list component
      --  below (M87e: the scrollbar is part of the component).
      for P in 1 .. 2 loop
         declare
            Pane_Grp : constant Trinket.Widgets.Any_Widget :=
              Trinket.Widgets.New_Group (Trinket.Widgets.Vertical);
            Frame : Trinket.Widgets.Any_Widget;
         begin
            Panes (P).Path_Input := Trinket.Widgets.Input.New_Input;
            if P = 1 then
               Trinket.Widgets.Input.Input
                 (Panes (P).Path_Input.all).On_Commit :=
                   Path_Commit_L'Access;
               Frame := Trinket.Listview.New_Scrolled_List
                 (Panes (P).List, Selection_Changed_L'Access);
               Trinket.Listview.Set_On_Press
                 (Panes (P).List.all, Press_L'Access);
               Trinket.Listview.Set_On_Double_Click
                 (Panes (P).List.all, Double_L'Access);
            else
               Trinket.Widgets.Input.Input
                 (Panes (P).Path_Input.all).On_Commit :=
                   Path_Commit_R'Access;
               Frame := Trinket.Listview.New_Scrolled_List
                 (Panes (P).List, Selection_Changed_R'Access);
               Trinket.Listview.Set_On_Press
                 (Panes (P).List.all, Press_R'Access);
               Trinket.Listview.Set_On_Double_Click
                 (Panes (P).List.all, Double_R'Access);
            end if;
            Trinket.Widgets.Group (Pane_Grp.all).Add
              (Panes (P).Path_Input);
            Trinket.Widgets.Group (Pane_Grp.all).Add (Frame, 6);
            Trinket.Widgets.Group (Panes_Row.all).Add (Pane_Grp);
         end;
      end loop;

      Name_Input := Trinket.Widgets.Input.New_Input;
      Status_Label := Trinket.Widgets.Label.New_Label ("", Inset => True);

      --  Weights (MUI lineage): the panes take the bulk of the
      --  window; field/buttons/status split the rest evenly.
      --  Buttons: nine at weight 1 = equal width (Dopus bar).
      Trinket.Widgets.Group (Root.all).Add (Panes_Row, 6);
      Trinket.Widgets.Group (Root.all).Add (Name_Input);
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.Button.New_Button ("Open", Open_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.Button.New_Button ("Parent", Parent_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.Button.New_Button ("Copy", Copy_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.Button.New_Button ("Move", Move_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.Button.New_Button ("Rename", Rename_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.Button.New_Button ("Swap", Swap_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.Button.New_Button
           ("New Drawer", Newdir_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.Button.New_Button ("Delete", Delete_Clicked'Access));
      Trinket.Widgets.Group (Btn_Row.all).Add
        (Trinket.Widgets.Button.New_Button ("Quit", Quit_Clicked'Access));
      Trinket.Widgets.Group (Root.all).Add (Btn_Row);
      Trinket.Widgets.Group (Root.all).Add (Status_Label);

      if Trinket.Window.Open
        (Win, Bureau_EP, 720, 440, "File Manager", Root)
      then
         Trinket.Window.Set_Menus
           (Win,
            (1 => Trinket.Menus.M
               ("File", (Trinket.Menus.It (1, "Open"),
                         Trinket.Menus.It (2, "Parent"),
                         Trinket.Menus.It (3, "Copy"),
                         Trinket.Menus.It (4, "Move"),
                         Trinket.Menus.It (5, "Rename"),
                         Trinket.Menus.It (6, "Swap"),
                         Trinket.Menus.It (7, "New Drawer"),
                         Trinket.Menus.It (8, "Delete"),
                         Trinket.Menus.It (9, "Quit")))));
         Trinket.Window.Set_Menu_Handler (Win, Menu_Picked'Access);
         --  Phase B: the pumped directory fill arrives as app
         --  messages; without the handler the post would sit in
         --  the ring until the next real input event.
         Trinket.Window.Set_App_Handler (Win, Fill_More'Access);
         Load_T0 := Syscalls.Read_Time;
         Load_Directory (1, Panes (1).Path.all);
         Load_Directory (2, Panes (2).Path.all);
         --  The initial loads select row 1 once their (sorted)
         --  rows commit; the left pane starts active. Rows for a
         --  big directory appear when its full read completes —
         --  the pump keeps the window live meanwhile.
         Active := 1;
         Set_Status ("Left pane active");
         if not Fill (1).Active and then not Fill (2).Active then
            Syscalls.Debug_Put_Line ("fileman: filled " & Natural'Image (Pane_Rows)
                            & " rows t="
                            & Syscalls.U64'Image
                              (Syscalls.Read_Time - Load_T0));
         else
            Track_Startup := True;   --  Fill_More prints completion
         end if;
         Trinket.Window.Run (Win);
         Trinket.Window.Close (Win);
      end if;
   end Main;

end Fileman_App;
