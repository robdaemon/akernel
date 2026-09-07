with Akernel_User.CLI;
with Akernel_User.Files;
with Trinket.Columns;
with Trinket.Window;
with Trinket.Widgets;
with Trinket.Widgets.Button;
with Trinket.Widgets.Input;
with Trinket.Widgets.Label;

package body Trinket.File_Requester is

   use type Akernel_User.Syscalls.U64;
   package Widgets renames Trinket.Widgets;

   Max_Path_Len : constant := 255;
   Max_Rows     : constant := 512;

   Req_Mode  : Mode_Kind := Pick_Open;
   Cur       : String (1 .. Max_Path_Len);
   Cur_Len   : Natural := 0;

   Cols_W    : Trinket.Columns.Any_Columns;
   Path_Inp  : Widgets.Any_Widget;
   Name_Inp  : Widgets.Any_Widget;

   --  Per-row leaf + kind, parallel to the Columns rows (the
   --  widget keeps display strings only).
   Leaf_Buf  : array (1 .. Max_Rows) of String (1 .. 32);
   Leaf_Len  : array (1 .. Max_Rows) of Natural := (others => 0);
   Leaf_Dir  : array (1 .. Max_Rows) of Boolean := (others => False);
   Row_Count : Natural := 0;

   --  Host window for the modal (assigned per Run).
   type Win_Acc is access all Trinket.Window.Window;
   Host      : Win_Acc := null;

   Result    : access String := null;
   Result_Len : Natural := 0;
   Picked    : Boolean := False;

   function Min (A, B : Natural) return Natural is
     (if A < B then A else B);

   function U64_Text (V : Akernel_User.Syscalls.U64) return String is
      Digs : String (1 .. 20);
      Len  : Natural := 0;
      X    : Akernel_User.Syscalls.U64 := V;
   begin
      if X = 0 then
         return "0";
      end if;
      while X /= 0 loop
         Len := Len + 1;
         Digs (Len) := Character'Val
           (Character'Pos ('0')
            + Natural (X mod 10));
         X := X / 10;
      end loop;
      return Digs (1 .. Len);
   end U64_Text;

   function Two_Digits (V : Akernel_User.Syscalls.U64) return String is
     (Character'Val (Character'Pos ('0') + Natural (V / 10))
      & Character'Val (Character'Pos ('0') + Natural (V mod 10)));

   --  Epoch seconds -> "YYYY-MM-DD" ("" for 0). Days-from-civil
   --  via Hinnant (U64 arithmetic, 1970..2106 range in practice).
   function Date_Text (Secs : Akernel_User.Syscalls.U64)
                       return String is
      Z, Era, Doe, Yoe, Y, Doy, Mp, D, M : Akernel_User.Syscalls.U64;
   begin
      if Secs < 86_400 then
         return "";
      end if;
      Z   := Secs / 86_400 + 719_468;
      Era := Z / 146_097;
      Doe := Z mod 146_097;
      Yoe := (Doe - Doe / 1_460 + Doe / 36_524 - Doe / 146_096)
             / 365;
      Y   := Yoe + Era * 400;
      Doy := Doe - (365 * Yoe + Yoe / 4 - Yoe / 100);
      Mp  := (5 * Doy + 2) / 153;
      D   := Doy - (153 * Mp + 2) / 5 + 1;
      M   := (if Mp < 10 then Mp + 3 else Mp - 9);
      if M <= 2 then
         Y := Y + 1;
      end if;
      if Y > 9_999 then
         return "";
      end if;
      return (Two_Digits (Y / 100) & Two_Digits (Y mod 100)
              & "-" & Two_Digits (M) & "-" & Two_Digits (D));
   end Date_Text;

   procedure Finish (Path : String) is
   begin
      Picked := True;
      Result_Len := Min (Path'Length, Result'Length);
      if Result_Len > 0 then
         Result (Result'First .. Result'First + Result_Len - 1) :=
           Path (Path'First .. Path'First + Result_Len - 1);
      end if;
      if Host /= null then
         Trinket.Window.Request_Modal_Exit (Host.all);
      end if;
   end Finish;

   procedure Canceled is
   begin
      Picked := False;
      Result_Len := 0;
      if Host /= null then
         Trinket.Window.Request_Modal_Exit (Host.all);
      end if;
   end Canceled;

   function Parent_Of return String is
   begin
      if Cur_Len = 0 then
         return "";
      end if;
      for I in reverse 1 .. Cur_Len loop
         if Cur (I) = '/' then
            return Cur (1 .. I - 1);
         end if;
      end loop;
      --  Volume root or bare volume name: no parent.
      return Cur (1 .. Cur_Len);
   end Parent_Of;

   procedure Reload is
      Idx    : Akernel_User.Syscalls.U64 := 0;
      E_Nm   : String (1 .. 32);
      E_L    : Natural;
      E_D    : Boolean;
      E_S, E_M : Akernel_User.Syscalls.U64;
      St     : Akernel_User.Syscalls.U64;
      N      : Natural := 0;
   begin
      Trinket.Columns.Clear (Cols_W.all);
      Row_Count := 0;
      if Cur_Len = 0 then
         return;
      end if;
      loop
         exit when N >= Max_Rows;
         St := Akernel_User.Files.Read_Dir_Ex
           (Cur (1 .. Cur_Len), Idx, E_Nm, E_L, E_D, E_S, E_M);
         exit when St /= Akernel_User.Files.Status_Ok;
         N := N + 1;
         Row_Count := N;
         Leaf_Len (N) := Min (E_L, Leaf_Buf (N)'Length);
         if Leaf_Len (N) > 0 then
            Leaf_Buf (N) (1 .. Leaf_Len (N)) :=
              E_Nm (1 .. Leaf_Len (N));
         end if;
         Leaf_Dir (N) := E_D;
         Trinket.Columns.Add_Row
           (Cols_W.all,
            E_Nm (1 .. Min (E_L, 32)),
            (if E_D then "" else U64_Text (E_S)),
            Date_Text (E_M), E_D);
         Idx := Idx + 1;
      end loop;
      if Row_Count > 0 then
         Trinket.Columns.Set_Selected (Cols_W.all, 1);
      end if;
   end Reload;

   procedure Go_To (Path : String) is
   begin
      Cur_Len := Min (Path'Length, Cur'Length);
      if Cur_Len > 0 then
         Cur (1 .. Cur_Len) := Path (Path'First
                                     .. Path'First + Cur_Len - 1);
      end if;
      Trinket.Widgets.Input.Input (Path_Inp.all).Set_Text
        (Cur (1 .. Cur_Len));
      Reload;
   end Go_To;

   procedure Up_Clicked is
   begin
      Go_To (Parent_Of);
   end Up_Clicked;

   procedure Path_Committed is
   begin
      Go_To (Trinket.Widgets.Input.Get_Text
               (Trinket.Widgets.Input.Input (Path_Inp.all)));
   end Path_Committed;

   procedure Row_Activated (Index : Natural) is
      Leaf : constant String :=
        (if Index in 1 .. Row_Count
         then Leaf_Buf (Index) (1 .. Leaf_Len (Index)) else "");
   begin
      if Index not in 1 .. Row_Count or else Leaf'Length = 0 then
         return;
      end if;
      if Leaf_Dir (Index) then
         Go_To (Akernel_User.CLI.Join_Path (Cur (1 .. Cur_Len),
                                            Leaf));
      elsif Req_Mode = Pick_Open then
         Finish (Akernel_User.CLI.Join_Path (Cur (1 .. Cur_Len),
                                             Leaf));
      else
         --  Save As: offer the name, wait for Save/Return.
         Trinket.Widgets.Input.Input (Name_Inp.all).Set_Text (Leaf);
      end if;
   end Row_Activated;

   procedure Row_Changed (Index : Natural) is
   begin
      null;   --  selection drives Open; nothing else needed
   end Row_Changed;

   procedure Open_Save_Clicked is
      Name : constant String := Trinket.Widgets.Input.Get_Text
        (Trinket.Widgets.Input.Input (Name_Inp.all));
   begin
      if Req_Mode = Pick_Open then
         Row_Activated (Trinket.Columns.Selected (Cols_W.all));
      else
         if Name'Length > 0 then
            Finish (Akernel_User.CLI.Join_Path (Cur (1 .. Cur_Len),
                                                Name));
         end if;
      end if;
   end Open_Save_Clicked;

   procedure Name_Committed is
   begin
      if Req_Mode = Pick_Save_As then
         Open_Save_Clicked;
      end if;
   end Name_Committed;

   function Run
     (Win         : in out Trinket.Window.Window;
      Mode        : Mode_Kind;
      Initial_Dir : String;
      Chosen      : out String;
      Chosen_Len  : out Natural) return Boolean
   is
      Root : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Vertical);
      Row1 : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
      Row3 : constant Widgets.Any_Widget :=
        Widgets.New_Group (Widgets.Horizontal);
      Lbl  : Widgets.Any_Widget;
      Cols_Frame : Widgets.Any_Widget;
   begin
      Req_Mode := Mode;
      Picked := False;
      Result_Len := 0;
      Result := Chosen'Unrestricted_Access;
      Host := Win'Unrestricted_Access;
      Cur_Len := Min (Initial_Dir'Length, Cur'Length);
      if Cur_Len > 0 then
         Cur (1 .. Cur_Len) :=
           Initial_Dir (Initial_Dir'First
                        .. Initial_Dir'First + Cur_Len - 1);
      end if;
      Path_Inp := null;
      Name_Inp := null;

      Lbl := Widgets.Label.New_Label
        ((if Mode = Pick_Open then "Open" else "Save As"),
         Inset => True);
      Widgets.Group (Row1.all).Add (Lbl);
      Widgets.Group (Row1.all).Add
        (Widgets.Button.New_Button ("Up", Up_Clicked'Access));
      Widgets.Group (Root.all).Add (Row1);

      Path_Inp := Widgets.Input.New_Input;
      Widgets.Input.Input (Path_Inp.all).On_Commit :=
        Path_Committed'Access;
      Widgets.Group (Root.all).Add (Path_Inp);

      Cols_Frame := Trinket.Columns.New_Scrolled_Columns
        (Cols_W, Row_Changed'Access, Row_Activated'Access);
      Widgets.Group (Root.all).Add (Cols_Frame, Weight => 5);

      if Mode = Pick_Save_As then
         Name_Inp := Widgets.Input.New_Input;
         Widgets.Input.Input (Name_Inp.all).On_Commit :=
           Name_Committed'Access;
         Widgets.Group (Row3.all).Add (Name_Inp, Weight => 2);
      end if;
      Widgets.Group (Row3.all).Add
        (Widgets.Button.New_Button
           ((if Mode = Pick_Open then "Open" else "Save"),
            Open_Save_Clicked'Access));
      Widgets.Group (Row3.all).Add
        (Widgets.Button.New_Button ("Cancel", Canceled'Access));
      Widgets.Group (Root.all).Add (Row3);

      Go_To (Cur (1 .. Cur_Len));
      Trinket.Window.Run_Modal (Win, Root);

      Chosen_Len := Result_Len;
      Host := null;
      return Picked;
   end Run;

end Trinket.File_Requester;
