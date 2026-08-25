package body Scripting is

   procedure Split_Cmd
     (Cmd : String; W_Last : out Natural; R_First : out Natural)
   is
      W : Natural := Cmd'First;
   begin
      while W <= Cmd'Last and then Cmd (W) /= ' ' loop
         W := W + 1;
      end loop;
      W_Last := W - 1;
      while W <= Cmd'Last and then Cmd (W) = ' ' loop
         W := W + 1;
      end loop;
      R_First := W;
   end Split_Cmd;

end Scripting;
