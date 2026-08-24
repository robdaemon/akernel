package body Terminal_Buffer is

   subtype Line_String is String (1 .. Max_Cols);
   type Line_Rec is record
      Text : Line_String;
      Len  : Natural;
   end record;
   type Line_Array is array (0 .. Max_Lines - 1) of Line_Rec;

   Buffer       : Line_Array := (others => (Text => (others => ' '), Len => 0));
   Base         : Natural := 0;      --  index of oldest line
   Count        : Natural := 1;      --  number of lines
   Current      : Natural := 0;      --  line receiving new chars
   Current_Len  : Natural := 0;      --  used length of Current line
   Cols_Count   : Natural := 80;
   Rows_Count   : Natural := 25;
   Top          : Natural := 0;
   Dirty_Flag   : Boolean := True;

   procedure Set_Dirty is
   begin
      Dirty_Flag := True;
   end Set_Dirty;

   function Is_Dirty return Boolean is (Dirty_Flag);

   procedure Clear_Dirty is
   begin
      Dirty_Flag := False;
   end Clear_Dirty;

   function Line_Index (I : Natural) return Natural is
   begin
      return (Base + I) mod Max_Lines;
   end Line_Index;

   procedure Init (C, R : Natural) is
   begin
      Cols_Count := C;
      Rows_Count := R;
      Clear;
   end Init;

   procedure Clear is
   begin
      Base := 0;
      Count := 1;
      Current := 0;
      Current_Len := 0;
      Top := 0;
      Buffer := (others => (Text => (others => ' '), Len => 0));
      Dirty_Flag := True;
   end Clear;

   function Line_Count return Natural is (Count);
   function Cols return Natural is (Cols_Count);
   function Rows return Natural is (Rows_Count);
   function View_Top return Natural is (Top);
   function Current_Line return Natural is (Count - 1);
   function Current_Col  return Natural is (Current_Len);

   function Max_Top return Natural is
   begin
      if Count > Rows_Count then
         return Count - Rows_Count;
      end if;
      return 0;
   end Max_Top;

   procedure New_Line is
      Old_Max : constant Natural := Max_Top;
   begin
      Buffer (Current).Len := Current_Len;
      Current_Len := 0;
      if Count < Max_Lines then
         Count := Count + 1;
         Current := (Current + 1) mod Max_Lines;
      else
         Base := (Base + 1) mod Max_Lines;
         Current := (Current + 1) mod Max_Lines;
      end if;
      Buffer (Current).Len := 0;
      --  Auto-scroll only if the user was already at the bottom;
      --  otherwise preserve their manual scroll position.
      if Count > Rows_Count and then Top >= Old_Max then
         Top := Count - Rows_Count;
      elsif Count <= Rows_Count then
         Top := 0;
      end if;
      Set_Dirty;
   end New_Line;

   procedure Put_Char (Ch : Character) is
      Code : constant Natural := Character'Pos (Ch);
   begin
      if Code = 10 then
         New_Line;
      elsif Code = 13 then
         Current_Len := 0;
      elsif Code = 9 then
         Current_Len := (Current_Len + 4) / 4 * 4;
         if Current_Len >= Cols_Count then
            New_Line;
         end if;
      elsif Code = 8 then
         if Current_Len > 0 then
            Current_Len := Current_Len - 1;
         end if;
      elsif Code >= 32 and then Code < 127 then
         if Current_Len >= Cols_Count then
            New_Line;
         end if;
         if Current_Len < Max_Cols then
            Buffer (Current).Text (Current_Len + 1) := Ch;
            Current_Len := Current_Len + 1;
            if Current_Len = Cols_Count then
               New_Line;
            end if;
         end if;
      end if;
      Buffer (Current).Len := Current_Len;
      Set_Dirty;
   end Put_Char;

   procedure Set_Top (T : Natural) is
      M : constant Natural := Max_Top;
   begin
      if T > M then
         if Top /= M then
            Top := M;
            Set_Dirty;
         end if;
      elsif T /= Top then
         Top := T;
         Set_Dirty;
      end if;
   end Set_Top;

   procedure Get_Line (I : Natural; S : out String; Len : out Natural) is
      Idx : Natural;
   begin
      Len := 0;
      if I >= Count then
         return;
      end if;
      Idx := Line_Index (I);
      Len := Natural'Min (Buffer (Idx).Len, S'Length);
      if Len > 0 then
         S (S'First .. S'First + Len - 1) :=
           Buffer (Idx).Text (1 .. Len);
      end if;
   end Get_Line;

end Terminal_Buffer;
